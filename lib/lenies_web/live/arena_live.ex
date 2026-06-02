defmodule LeniesWeb.ArenaLive do
  @moduledoc """
  Public LiveView for the singleton `:arena` world at `/`.

  Mirrors `LeniesWeb.DashboardLive` in structure (canvas, world totals,
  species table) but for the shared, read-only Arena:

  - Anonymous-friendly: `current_scope` may be nil/userless.
  - Lifecycle is mediated by `Lenies.Arena.attach_viewer/0` — first attach
    starts/restores the world, last detach (after a grace window) snapshots
    and stops it.
  - Subscribes to `world:arena:tick|control|fx` plus `arena:presence` (for
    the viewer count badge) and `arena:manager_up` (to re-attach if the
    Arena manager restarts).
  - The right-hand controls slot is a placeholder pending Task 14
    (`LeniesWeb.ArenaControlsComponent`).
  - The inspector "Edit" affordance is removed: Arena is read-only.
  """

  use LeniesWeb, :live_view

  alias Lenies.SpeciesColor
  alias LeniesWeb.Presence

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

  @world_id :arena
  @presence_topic "arena:presence"

  @impl true
  def mount(_params, _session, socket) do
    :ok = Lenies.Arena.attach_viewer()
    {:ok, world_handle} = Lenies.Worlds.handle(@world_id)

    lineage_count =
      case socket.assigns[:current_scope] do
        %{user: %{id: id}} -> Lenies.Arena.lineage_count(id)
        _ -> 0
      end

    session_id = derive_session_id(socket)

    if connected?(socket) do
      prefix = world_handle.pubsub_prefix
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:tick")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:control")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:fx")
      # Canvas frames are encoded once per world by Lenies.WorldRenderer and
      # broadcast here — every Arena viewer shares one encode instead of N.
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:frame")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "arena:manager_up")
      Phoenix.PubSub.subscribe(Lenies.PubSub, @presence_topic)
      {:ok, _ref} = Presence.track(self(), @presence_topic, session_id, %{})

      # Per sub-project #4: per-user PubSub topic — covers natural-death
      # lineage refresh AND multi-tab same-user sync (a Seed/Apoptosis in
      # tab A reaches tab B via the broadcast, not just the local
      # `send(self(), …)` from ArenaControlsComponent).
      case socket.assigns[:current_scope] do
        %{user: %{id: id}} ->
          Phoenix.PubSub.subscribe(Lenies.PubSub, "arena:user:#{id}")

        _ ->
          :ok
      end
    end

    grid = Lenies.Config.grid_size()
    {species, all_species, species_total} = aggregate_with_top(world_handle, 10)

    sort_by = :population
    sort_dir = :desc

    socket =
      socket
      |> assign(:world_id, @world_id)
      |> assign(:world_handle, world_handle)
      |> assign(:session_id, session_id)
      |> assign(:viewer_count, viewer_count())
      |> assign(:lineage_count, lineage_count)
      |> assign(:grid, grid)
      |> assign(:tick_count, 0)
      |> assign(:layers_visible, %{lenies: true, resource: true, carcass: true})
      |> assign(:throttle_counter, 0)
      |> assign(:latest, nil)
      |> assign(:species, species)
      |> assign(:species_total, species_total)
      |> assign(:all_species, all_species)
      |> assign(:selected_hash, nil)
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)
      |> assign(:species_sig, nil)
      |> stream_configure(:species_table, dom_id: fn sp -> "species-row-#{sp.hash}" end)
      |> stream(:species_table, sort_species(all_species, sort_by, sort_dir))

    # Push an initial frame as soon as the websocket is connected so the
    # canvas isn't black between mount and the next broadcast frame. The
    # frame comes from the shared per-world renderer's cache — no per-socket
    # encode.
    socket =
      if connected?(socket) do
        case Lenies.WorldRenderer.current_frame(@world_id) do
          nil -> socket
          payload -> push_event(socket, "render_frame", payload)
        end
      else
        socket
      end

    {:ok, socket}
  end

  # Pull a stable per-tab identifier from the LV connect params (the
  # CSRF token rotates per session/tab) — falls back to a random id
  # for the initial disconnected mount so `track/4` always has a key.
  defp derive_session_id(socket) do
    case Phoenix.LiveView.get_connect_params(socket) do
      %{"_csrf_token" => token} when is_binary(token) -> token
      _ -> "anon-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    end
  end

  defp viewer_count, do: Presence.list(@presence_topic) |> map_size()

  # Returns {top_n, all_species, total_count} from a single Species.aggregate/1
  # pass. The Arena table uses `top_n`; `all_species` is kept for the species
  # inspector lookup parity with DashboardLive.
  defp aggregate_with_top(handle, n) do
    all = Lenies.Species.aggregate(handle)
    {Enum.take(all, n), all, length(all)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="lenies-dashboard h-full w-full overflow-hidden flex flex-col p-3 gap-3">
      <Layouts.flash_group flash={@flash} />
      <header class="flex items-center justify-between px-2 shrink-0">
        <h1 class="text-lg font-bold tracking-widest">⬡ LENIES · ARENA</h1>
        <div class="flex items-center gap-4 text-xs">
          <span class="viewers flex items-center gap-1.5">
            <span class="inline-block w-2 h-2 rounded-full bg-fuchsia-400 shadow-[0_0_8px_#e879f9]">
            </span>
            <span class="text-fuchsia-200 font-bold tabular-nums">{@viewer_count}</span>
            <span class="opacity-70">watching</span>
          </span>
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
          <h2 class="text-xs">▮ Arena</h2>
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
              data-highlight-hue={highlight_hue(handle_from_assigns(assigns), @selected_hash)}
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
            scroll: zoom · drag: pan · click: focus
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
                              style={"background:#{species_hex(handle_from_assigns(assigns), sp.hash)}"}
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
                        <td class="text-right pl-3 whitespace-nowrap text-rose-300">
                          {format_energy(sp.cost)}
                        </td>
                        <td class="text-right pl-3 whitespace-nowrap text-emerald-300">
                          {format_energy(sp.max_gain)}
                        </td>
                        <td class="text-right pl-3 whitespace-nowrap">{sp.population}</td>
                        <td class="text-right pl-3 whitespace-nowrap">
                          {Float.round(sp.avg_generation, 2)}
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>

            <%!-- Arena is read-only: no species inspector / Edit button.
                  Selecting a row still dims the canvas via :selected_hash. --%>
          </div>

          <aside class="arena-controls">
            <.live_component
              module={LeniesWeb.ArenaControlsComponent}
              id="arena-controls"
              current_scope={@current_scope}
              world_handle={@world_handle}
              lineage_count={@lineage_count}
            />
          </aside>
        </div>
      </div>
    </div>
    """
  end

  # Maps the selected species hash to the 0..255 hue byte that the canvas
  # reads from `data-highlight-hue`. 0 means "no highlight" so the hook
  # renders every cell at full intensity.
  defp highlight_hue(_handle, nil), do: 0
  defp highlight_hue(nil, _hash), do: 0

  defp highlight_hue(%Lenies.WorldHandle{} = handle, hash) when is_binary(hash),
    do: SpeciesColor.hue_byte(handle, hash)

  # Lookup the world handle from socket assigns. Arena mount always assigns
  # a %WorldHandle{} (attach starts the world synchronously); the nil clause
  # is a defensive fallback for any stale render path.
  defp handle_from_assigns(%{world_handle: %Lenies.WorldHandle{} = h}), do: h
  defp handle_from_assigns(_), do: nil

  # Compute the per-species hex color. Returns "#000000" if no World is
  # running (caller renders an empty/black swatch, not a crash).
  defp species_hex(nil, _hash), do: "#000000"
  defp species_hex(%Lenies.WorldHandle{} = handle, hash), do: SpeciesColor.hex(handle, hash)

  @impl true
  def handle_event("select_species", %{"hash" => hash}, socket) do
    new_hash =
      if socket.assigns.selected_hash == hash do
        nil
      else
        hash
      end

    %{all_species: all_species} = socket.assigns

    socket =
      socket
      |> assign(:selected_hash, new_hash)
      |> maybe_stream_species(all_species)

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

        all_species = socket.assigns.all_species

        socket =
          socket
          |> assign(sort_by: by, sort_dir: dir)
          |> maybe_stream_species(all_species)

        {:noreply, socket}

      :error ->
        {:noreply, socket}
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
    payload = lenie_hover_payload(socket.assigns.world_handle, x, y)
    {:noreply, push_event(socket, "lenie_hover_info", payload)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp lenie_hover_payload(handle, x, y) do
    with handle when not is_nil(handle) <- handle,
         [{_, %{lenie_id: id}}] when is_binary(id) <-
           :ets.lookup(handle.tables.cells, {x, y}),
         [{^id, snap}] <- :ets.lookup(handle.tables.lenies, id) do
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
  def handle_info({:tick, n, stats}, socket) do
    throttle = Application.get_env(:lenies, :dashboard_throttle_ticks, 5)
    new_counter = socket.assigns.throttle_counter + 1

    # `:latest` comes straight from the tick payload — no ETS history scan.
    # The canvas frame arrives via the shared renderer's {:frame, _}
    # broadcast, so the socket encodes nothing.
    socket =
      socket
      |> assign(:tick_count, n)
      |> assign(:throttle_counter, new_counter)
      |> assign(:latest, %{
        population: stats.population,
        total_resource: stats.total_resource,
        total_carcass: stats.total_carcass
      })

    if rem(new_counter, throttle) == 0 do
      {_species, all_species, species_total} =
        aggregate_with_top(socket.assigns.world_handle, 10)

      socket =
        socket
        |> assign(:species_total, species_total)
        |> assign(:all_species, all_species)
        |> maybe_clear_selected_species(all_species)
        |> maybe_stream_species(all_species)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Canvas frame broadcast by the shared per-world Lenies.WorldRenderer.
  def handle_info({:frame, payload}, socket) do
    {:noreply, push_event(socket, "render_frame", payload)}
  end

  def handle_info({:sterilized, _ts}, socket) do
    {_species, all_species, species_total} =
      aggregate_with_top(socket.assigns.world_handle, 10)

    socket =
      socket
      |> assign(:species_total, species_total)
      |> assign(:all_species, all_species)
      |> maybe_stream_species(all_species)

    {:noreply, socket}
  end

  # Mirrors Sandbox dashboard behaviour: on restore, push the fresh
  # stats into :latest immediately so a paused world doesn't render
  # zeros in the header until the next tick.
  def handle_info({:restored, _ts, stats}, socket) when is_map(stats) do
    {_species, all_species, species_total} =
      aggregate_with_top(socket.assigns.world_handle, 10)

    socket =
      socket
      |> assign(:latest, %{
        population: Map.get(stats, :population, 0),
        total_resource: Map.get(stats, :total_resource, 0),
        total_carcass: Map.get(stats, :total_carcass, 0)
      })
      |> assign(:species_total, species_total)
      |> assign(:all_species, all_species)
      |> maybe_stream_species(all_species)

    {:noreply, socket}
  end

  def handle_info(:arena_manager_up, socket) do
    :ok = Lenies.Arena.attach_viewer()
    {:noreply, socket}
  end

  def handle_info({:arena_lineage_changed, user_id}, socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: ^user_id}} ->
        {:noreply, assign(socket, :lineage_count, Lenies.Arena.lineage_count(user_id))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :viewer_count, viewer_count())}
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

  # Re-stream the species table only when its rendered content would actually
  # change. Skips the full `reset: true` re-patch on a stable / paused world.
  # The signature folds in `selected_hash` because the row highlight class
  # depends on it.
  defp maybe_stream_species(socket, all_species) do
    sorted = sort_species(all_species, socket.assigns.sort_by, socket.assigns.sort_dir)
    sig = :erlang.phash2({socket.assigns.selected_hash, sorted})

    if sig == socket.assigns.species_sig do
      socket
    else
      socket
      |> assign(:species_sig, sig)
      |> stream(:species_table, sorted, reset: true)
    end
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
          assign(socket, :selected_hash, nil)
        end
    end
  end
end
