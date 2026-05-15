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
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:control")
    end

    grid = Lenies.Config.grid_size()
    {species, species_total} = top_species(10)

    socket =
      socket
      |> assign(:grid, grid)
      |> assign(:tick_count, 0)
      |> assign(:layers_visible, %{lenies: true, resource: true, carcass: true})
      |> assign(:throttle_counter, 0)
      |> assign(:history, [])
      |> assign(:species, species)
      |> assign(:species_total, species_total)
      |> assign(:selected_hash, nil)
      |> assign(:selected_species_record, nil)
      |> assign(:inspector_dirty, false)

    {:ok, socket}
  end

  defp top_species(n) do
    all = Lenies.Species.aggregate()
    {Enum.take(all, n), length(all)}
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
            SPECIE <span class="text-violet-300">{@species_total}</span>
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
            <h2 class="text-xs">▮ Mondo</h2>
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
                <span>Risorse</span>
              </label>
              <label class="flex items-center gap-1.5 cursor-pointer">
                <input
                  type="checkbox"
                  phx-click="toggle_layer"
                  phx-value-layer="carcass"
                  checked={@layers_visible.carcass}
                  class="accent-rose-400"
                />
                <span>Carcasse</span>
              </label>
            </div>
          </div>

          <div class="flex-1 grid grid-rows-2 gap-3 min-h-0 min-w-0">
            <div class="panel p-3 flex flex-col gap-2 min-h-0">
              <h2 class="text-xs">▮ Telemetria — popolazione totale nel tempo</h2>
              <% latest = List.last(@history) || %{population: 0, total_resource: 0, total_carcass: 0} %>
              <div class="grid grid-cols-3 gap-2 text-[11px]">
                <div class="border border-cyan-500/30 px-2 py-1">
                  <div class="opacity-60">popolaz.</div>
                  <div class="text-cyan-300 font-bold tabular-nums text-base">
                    {latest.population}
                  </div>
                </div>
                <div class="border border-emerald-500/30 px-2 py-1">
                  <div class="opacity-60">risorse</div>
                  <div class="text-emerald-300 font-bold tabular-nums text-base">
                    {latest.total_resource}
                  </div>
                </div>
                <div class="border border-rose-500/30 px-2 py-1">
                  <div class="opacity-60">carcasse</div>
                  <div class="text-rose-300 font-bold tabular-nums text-base">
                    {latest.total_carcass}
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
                Una linea per ciascuna delle top {length(@species)} specie correnti (top 20/tick salvate in history).
              </p>
            </div>

            <div class="panel p-3 flex flex-col gap-2 min-h-0">
              <h2 class="text-xs">
                ▮ Specie <span class="opacity-60">top {length(@species)} di {@species_total}</span>
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
                        phx-hook="ConfirmAction"
                        data-confirm="Discard codeome edits?"
                        data-confirm-when="[data-inspector-dirty='true']"
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

  @impl true
  def handle_info({:tick, n}, socket) do
    throttle = Application.get_env(:lenies, :dashboard_throttle_ticks, 5)
    new_counter = socket.assigns.throttle_counter + 1

    socket =
      socket
      |> assign(:tick_count, n)
      |> assign(:throttle_counter, new_counter)

    if rem(new_counter, throttle) == 0 do
      {species, species_total} = top_species(10)

      socket =
        socket
        |> assign(:history, Lenies.Telemetry.history(:last_n, 100))
        |> assign(:species, species)
        |> assign(:species_total, species_total)
        |> assign(:selected_species_record,
          find_selected_record(socket.assigns.selected_hash, species)
        )

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
end
