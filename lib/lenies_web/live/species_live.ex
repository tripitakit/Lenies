defmodule LeniesWeb.SpeciesLive do
  @moduledoc """
  Detail view for a species at `/species/:hash`.

  Shows population summary, Codeome (via sample Lenie), and lineage list.
  Phylogenetic tree visualization deferred (placeholder).

  See spec §7.3.
  """

  use LeniesWeb, :live_view

  alias Lenies.Species
  alias LeniesWeb.Disassembler

  @impl true
  def mount(%{"hash" => hash}, _session, socket) do
    user = socket.assigns.current_scope.user
    user_id = user.id
    world_id = Lenies.Sandboxes.world_id_for(user_id)

    :ok = Lenies.Sandboxes.attach(user_id)
    {:ok, world_handle} = Lenies.Worlds.handle(world_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "sandboxes:manager_up")
    end

    socket =
      socket
      |> assign(:world_id, world_id)
      |> assign(:world_handle, world_handle)
      |> assign(:hash, hash)
      |> load_species()

    {:ok, socket}
  end

  defp load_species(socket) do
    hash = socket.assigns.hash
    records = Species.for_hash(socket.assigns.world_handle, hash)

    if Enum.empty?(records) do
      socket
      |> assign(:found?, false)
      |> assign(:population, 0)
      |> assign(:lineage_entries, [])
      |> assign(:codeome_lines, [])
    else
      lineage_entries =
        records
        |> Enum.map(fn {id, snap} ->
          {parent_id, gen} = Map.get(snap, :lineage, {nil, 0})
          %{id: id, parent_id: parent_id, generation: gen, energy: snap.energy}
        end)
        |> Enum.sort_by(& &1.generation)

      {sample_id, _} = hd(records)
      codeome_lines = fetch_sample_codeome(socket.assigns.world_id, sample_id)

      socket
      |> assign(:found?, true)
      |> assign(:population, length(records))
      |> assign(:lineage_entries, lineage_entries)
      |> assign(:codeome_lines, codeome_lines)
    end
  end

  defp fetch_sample_codeome(world_id, sample_id) do
    case Registry.lookup(Lenies.Registry, {:lenie, world_id, sample_id}) do
      [{pid, _}] ->
        try do
          case GenServer.call(pid, :get_codeome) do
            {:ok, codeome} -> Disassembler.disassemble(codeome, nil)
            _ -> []
          end
        catch
          :exit, _ -> []
        end

      [] ->
        []
    end
  end

  @impl true
  def handle_info(:sandboxes_manager_up, socket) do
    :ok = Lenies.Sandboxes.attach(socket.assigns.current_scope.user.id)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="species-view">
      <Layouts.flash_group flash={@flash} />
      <h1>Species: {String.slice(@hash, 0..15)}…</h1>

      <%= if @found? do %>
        <p><strong>Population:</strong> {@population}</p>

        <h2>Codeome ({length(@codeome_lines)} opcodes)</h2>
        <pre class="disassembly">
          <%= for line <- @codeome_lines do %>
            <div class="line">
              <span class="idx">{String.pad_leading(Integer.to_string(line.index), 4, "0")}</span>
              <span class={"op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
                {Atom.to_string(line.opcode)}
              </span>
            </div>
          <% end %>
        </pre>

        <h2>Lineage ({length(@lineage_entries)} entries)</h2>
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Parent</th>
              <th>Generation</th>
              <th>Energy</th>
            </tr>
          </thead>
          <tbody>
            <%= for entry <- @lineage_entries do %>
              <tr>
                <td>
                  <a href={"/lenie/#{entry.id}"}>{entry.id}</a>
                </td>
                <td>{entry.parent_id || "—"}</td>
                <td>{entry.generation}</td>
                <td>{Float.round(entry.energy, 2)}</td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <p class="note">
          (Phylogeny SVG-tree and sister-species diff: deferred to a future polish.)
        </p>
      <% else %>
        <p>Species with hash <code>{@hash}</code> not found (extinct or never existed).</p>
      <% end %>

      <a href="/">← Back to dashboard</a>
    </div>
    """
  end
end
