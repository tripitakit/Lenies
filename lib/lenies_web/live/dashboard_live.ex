defmodule LeniesWeb.DashboardLive do
  @moduledoc """
  Main dashboard for monitoring the Lenies sandbox.

  Layout:
  - **Left** : World canvas, full-height. Owns pan/zoom/dblclick — clicking
    a Lenie cell opens its codeome editor; the canvas dims every other
    species when one row in the species table is selected.
  - **Right top** : Telemetry + species table + (when a row is selected)
    species inspector.
  - **Right bottom** : Controls + Tuning (delegated to
    `LeniesWeb.ControlsPanelComponent`).

  Only the world canvas and telemetry/species panels re-render on tick;
  controls live in a LiveComponent so form/input state is preserved.
  """

  use LeniesWeb, :live_view

  alias Lenies.SpeciesColor
  alias LeniesWeb.GridRenderer

  # Whitelist of clickable species-table columns -> the sort key. Guards
  # `handle_event("sort_species", ...)` against arbitrary input.
  @sortable_columns %{
    "seed" => :seed,
    "size" => :size,
    "cost" => :cost,
    "gain" => :gain,
    "population" => :population,
    "avg_generation" => :avg_generation
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:control")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:fx")
    end

    grid = Lenies.Config.grid_size()
    {species, all_species, species_total} = aggregate_with_top(10)

    sort_by = :population
    sort_dir = :desc

    socket =
      socket
      |> assign(:grid, grid)
      |> assign(:tick_count, 0)
      |> assign(:layers_visible, %{lenies: true, resource: true, carcass: true})
      |> assign(:throttle_counter, 0)
      |> assign(:latest, nil)
      |> assign(:species, species)
      |> assign(:species_total, species_total)
      |> assign(:all_species, all_species)
      |> assign(:selected_hash, nil)
      |> assign(:selected_species_record, nil)
      |> assign(:inspector_dirty, false)
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)
      |> stream_configure(:species_table, dom_id: fn sp -> "species-row-#{sp.hash}" end)
      |> stream(:species_table, sort_species(all_species, sort_by, sort_dir))

    # Push an initial frame as soon as the websocket is connected so the
    # canvas isn't black between mount and the next throttled tick
    # (especially after navigating back from the editor).
    socket =
      if connected?(socket) do
        payload = GridRenderer.encode_payload(grid)
        push_event(socket, "render_frame", payload)
      else
        socket
      end

    {:ok, socket}
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
      <Layouts.flash_group flash={@flash} />
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
            phx-hook="AudioToggle"
            phx-update="ignore"
            type="button"
            title="Toggle audio feedback"
            class="text-[10px] px-2 py-1 border border-cyan-500/40 hover:border-cyan-300 hover:text-cyan-200"
          >
            ♪ AUDIO
          </button>
        </div>
      </header>

      <div class="flex-1 flex gap-3 min-h-0">
        <section class="panel p-3 flex flex-col gap-2 min-h-0 shrink-0 dashboard-map-pane">
          <h2 class="text-xs">▮ World</h2>
          <div
            id="conjugation-log"
            phx-update="ignore"
            class="conjugation-log text-[10px] font-mono leading-tight overflow-hidden whitespace-nowrap"
          >
          </div>
          <%!-- phx-update="ignore" keeps morphdom from patching the canvas
                BITMAP; the element's own attributes (data-show-*,
                data-highlight-hue) are still morphed on every render so
                the hook's updated() picks them up immediately. --%>
          <div class="dashboard-map-frame">
            <canvas
              id="grid-canvas"
              phx-hook="GridCanvas"
              phx-update="ignore"
              data-grid-width={elem(@grid, 0)}
              data-grid-height={elem(@grid, 1)}
              data-show-lenies={@layers_visible.lenies}
              data-show-resource={@layers_visible.resource}
              data-show-carcass={@layers_visible.carcass}
              data-highlight-hue={highlight_hue(@selected_hash)}
              width={elem(@grid, 0) * 2}
              height={elem(@grid, 1) * 2}
              class="dashboard-map-canvas"
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
              <span>Detritus</span>
            </label>
          </div>
          <p class="dashboard-map-hint">
            scroll: zoom · drag: pan · click: focus · dblclick on a Lenie: edit codeome
          </p>
        </section>

        <div class="flex-1 grid grid-rows-[minmax(0,1fr)_auto] gap-3 min-h-0 min-w-0">
          <div class="flex gap-3 min-h-0 min-w-0">
            <div class="flex-1 grid grid-rows-[auto_minmax(0,1fr)] gap-3 min-h-0 min-w-0">
              <div class="panel p-3 flex flex-col gap-2 min-h-0">
                <h2 class="text-xs">▮ World totals</h2>
                <% latest = @latest || %{population: 0, total_resource: 0, total_carcass: 0} %>
                <div class="grid grid-cols-3 gap-2 text-[11px]">
                  <div class="border border-cyan-500/30 px-2 py-1">
                    <div class="opacity-60">Population</div>
                    <div class="text-cyan-300 font-bold tabular-nums text-base">
                      {format_count(latest.population)}
                    </div>
                  </div>
                  <div class="border border-emerald-500/30 px-2 py-1">
                    <div class="opacity-60">Resources</div>
                    <div
                      class="text-emerald-300 font-bold tabular-nums text-base"
                      title={"#{latest.total_resource}"}
                    >
                      {format_count(latest.total_resource)}
                    </div>
                  </div>
                  <div class="border border-rose-500/30 px-2 py-1">
                    <div class="opacity-60">Detritus</div>
                    <div
                      class="text-rose-300 font-bold tabular-nums text-base"
                      title={"#{latest.total_carcass}"}
                    >
                      {format_count(latest.total_carcass)}
                    </div>
                  </div>
                </div>
              </div>

              <div class="panel p-3 flex flex-col gap-2 min-h-0">
                <h2 class="text-xs">▮ {@species_total} species</h2>
                <div class="flex-1 min-h-0 overflow-auto">
                  <table class="w-full text-[11px] tabular-nums">
                    <thead class="text-cyan-300/80 sticky top-0 bg-slate-950/80">
                      <tr>
                        <th class="text-left py-1 pr-4 whitespace-nowrap">Hash</th>
                        <th
                          class="text-left py-1 w-full cursor-pointer select-none hover:text-cyan-200"
                          phx-click="sort_species"
                          phx-value-col="seed"
                          title="Seed of origin — bare seed name when the species' codeome still matches the pristine seed; prefixed with 'evolved from' once mutations have drifted it. Click to sort."
                        >
                          Seed{sort_arrow(@sort_by, @sort_dir, :seed)}
                        </th>
                        <th
                          class="text-right py-1 pl-3 whitespace-nowrap cursor-pointer select-none hover:text-cyan-200"
                          phx-click="sort_species"
                          phx-value-col="size"
                          title="Codeome length (opcodes). Click to sort."
                        >
                          Size{sort_arrow(@sort_by, @sort_dir, :size)}
                        </th>
                        <th
                          class="text-right py-1 pl-3 whitespace-nowrap cursor-pointer select-none hover:text-cyan-200"
                          phx-click="sort_species"
                          phx-value-col="cost"
                          title="Static energy cost for one linear pass through the codeome. Click to sort."
                        >
                          Cost{sort_arrow(@sort_by, @sort_dir, :cost)}
                        </th>
                        <th
                          class="text-right py-1 pl-3 whitespace-nowrap cursor-pointer select-none hover:text-cyan-200"
                          phx-click="sort_species"
                          phx-value-col="gain"
                          title="Max energy gain for one linear pass (all eat/attack succeed). Click to sort."
                        >
                          Gain{sort_arrow(@sort_by, @sort_dir, :gain)}
                        </th>
                        <th
                          class="text-right py-1 pl-3 whitespace-nowrap cursor-pointer select-none hover:text-cyan-200"
                          phx-click="sort_species"
                          phx-value-col="population"
                          title="Population. Click to sort."
                        >
                          Pop{sort_arrow(@sort_by, @sort_dir, :population)}
                        </th>
                        <th
                          class="text-right py-1 pl-3 whitespace-nowrap cursor-pointer select-none hover:text-cyan-200"
                          phx-click="sort_species"
                          phx-value-col="avg_generation"
                          title="Average generation. Click to sort."
                        >
                          Gen{sort_arrow(@sort_by, @sort_dir, :avg_generation)}
                        </th>
                      </tr>
                    </thead>
                    <tbody id="species-rows" phx-update="stream">
                      <tr
                        :for={{dom_id, sp} <- @streams.species_table}
                        id={dom_id}
                        class={[
                          "hover:bg-cyan-500/10 cursor-pointer",
                          @selected_hash == sp.hash && "bg-cyan-500/20 ring-1 ring-cyan-400"
                        ]}
                        phx-click="select_species"
                        phx-value-hash={sp.hash}
                      >
                        <td class="py-0.5 pr-4 whitespace-nowrap">
                          <div class="flex items-center gap-1.5">
                            <span
                              class="inline-block w-2 h-2 shrink-0"
                              style={"background:#{Lenies.SpeciesColor.hex(sp.hash)}"}
                            >
                            </span>
                            <span class="text-cyan-400">
                              {String.slice(sp.hash, 0..7)}
                            </span>
                          </div>
                        </td>
                        <td class="py-0.5 opacity-80">
                          {format_seed_origin(sp)}<span
                            :if={carried_plasmids(sp) != []}
                            class="ml-1 text-[9px] text-yellow-300/80"
                          >+ {Enum.join(carried_plasmids(sp), ", ")}</span>
                        </td>
                        <td class="text-right pl-3 whitespace-nowrap">{sp.size}</td>
                        <td class="text-right pl-3 whitespace-nowrap text-rose-300">{format_energy(sp.cost)}</td>
                        <td class="text-right pl-3 whitespace-nowrap text-emerald-300">{format_energy(sp.max_gain)}</td>
                        <td class="text-right pl-3 whitespace-nowrap">{sp.population}</td>
                        <td class="text-right pl-3 whitespace-nowrap">{Float.round(sp.avg_generation, 2)}</td>
                      </tr>
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

          <.live_component
            module={LeniesWeb.ControlsPanelComponent}
            id="controls"
            current_scope={@current_scope}
          />
        </div>
      </div>
    </div>
    """
  end

  # Maps the selected species hash to the 0..255 hue byte that the canvas
  # reads from `data-highlight-hue`. 0 means "no highlight" so the hook
  # renders every cell at full intensity.
  defp highlight_hue(nil), do: 0
  defp highlight_hue(hash) when is_binary(hash), do: SpeciesColor.hue_byte(hash)

  @impl true
  def handle_event("select_species", %{"hash" => hash}, socket) do
    new_hash =
      if socket.assigns.selected_hash == hash do
        nil
      else
        hash
      end

    %{all_species: all_species, sort_by: sort_by, sort_dir: sort_dir} = socket.assigns

    socket =
      socket
      |> assign(:selected_hash, new_hash)
      |> assign(
        :selected_species_record,
        find_selected_record(new_hash, all_species)
      )
      |> stream(:species_table, sort_species(all_species, sort_by, sort_dir), reset: true)

    socket =
      if is_nil(new_hash),
        do: assign(socket, :inspector_dirty, false),
        else: socket

    {:noreply, socket}
  end

  def handle_event("toggle_layer", %{"layer" => layer}, socket)
      when layer in ~w(lenies resource carcass) do
    layer_atom = String.to_existing_atom(layer)
    new_visible = Map.update!(socket.assigns.layers_visible, layer_atom, &(!&1))
    {:noreply, assign(socket, :layers_visible, new_visible)}
  end

  def handle_event("toggle_layer", _params, socket), do: {:noreply, socket}

  def handle_event("sort_species", %{"col" => col}, socket) do
    case Map.fetch(@sortable_columns, col) do
      {:ok, new_by} ->
        {by, dir} =
          if socket.assigns.sort_by == new_by do
            {new_by, toggle_dir(socket.assigns.sort_dir)}
          else
            {new_by, default_sort_dir(new_by)}
          end

        socket =
          socket
          |> assign(sort_by: by, sort_dir: dir)
          |> stream(
            :species_table,
            sort_species(socket.assigns.all_species, by, dir),
            reset: true
          )

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  # Pushed by the GridCanvas hook on dblclick. We resolve the cell to a
  # Lenie via the :cells / :lenies ETS tables and navigate to its
  # editor; misses (empty cells) are a silent no-op.
  def handle_event("select_lenie_at_cell", %{"x" => x, "y" => y}, socket)
      when is_integer(x) and is_integer(y) do
    case lookup_lenie_at_cell(x, y) do
      {:ok, hash} -> {:noreply, push_navigate(socket, to: ~p"/editor/edit/#{hash}")}
      :error -> {:noreply, socket}
    end
  end

  # Mousemove on the world map fires this event whenever the hovered
  # buffer cell changes (the JS hook debounces by tracked cell). The
  # response carries seed_origin / age / energy for the Lenie at that
  # cell, or `present: false` if the cell is empty — the JS then shows
  # or hides the tooltip accordingly. The requested {x, y} are echoed
  # back so a stale response (cursor already moved to another cell) can
  # be discarded on the client.
  def handle_event("request_lenie_hover", %{"x" => x, "y" => y}, socket)
      when is_integer(x) and is_integer(y) do
    payload = lenie_hover_payload(x, y)
    {:noreply, push_event(socket, "lenie_hover_info", payload)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp lookup_lenie_at_cell(x, y) do
    with [{_, %{lenie_id: id}}] when is_binary(id) <- :ets.lookup(:cells, {x, y}),
         [{^id, lenie_meta}] <- :ets.lookup(:lenies, id),
         hash when is_binary(hash) <- Map.get(lenie_meta, :codeome_hash) do
      {:ok, hash}
    else
      _ -> :error
    end
  end

  defp lenie_hover_payload(x, y) do
    with [{_, %{lenie_id: id}}] when is_binary(id) <- :ets.lookup(:cells, {x, y}),
         [{^id, snap}] <- :ets.lookup(:lenies, id) do
      %{
        x: x,
        y: y,
        present: true,
        seed_origin: Map.get(snap, :seed_origin),
        age: Map.get(snap, :age, 0),
        energy: trunc(Map.get(snap, :energy, 0.0)),
        codeome_hash: Map.get(snap, :codeome_hash)
      }
    else
      _ -> %{x: x, y: y, present: false}
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
      {species, all_species, species_total} = aggregate_with_top(10)
      %{sort_by: sort_by, sort_dir: sort_dir} = socket.assigns

      socket =
        socket
        |> assign(:latest, List.last(Lenies.Telemetry.history(:last_n, 1)))
        |> assign(:species, species)
        |> assign(:species_total, species_total)
        |> assign(:all_species, all_species)
        |> assign(
          :selected_species_record,
          find_selected_record(socket.assigns.selected_hash, all_species)
        )
        |> maybe_clear_selected_species(all_species)
        |> stream(:species_table, sort_species(all_species, sort_by, sort_dir), reset: true)

      payload = GridRenderer.encode_payload(socket.assigns.grid)
      {:noreply, push_event(socket, "render_frame", payload)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:sterilized, _ts}, socket) do
    {species, all_species, species_total} = aggregate_with_top(10)
    %{sort_by: sort_by, sort_dir: sort_dir} = socket.assigns

    socket =
      socket
      |> assign(:species, species)
      |> assign(:species_total, species_total)
      |> assign(:all_species, all_species)
      |> stream(:species_table, sort_species(all_species, sort_by, sort_dir), reset: true)

    payload = GridRenderer.encode_payload(socket.assigns.grid)
    {:noreply, push_event(socket, "render_frame", payload)}
  end

  def handle_info({:inspector_dirty, dirty}, socket) do
    {:noreply, assign(socket, :inspector_dirty, dirty)}
  end

  def handle_info({:conjugation, %{} = info}, socket) do
    {sender_x, sender_y} = info.sender_pos
    {receiver_x, receiver_y} = info.receiver_pos

    {:noreply,
     push_event(socket, "fx_conjugation", %{
       sender: %{x: sender_x, y: sender_y},
       receiver: %{x: receiver_x, y: receiver_y},
       donor_seed: info.donor_seed,
       recipient_seed: info.recipient_seed,
       plasmid_label: plasmid_label(info.plasmid_hash)
     })}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Recognise the two shipped seed plasmids by their phash2; fall back to
  # the hex hash for unknown payloads.
  @twitch_hash :erlang.phash2(Lenies.Codeomes.MinimalReplicator.plasmid(), 16_777_216)
               |> Integer.to_string(16)
               |> String.pad_leading(6, "0")
  @sprint_hash :erlang.phash2(Lenies.Codeomes.Carnivore.plasmid(), 16_777_216)
               |> Integer.to_string(16)
               |> String.pad_leading(6, "0")

  defp plasmid_label(@twitch_hash), do: "Twitch"
  defp plasmid_label(@sprint_hash), do: "Sprint"
  defp plasmid_label(hash) when is_binary(hash), do: hash

  # Human labels for the plasmids a species carries in its buffer (from the
  # representative Lenie's snapshot). Used to annotate the species-table seed
  # name with the conjugation-acquired plasmid(s).
  defp carried_plasmids(%{plasmids: plasmids}) when is_list(plasmids) do
    plasmids
    |> Enum.map(&plasmid_label(plasmid_hash(&1)))
    |> Enum.uniq()
  end

  defp carried_plasmids(_), do: []

  defp plasmid_hash(opcodes) do
    :erlang.phash2(opcodes, 16_777_216)
    |> Integer.to_string(16)
    |> String.pad_leading(6, "0")
  end

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

  # Pristine-codeome hashes for every built-in seed, computed once at
  # module load. Custom user seeds aren't covered because their pristine
  # codeome lives in the per-user `Lenies.Collection` (the user could even
  # edit and save back at any time) — for those we always show the "evolved
  # from" form because we can't reliably know what "pristine" means.
  @builtin_pristine_hashes Map.new(
                             Lenies.Seeds.all(),
                             fn s -> {s.name, Lenies.Codeome.hash(s.codeome)} end
                           )

  # Renders the Seed column. Three cases:
  #   - seed_origin is nil → "—" (Lenie pre-feature or untracked).
  #   - the species' hash matches the pristine hash of `seed_origin` → bare
  #     seed name (Lenie hasn't drifted from its seed).
  #   - otherwise → "evolved from <seed_origin>" (mutation / copy-error
  #     descendant).
  defp format_seed_origin(%{seed_origin: nil}), do: "—"

  defp format_seed_origin(%{seed_origin: origin, hash: hash}) do
    case Map.get(@builtin_pristine_hashes, origin) do
      ^hash -> origin
      _ -> "evolved from " <> origin
    end
  end

  defp format_seed_origin(_), do: "—"

  # Order the species rows by the active column/direction. `Enum.sort_by/3`
  # handles both numeric keys and the (downcased) seed-name string via term
  # ordering. Called from mount and event/tick handlers (not render) so the
  # stream is always pre-sorted before being sent to the client.
  defp sort_species(species, sort_by, sort_dir) do
    Enum.sort_by(species, sort_key_fun(sort_by), sort_dir)
  end

  defp sort_key_fun(:seed), do: fn sp -> sp |> format_seed_origin() |> String.downcase() end
  defp sort_key_fun(:size), do: & &1.size
  defp sort_key_fun(:cost), do: & &1.cost
  defp sort_key_fun(:gain), do: & &1.max_gain
  defp sort_key_fun(:population), do: & &1.population
  defp sort_key_fun(:avg_generation), do: & &1.avg_generation

  # Sort indicator next to the active column header.
  defp sort_arrow(active, :asc, active), do: " ▲"
  defp sort_arrow(active, :desc, active), do: " ▼"
  defp sort_arrow(_by, _dir, _col), do: ""

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc

  # Seed is alphabetical (asc) by default; numeric columns lead with the
  # largest value (desc), which is what a user scanning for the dominant /
  # most-expensive species expects.
  defp default_sort_dir(:seed), do: :asc
  defp default_sort_dir(_), do: :desc

  # Compact energy display for the species table: integer when whole,
  # one decimal otherwise. Avoids `0.0` clutter for codeomes with no
  # eat/attack opcodes and keeps the column width predictable.
  defp format_energy(n) when is_integer(n), do: Integer.to_string(n)

  defp format_energy(n) when is_float(n) do
    rounded = Float.round(n, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end

  defp format_energy(_), do: "0"

  # When the species the user is inspecting falls out of the active set
  # (extinct or pushed out of the top-N), close the inspector and drop
  # the canvas highlight so we don't keep dimming the map against a
  # ghost selection.
  defp maybe_clear_selected_species(socket, species) do
    case socket.assigns.selected_hash do
      nil ->
        socket

      hash ->
        if Enum.any?(species, &(&1.hash == hash)) do
          socket
        else
          socket
          |> assign(:selected_hash, nil)
          |> assign(:selected_species_record, nil)
          |> assign(:inspector_dirty, false)
        end
    end
  end
end
