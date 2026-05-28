defmodule LeniesWeb.LenieInspectorLive do
  @moduledoc """
  Inspector view for an individual Lenie at `/lenie/:id`.

  Shows current state and Codeome disassembled with IP highlighted.
  Subscribes to `"lenie:<id>"` PubSub topic and re-renders on each
  `{:lenie_update, snap}` broadcast.

  See spec §7.2.
  """

  use LeniesWeb, :live_view

  alias LeniesWeb.Disassembler

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    world_id = :primary
    world_handle = fetch_primary_handle()

    if connected?(socket) do
      # Subscribe to the per-Lenie scoped topic, e.g. "world:primary:lenie:<id>".
      prefix = (world_handle && world_handle.pubsub_prefix) || "world:primary"
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:lenie:#{id}")
    end

    socket =
      socket
      |> assign(:world_id, world_id)
      |> assign(:world_handle, world_handle)
      |> assign(:id, id)
      |> load_lenie()

    {:ok, socket}
  end

  defp fetch_primary_handle do
    try do
      Lenies.Worlds.primary_handle()
    catch
      :exit, _ -> nil
    end
  end

  defp load_lenie(socket) do
    id = socket.assigns.id

    case Registry.lookup(Lenies.Registry, {:lenie, :primary, id}) do
      [{pid, _}] ->
        snap =
          try do
            Lenies.Lenie.inspect_state(pid)
          catch
            :exit, _ -> nil
          end

        if snap do
          socket
          |> assign(:found?, true)
          |> assign(:snap, snap)
          |> assign(:codeome_lines, fetch_codeome_lines(pid, snap))
        else
          assign(socket, :found?, false)
        end

      [] ->
        case lookup_lenie_snap(id) do
          {:ok, snap} ->
            socket
            |> assign(:found?, false)
            |> assign(:snap, snap)
            |> assign(:codeome_lines, [])

          :error ->
            assign(socket, :found?, false)
        end
    end
  end

  defp lookup_lenie_snap(id) do
    try do
      handle = Lenies.Worlds.primary_handle()

      case :ets.lookup(handle.tables.lenies, id) do
        [{^id, snap}] -> {:ok, snap}
        _ -> :error
      end
    catch
      :exit, _ -> :error
    end
  end

  defp fetch_codeome_lines(pid, snap) do
    try do
      case GenServer.call(pid, :get_codeome) do
        {:ok, codeome} ->
          ip = Map.get(snap, :ip, 0)
          Disassembler.disassemble(codeome, ip)

        _ ->
          []
      end
    catch
      :exit, _ -> []
    end
  end

  @impl true
  def handle_info({:lenie_update, snap}, socket) do
    if snap.id == socket.assigns.id do
      socket =
        socket
        |> assign(:snap, snap)
        |> assign(:found?, true)

      socket =
        case Registry.lookup(Lenies.Registry, {:lenie, :primary, snap.id}) do
          [{pid, _}] -> assign(socket, :codeome_lines, fetch_codeome_lines(pid, snap))
          [] -> socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="inspector">
      <Layouts.flash_group flash={@flash} />
      <h1>Lenie Inspector: {@id}</h1>

      <%= if @found? do %>
        <div class="state">
          <h2>State</h2>
          <table>
            <tr>
              <th>ID</th>
              <td>{@snap.id}</td>
            </tr>
            <tr>
              <th>Energy</th>
              <td>{Float.round(@snap.energy, 2)}</td>
            </tr>
            <tr>
              <th>Position</th>
              <td>{inspect(@snap.pos)}</td>
            </tr>
            <tr>
              <th>Direction</th>
              <td>{@snap.dir}</td>
            </tr>
            <tr>
              <th>Age</th>
              <td>{Map.get(@snap, :age, 0)}</td>
            </tr>
            <tr>
              <th>Lineage</th>
              <td>{inspect(Map.get(@snap, :lineage, {nil, 0}))}</td>
            </tr>
            <tr>
              <th>Child slot</th>
              <td>{Map.get(@snap, :child_slot_id, "—")}</td>
            </tr>
            <tr>
              <th>Codeome hash</th>
              <td>{Map.get(@snap, :codeome_hash, "?")}</td>
            </tr>
          </table>
        </div>

        <div class="codeome">
          <h2>Codeome ({length(@codeome_lines)} opcodes)</h2>
          <pre class="disassembly">
            <%= for line <- @codeome_lines do %>
              <div class={if line.is_current, do: "line current", else: "line"}>
                <span class="idx">{String.pad_leading(Integer.to_string(line.index), 4, "0")}</span>
                <span class={"op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
                  {Atom.to_string(line.opcode)}
                </span>
              </div>
            <% end %>
          </pre>
        </div>
      <% else %>
        <p>Lenie <strong>{@id}</strong> not found (possibly extinct).</p>
      <% end %>

      <a href="/">← Back to dashboard</a>
    </div>
    """
  end
end
