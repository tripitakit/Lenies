defmodule LeniesWeb.DashboardLive do
  @moduledoc """
  Main dashboard for monitoring the Lenies sandbox.

  Four panels (per spec §7.1):
  1. World (canvas 512×512 with 3 toggleable layers)
  2. Telemetry (population over time)
  3. Species (top-N table)
  4. Controls (delegated to LeniesWeb.ControlsPanelComponent — see file)

  Only the world canvas and telemetry/species panels re-render on tick;
  controls live in a LiveComponent so form/input state is preserved.
  """

  use LeniesWeb, :live_view

  alias LeniesWeb.GridRenderer

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:control")
    end

    grid = Lenies.Config.grid_size()
    {species, all_species, species_total} = aggregate_with_top(10)

    # `?world_detail=1` reopens the modal — used by the editor's Back/Cancel
    # to restore the view it was launched from (dblclick on a Lenie cell).
    world_detail_open? = params["world_detail"] == "1"

    socket =
      socket
      |> assign(:grid, grid)
      |> assign(:tick_count, 0)
      |> assign(:layers_visible, %{lenies: true, resource: true, carcass: true})
      |> assign(:throttle_counter, 0)
      |> assign(:history, [])
      |> assign(:species, species)
      |> assign(:species_total, species_total)
      |> assign(:all_species, all_species)
      |> assign(:selected_hash, nil)
      |> assign(:selected_species_record, nil)
      |> assign(:inspector_dirty, false)
      |> assign(:world_detail_open?, world_detail_open?)
      |> assign(:world_detail_highlight_hash, nil)
      |> assign(:world_paused?, world_paused_status())

    {:ok, socket}
  end

  # Read the running world's actual pause flag at mount so the modal
  # opens with the correct button state even if some other client (or
  # an iex session) toggled it. Defaults to false if World isn't up.
  defp world_paused_status do
    case Process.whereis(Lenies.World) do
      pid when is_pid(pid) ->
        try do
          Lenies.World.paused?()
        catch
          :exit, _ -> false
        end

      _ ->
        false
    end
  end

  # Returns {top_n, all_species, total_count} from a single Species.aggregate()
  # pass. The dashboard table uses `top_n`; the World Detail modal needs the
  # full `all_species` list (sorted by population descending, already).
  defp aggregate_with_top(n) do
    all = Lenies.Species.aggregate()
    {Enum.take(all, n), all, length(all)}
  end

  defp find_selected_record(nil, _species), do: nil

  defp find_selected_record(hash, species) do
    case Enum.find(species, &(&1.hash == hash)) do
      %{} = found ->
        found

      nil ->
        case Lenies.Species.for_hash(hash) do
          [] ->
            %{hash: hash, population: 0, avg_generation: 0.0}

          records ->
            gens =
              records
              |> Enum.map(fn {_id, snap} -> snap.lineage |> elem(1) end)

            avg =
              if Enum.empty?(gens),
                do: 0.0,
                else: Enum.sum(gens) / length(gens) * 1.0

            %{hash: hash, population: length(records), avg_generation: avg}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="lenies-dashboard h-screen w-screen overflow-hidden flex flex-col p-3 gap-3"
      data-inspector-dirty={if @inspector_dirty, do: "true", else: nil}
    >
      <header class="flex items-center justify-between px-2 shrink-0">
        <h1 class="text-lg font-bold tracking-widest">⬡ LENIES · SANDBOX</h1>
        <div class="flex items-center gap-4 text-xs">
          <span class="flex items-center gap-1.5">
            <span class="pulse-dot inline-block w-2 h-2 rounded-full bg-cyan-400 shadow-[0_0_8px_#22d3ee]">
            </span>
            <span class="opacity-70">TICK</span>
            <span class="text-cyan-300 font-bold tabular-nums">{@tick_count}</span>
          </span>
          <span class="opacity-70">
            GRID <span class="text-cyan-300">{elem(@grid, 0)}×{elem(@grid, 1)}</span>
          </span>
          <span class="opacity-70">
            SPECIES <span class="text-violet-300">{@species_total}</span>
          </span>
          <button
            id="audio-toggle"
            phx-update="ignore"
            type="button"
            title="Toggle audio feedback"
            onclick="(function(b){var m=window.LeniesAudio&&window.LeniesAudio.isMuted();if(m){window.LeniesAudio.unmute();b.textContent='♪ AUDIO';b.dataset.muted='';}else{window.LeniesAudio&&window.LeniesAudio.mute();b.textContent='∅ MUTE';b.dataset.muted='1';}})(this)"
            class="text-[10px] px-2 py-1 border border-cyan-500/40 hover:border-cyan-300 hover:text-cyan-200"
          >
            ♪ AUDIO
          </button>
        </div>
      </header>

      <div class="flex-1 grid gap-3 min-h-0 grid-rows-[minmax(0,1fr)_auto]">
        <div class="flex gap-3 min-h-0">
          <div class="panel p-3 flex flex-col gap-2 shrink-0">
            <h2 class="text-xs">▮ World</h2>
            <div class="canvas-frame">
              <canvas
                id="grid-canvas"
                phx-hook="GridCanvas"
                data-grid-width={elem(@grid, 0)}
                data-grid-height={elem(@grid, 1)}
                data-show-lenies={@layers_visible.lenies}
                data-show-resource={@layers_visible.resource}
                data-show-carcass={@layers_visible.carcass}
                width="512"
                height="512"
                class="block"
              >
              </canvas>
            </div>
            <div class="flex gap-3 text-xs">
              <label class="flex items-center gap-1.5 cursor-pointer">
                <input
                  type="checkbox"
                  phx-click="toggle_layer"
                  phx-value-layer="lenies"
                  checked={@layers_visible.lenies}
                  class="accent-cyan-400"
                />
                <span>Lenies</span>
              </label>
              <label class="flex items-center gap-1.5 cursor-pointer">
                <input
                  type="checkbox"
                  phx-click="toggle_layer"
                  phx-value-layer="resource"
                  checked={@layers_visible.resource}
                  class="accent-emerald-400"
                />
                <span>Resources</span>
              </label>
              <label class="flex items-center gap-1.5 cursor-pointer">
                <input
                  type="checkbox"
                  phx-click="toggle_layer"
                  phx-value-layer="carcass"
                  checked={@layers_visible.carcass}
                  class="accent-rose-400"
                />
                <span>Carcasses</span>
              </label>
            </div>
          </div>

          <div class="flex-1 grid grid-rows-2 gap-3 min-h-0 min-w-0">
            <div class="panel p-3 flex flex-col gap-2 min-h-0">
              <h2 class="text-xs">▮ Telemetry — total population over time</h2>
              <% latest = List.last(@history) || %{population: 0, total_resource: 0, total_carcass: 0} %>
              <div class="grid grid-cols-3 gap-2 text-[11px]">
                <div class="border border-cyan-500/30 px-2 py-1">
                  <div class="opacity-60">pop.</div>
                  <div class="text-cyan-300 font-bold tabular-nums text-base">
                    {format_count(latest.population)}
                  </div>
                </div>
                <div class="border border-emerald-500/30 px-2 py-1">
                  <div class="opacity-60">resources</div>
                  <div
                    class="text-emerald-300 font-bold tabular-nums text-base"
                    title={"#{latest.total_resource}"}
                  >
                    {format_count(latest.total_resource)}
                  </div>
                </div>
                <div class="border border-rose-500/30 px-2 py-1">
                  <div class="opacity-60">carcasses</div>
                  <div
                    class="text-rose-300 font-bold tabular-nums text-base"
                    title={"#{latest.total_carcass}"}
                  >
                    {format_count(latest.total_carcass)}
                  </div>
                </div>
              </div>
              <% n_points = max(1, length(@history)) %>
              <% species_pops =
                for entry <- @history,
                    do: Map.get(entry, :species, %{}) %>
              <% species_max =
                species_pops
                |> Enum.flat_map(&Map.values/1)
                |> Enum.max(fn -> 1 end)
                |> max(1) %>
              <svg
                viewBox="0 0 300 100"
                preserveAspectRatio="none"
                class="w-full flex-1 min-h-[60px] bg-slate-950/60 border border-cyan-500/20"
              >
                <line x1="0" y1="100" x2="300" y2="100" stroke="#334155" stroke-width="0.5" />
                <line x1="0" y1="0" x2="300" y2="0" stroke="#334155" stroke-width="0.5" />
                <%= for sp <- @species do %>
                  <polyline
                    fill="none"
                    stroke={Lenies.SpeciesColor.hex(sp.hash)}
                    stroke-width="1"
                    opacity="0.85"
                    points={
                      species_pops
                      |> Enum.with_index()
                      |> Enum.map(fn {pops_map, i} ->
                        pop = Map.get(pops_map, sp.hash, 0)
                        x = i / n_points * 300
                        y = 100 - pop / species_max * 95
                        "#{Float.round(x, 1)},#{Float.round(y, 1)}"
                      end)
                      |> Enum.join(" ")
                    }
                  />
                <% end %>
                <text x="4" y="10" fill="#64748b" font-size="8" font-family="monospace">
                  max {species_max}
                </text>
                <text x="4" y="96" fill="#64748b" font-size="8" font-family="monospace">0</text>
              </svg>
              <p class="text-[9px] opacity-50 leading-tight">
                One line per species in the current top {length(@species)} (top 20 per tick saved to history).
              </p>
            </div>

            <div class="panel p-3 flex flex-col gap-2 min-h-0">
              <h2 class="text-xs">
                ▮ Top {length(@species)} species of <span class="opacity-60">{@species_total}</span>
              </h2>
              <div class="flex-1 min-h-0 overflow-auto">
                <table class="w-full text-[11px] tabular-nums">
                  <thead class="text-cyan-300/80 sticky top-0 bg-slate-950/80">
                    <tr>
                      <th class="text-left py-1">Hash</th>
                      <th class="text-right py-1">Pop</th>
                      <th class="text-right py-1">Gen</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for sp <- @species do %>
                      <tr
                        class={[
                          "hover:bg-cyan-500/10 cursor-pointer",
                          @selected_hash == sp.hash && "bg-cyan-500/20 ring-1 ring-cyan-400"
                        ]}
                        id={"species-row-#{sp.hash}"}
                        phx-click="select_species"
                        phx-value-hash={sp.hash}
                      >
                        <td class="py-0.5 flex items-center gap-1.5">
                          <span
                            class="inline-block w-2 h-2 shrink-0"
                            style={"background:#{Lenies.SpeciesColor.hex(sp.hash)}"}
                          >
                          </span>
                          <span class="text-cyan-400">
                            {String.slice(sp.hash, 0..7)}
                          </span>
                        </td>
                        <td class="text-right">{sp.population}</td>
                        <td class="text-right">{Float.round(sp.avg_generation, 2)}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <%= if @selected_hash do %>
            <.live_component
              module={LeniesWeb.SpeciesInspectorComponent}
              id="species-inspector"
              selected_hash={@selected_hash}
              species_record={@selected_species_record}
            />
          <% end %>
          <%= if @world_detail_open? do %>
            <.live_component
              module={LeniesWeb.WorldDetailComponent}
              id="world-detail"
              species={@all_species}
              highlight_hash={@world_detail_highlight_hash}
              grid={@grid}
              paused?={@world_paused?}
            />
          <% end %>
        </div>

        <.live_component module={LeniesWeb.ControlsPanelComponent} id="controls" />
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("select_species", %{"hash" => hash}, socket) do
    new_hash =
      if socket.assigns.selected_hash == hash do
        nil
      else
        hash
      end

    socket =
      socket
      |> assign(:selected_hash, new_hash)
      |> assign(:selected_species_record, find_selected_record(new_hash, socket.assigns.species))

    socket =
      if is_nil(new_hash),
        do: assign(socket, :inspector_dirty, false),
        else: socket

    {:noreply, socket}
  end

  def handle_event("toggle_layer", %{"layer" => layer}, socket) do
    layer_atom = String.to_existing_atom(layer)
    new_visible = Map.update!(socket.assigns.layers_visible, layer_atom, &(!&1))
    {:noreply, assign(socket, :layers_visible, new_visible)}
  end

  def handle_event("cell_clicked", %{"x" => x, "y" => y}, socket)
      when is_integer(x) and is_integer(y) do
    case :ets.lookup(:cells, {x, y}) do
      [{_, %{lenie_id: id}}] when is_binary(id) ->
        {:noreply, push_navigate(socket, to: ~p"/lenie/#{id}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_world_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:world_detail_open?, false)
     |> assign(:world_detail_highlight_hash, nil)}
  end

  def handle_event("highlight_species_in_world", %{"hash" => hash}, socket)
      when is_binary(hash) do
    new_hash =
      if socket.assigns.world_detail_highlight_hash == hash, do: nil, else: hash

    {:noreply, assign(socket, :world_detail_highlight_hash, new_hash)}
  end

  def handle_event("highlight_species_in_world", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_world_pause", _params, socket) do
    new_paused =
      if socket.assigns.world_paused? do
        Lenies.World.resume()
        false
      else
        Lenies.World.pause()
        true
      end

    {:noreply, assign(socket, :world_paused?, new_paused)}
  end

  def handle_event("select_lenie_at_cell", %{"x" => x, "y" => y}, socket)
      when is_integer(x) and is_integer(y) do
    case lookup_lenie_at_cell(x, y) do
      {:ok, hash} ->
        # `from=world-detail` lets the editor's Back/Cancel reopen the
        # modal instead of dropping the user on the plain dashboard.
        {:noreply,
         push_navigate(socket, to: ~p"/editor/edit/#{hash}?from=world-detail")}

      :error ->
        {:noreply, socket}
    end
  end

  defp lookup_lenie_at_cell(x, y) do
    with [{_, %{lenie_id: id}}] when is_binary(id) <- :ets.lookup(:cells, {x, y}),
         [{^id, lenie_meta}] <- :ets.lookup(:lenies, id),
         hash when is_binary(hash) <- Map.get(lenie_meta, :codeome_hash) do
      {:ok, hash}
    else
      _ -> :error
    end
  end

  @impl true
  def handle_info(:open_world_detail, socket) do
    {:noreply,
     socket
     |> assign(:world_detail_open?, true)
     |> assign(:world_detail_highlight_hash, nil)}
  end

  def handle_info({:tick, n}, socket) do
    throttle = Application.get_env(:lenies, :dashboard_throttle_ticks, 5)
    new_counter = socket.assigns.throttle_counter + 1

    socket =
      socket
      |> assign(:tick_count, n)
      |> assign(:throttle_counter, new_counter)

    if rem(new_counter, throttle) == 0 do
      {species, all_species, species_total} = aggregate_with_top(10)

      socket =
        socket
        |> assign(:history, Lenies.Telemetry.history(:last_n, 100))
        |> assign(:species, species)
        |> assign(:species_total, species_total)
        |> assign(:all_species, all_species)
        |> assign(
          :selected_species_record,
          find_selected_record(socket.assigns.selected_hash, species)
        )
        |> maybe_clear_world_detail_highlight(all_species)

      payload = GridRenderer.encode_payload(socket.assigns.grid)
      {:noreply, push_event(socket, "render_frame", payload)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:sterilized, _ts}, socket) do
    payload = GridRenderer.encode_payload(socket.assigns.grid)
    {:noreply, push_event(socket, "render_frame", payload)}
  end

  def handle_info({:inspector_dirty, dirty}, socket) do
    {:noreply, assign(socket, :inspector_dirty, dirty)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Format large counters (resources / carcasses) so the user can read
  # them at a glance: thousand-separated below 1k, then k/M/B suffixes
  # so a runaway carcass_decay = 0 simulation doesn't render as an
  # unreadable 14-digit number that looks like a bug.
  defp format_count(n) when is_integer(n) and n >= 0 do
    cond do
      n < 1_000 -> Integer.to_string(n)
      n < 1_000_000 -> "#{Float.round(n / 1_000, 1)}k"
      n < 1_000_000_000 -> "#{Float.round(n / 1_000_000, 2)}M"
      true -> "#{Float.round(n / 1_000_000_000, 2)}B"
    end
  end

  defp format_count(n) when is_float(n), do: format_count(trunc(n))
  defp format_count(_), do: "0"

  defp maybe_clear_world_detail_highlight(socket, species) do
    case socket.assigns.world_detail_highlight_hash do
      nil ->
        socket

      hash ->
        if Enum.any?(species, &(&1.hash == hash)) do
          socket
        else
          assign(socket, :world_detail_highlight_hash, nil)
        end
    end
  end
end
