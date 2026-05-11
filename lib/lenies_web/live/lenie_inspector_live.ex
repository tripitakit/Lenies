defmodule LeniesWeb.LenieInspectorLive do
  @moduledoc """
  Inspector view for an individual Lenie at `/lenie/:id`.

  Shows current state and Codeome disassembled with IP highlighted.
  Subscribes to `"lenie:<id>"` PubSub topic and re-renders on each
  `{:lenie_update, snap}` broadcast.

  Vedi spec §7.2.
  """

  use LeniesWeb, :live_view

  alias LeniesWeb.Disassembler

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "lenie:#{id}")
    end

    socket =
      socket
      |> assign(:id, id)
      |> load_lenie()

    {:ok, socket}
  end

  defp load_lenie(socket) do
    id = socket.assigns.id

    case Lenies.Registry.whereis(id) do
      pid when is_pid(pid) ->
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

      _ ->
        case :ets.lookup(:lenies, id) do
          [{^id, snap}] ->
            socket
            |> assign(:found?, false)
            |> assign(:snap, snap)
            |> assign(:codeome_lines, [])

          _ ->
            assign(socket, :found?, false)
        end
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
        case Lenies.Registry.whereis(snap.id) do
          pid when is_pid(pid) -> assign(socket, :codeome_lines, fetch_codeome_lines(pid, snap))
          _ -> socket
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
      <h1>Lenie Inspector: {@id}</h1>

      <%= if @found? do %>
        <div class="state">
          <h2>Stato</h2>
          <table>
            <tr>
              <th>ID</th>
              <td>{@snap.id}</td>
            </tr>
            <tr>
              <th>Energia</th>
              <td>{Float.round(@snap.energy, 2)}</td>
            </tr>
            <tr>
              <th>Posizione</th>
              <td>{inspect(@snap.pos)}</td>
            </tr>
            <tr>
              <th>Direzione</th>
              <td>{@snap.dir}</td>
            </tr>
            <tr>
              <th>Età</th>
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
        <p>Lenie <strong>{@id}</strong> non trovato (forse estinto).</p>
      <% end %>

      <a href="/">← Torna al dashboard</a>
    </div>
    """
  end
end
