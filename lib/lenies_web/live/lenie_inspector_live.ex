defmodule LeniesWeb.LenieInspectorLive do
  @moduledoc """
  Inspector view for an individual Lenie at `/lenie/:id`.

  Shows current state and Codeome disassembled with IP highlighted. Polls the
  Lenie process via `Lenies.Lenie.inspect_state/1` on a timer to refresh — the
  Lenie no longer broadcasts per-tick updates (that fired thousands of
  no-subscriber PubSub messages/sec on a populated world; only this single,
  optional inspector ever cared).

  See spec §7.2.
  """

  use LeniesWeb, :live_view

  alias LeniesWeb.Disassembler

  # Human-inspector refresh cadence. Comparable to the old broadcast cadence
  # (~snapshot_every_batches × metabolize delay ≈ 1s) but driven by the viewer,
  # so an open inspector costs one GenServer.call per interval instead of every
  # Lenie broadcasting every tick.
  @refresh_interval_ms 750

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user
    user_id = user.id
    world_id = Lenies.Sandboxes.world_id_for(user_id)

    :ok = Lenies.Sandboxes.attach(user_id)
    {:ok, world_handle} = Lenies.Worlds.handle(world_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "sandboxes:manager_up")
      Process.send_after(self(), :refresh, @refresh_interval_ms)
    end

    socket =
      socket
      |> assign(:world_id, world_id)
      |> assign(:world_handle, world_handle)
      |> assign(:id, id)
      |> load_lenie()

    {:ok, socket}
  end

  defp load_lenie(socket) do
    id = socket.assigns.id
    world_id = socket.assigns.world_id

    case Registry.lookup(Lenies.Registry, {:lenie, world_id, id}) do
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
        case lookup_lenie_snap(socket.assigns.world_handle, id) do
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

  defp lookup_lenie_snap(%Lenies.WorldHandle{} = handle, id) do
    case :ets.lookup(handle.tables.lenies, id) do
      [{^id, snap}] -> {:ok, snap}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp lookup_lenie_snap(_handle, _id), do: :error

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
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    {:noreply, load_lenie(socket)}
  end

  def handle_info(:sandboxes_manager_up, socket) do
    :ok = Lenies.Sandboxes.attach(socket.assigns.current_scope.user.id)
    {:noreply, socket}
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
