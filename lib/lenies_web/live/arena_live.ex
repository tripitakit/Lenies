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
  import LeniesWeb.WorldLiveShared

  # Whitelist of clickable species-table columns -> the sort key. Guards
  # `handle_event("sort_species", ...)` against arbitrary input.
  @sortable_columns %{
    "seed" => :seed,
    "size" => :size,
    "cost" => :cost,
    "gain" => :gain,
    "net" => :net,
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
      |> assign(:throttle_counter, 0)
      |> assign(:latest, nil)
      |> assign(:species, species)
      |> assign(:species_total, species_total)
      |> assign(:all_species, all_species)
      |> assign(:selected_hash, nil)
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)
      |> assign(:species_sig, nil)
      |> assign(:owned_hashes, owned_hashes(socket))
      |> assign(:killing_hash, nil)
      |> assign(:saving_hash, nil)
      |> assign(:save_error, nil)
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="lenies-dashboard h-full w-full overflow-hidden flex flex-col p-3 gap-3">
      <Layouts.flash_group flash={@flash} />
      <header class="flex items-center justify-between px-2 shrink-0">
        <h1 class="text-lg font-bold tracking-widest">⬡ LENIES · ARENA</h1>
        <% latest = @latest || %{population: 0, total_resource: 0, total_carcass: 0} %>
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
            POP
            <span class="text-cyan-300 font-bold tabular-nums">
              {format_count(latest.population)}
            </span>
          </span>
          <span class="opacity-70">
            RES
            <span class="text-emerald-300 font-bold tabular-nums" title={"#{latest.total_resource}"}>
              {format_count(latest.total_resource)}
            </span>
          </span>
          <span class="opacity-70">
            DET
            <span class="text-rose-300 font-bold tabular-nums" title={"#{latest.total_carcass}"}>
              {format_count(latest.total_carcass)}
            </span>
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
            ♪ SndFx
          </button>
        </div>
      </header>

      <div class="flex-1 flex gap-3 min-h-0">
        <section class="panel p-2 flex flex-col gap-2 min-h-0 shrink-0 dashboard-map-pane">
          <h2 class="text-xs flex items-center gap-1.5">
            <span>▮ Arena</span>
            <span
              class="opacity-40 hover:opacity-80 cursor-help text-[10px] border border-slate-500/40 rounded-full w-4 h-4 inline-flex items-center justify-center"
              title="scroll: zoom · drag: pan · click: focus"
            >
              ?
            </span>
          </h2>
          <div
            id="conjugation-log"
            phx-update="ignore"
            class="conjugation-log text-[10px] font-mono leading-tight overflow-hidden whitespace-nowrap"
          >
          </div>
          <%!-- phx-update="ignore" keeps morphdom from patching the canvas
                BITMAP; data-highlight-hue is still morphed on every render so
                the hook's updated() picks it up immediately. data-show-* are
                hardcoded true (all layers always visible). --%>
          <div class="dashboard-map-frame">
            <canvas
              id="grid-canvas"
              phx-hook="GridCanvas"
              phx-update="ignore"
              data-grid-width={elem(@grid, 0)}
              data-grid-height={elem(@grid, 1)}
              data-show-lenies="true"
              data-show-resource="true"
              data-show-carcass="true"
              data-highlight-hue={highlight_hue(handle_from_assigns(assigns), @selected_hash)}
              width={elem(@grid, 0) * 2}
              height={elem(@grid, 1) * 2}
              class="dashboard-map-canvas"
            >
            </canvas>
          </div>
        </section>

        <div class="flex-1 grid grid-rows-[minmax(0,1fr)_auto] gap-2 min-h-0 min-w-0">
          <div class="flex gap-3 min-h-0 min-w-0">
            <div class="flex-1 flex flex-col min-h-0 min-w-0">
              <div class="panel p-2 flex-1 flex flex-col gap-2 min-h-0">
                <h2 class="text-xs">▮ {@species_total} species</h2>

                <div
                  :if={@killing_hash}
                  class="flex items-center gap-2 p-2 border border-rose-500/60 bg-rose-950/40"
                >
                  <span class="text-[11px] text-rose-200">
                    Kill your members of species {String.slice(@killing_hash, 0..7)}?
                  </span>
                  <button
                    type="button"
                    phx-click="kill_species_confirm"
                    class="text-[11px] px-2 py-0.5 border border-rose-500 bg-rose-700/40 text-rose-100 hover:bg-rose-600/60"
                  >
                    Confirm
                  </button>
                  <button
                    type="button"
                    phx-click="kill_species_cancel"
                    class="text-[11px] px-2 py-0.5 border border-slate-500 bg-slate-800 hover:bg-slate-700"
                  >
                    Cancel
                  </button>
                </div>

                <div
                  :if={@saving_hash}
                  class="flex flex-col gap-1 p-2 border border-emerald-500/60 bg-emerald-950/40"
                >
                  <form
                    phx-submit="save_species_confirm"
                    class="flex items-center gap-2 w-full"
                  >
                    <span class="text-[11px] text-emerald-200 whitespace-nowrap">
                      Save species {String.slice(@saving_hash, 0..7)} as:
                    </span>
                    <input
                      type="text"
                      name="name"
                      autocomplete="off"
                      autofocus
                      placeholder="name"
                      class="flex-1 min-w-0 text-[11px] px-2 py-0.5 bg-slate-900 border border-slate-600 text-cyan-100"
                    />
                    <button
                      type="submit"
                      class="text-[11px] px-2 py-0.5 border border-emerald-500 bg-emerald-700/40 text-emerald-100 hover:bg-emerald-600/60"
                    >
                      Save
                    </button>
                    <button
                      type="button"
                      phx-click="save_species_cancel"
                      class="text-[11px] px-2 py-0.5 border border-slate-500 bg-slate-800 hover:bg-slate-700"
                    >
                      Cancel
                    </button>
                  </form>
                  <span :if={@save_error} class="text-[11px] text-rose-300">
                    {@save_error}
                  </span>
                </div>

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
                          title="Energy to run the codeome once top-to-bottom, no loops taken (one linear pass). Click to sort."
                        >
                          Cost/pass{sort_arrow(@sort_by, @sort_dir, :cost)}
                        </th>
                        <th
                          class="text-right py-1 pl-3 whitespace-nowrap cursor-pointer select-none hover:text-cyan-200"
                          phx-click="sort_species"
                          phx-value-col="gain"
                          title="Best-case energy from that single pass if EVERY eat/attack lands — real gain is lower. Click to sort."
                        >
                          Max gain{sort_arrow(@sort_by, @sort_dir, :gain)}
                        </th>
                        <th
                          class="text-right py-1 pl-3 whitespace-nowrap cursor-pointer select-none hover:text-cyan-200"
                          phx-click="sort_species"
                          phx-value-col="net"
                          title="Max gain − Cost for one linear pass. Positive (green) = the pass pays for itself in the best case; negative (red) = it can't. Click to sort."
                        >
                          Net{sort_arrow(@sort_by, @sort_dir, :net)}
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
                        <th class="text-right py-1 pl-3 whitespace-nowrap"></th>
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
                            :if={sp.plasmid_max > 0}
                            class="ml-1 text-[9px] text-yellow-300/80"
                          >+ {plasmid_badge(sp.plasmid_min, sp.plasmid_max)}</span>
                        </td>
                        <td class="text-right pl-3 whitespace-nowrap">{sp.size}</td>
                        <td class="text-right pl-3 whitespace-nowrap text-rose-300">
                          {format_energy(sp.cost)}
                        </td>
                        <td class="text-right pl-3 whitespace-nowrap text-emerald-300">
                          {format_energy(sp.max_gain)}
                        </td>
                        <td class={[
                          "text-right pl-3 whitespace-nowrap",
                          net_color(sp.max_gain - sp.cost)
                        ]}>
                          {format_net(sp.max_gain - sp.cost)}
                        </td>
                        <td class="text-right pl-3 whitespace-nowrap">{sp.population}</td>
                        <td class="text-right pl-3 whitespace-nowrap">
                          {Float.round(sp.avg_generation, 2)}
                        </td>
                        <td class="text-right pl-3 whitespace-nowrap">
                          <button
                            :if={MapSet.member?(@owned_hashes, sp.hash)}
                            type="button"
                            phx-click="save_species_init"
                            phx-value-hash={sp.hash}
                            class="text-[10px] px-1.5 py-0.5 mr-1 border border-emerald-500/50 text-emerald-300 hover:bg-emerald-500/10"
                            title="Save this species to your collection"
                          >
                            SAVE
                          </button>
                          <button
                            :if={MapSet.member?(@owned_hashes, sp.hash)}
                            type="button"
                            phx-click="kill_species_init"
                            phx-value-hash={sp.hash}
                            class="text-[10px] px-1.5 py-0.5 border border-rose-500/50 text-rose-300 hover:bg-rose-500/10"
                            title="Kill your members of this species"
                          >
                            KILL
                          </button>
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

  def handle_event("kill_species_init", %{"hash" => hash}, socket) do
    {:noreply, assign(socket, killing_hash: hash, saving_hash: nil, save_error: nil)}
  end

  def handle_event("kill_species_cancel", _params, socket) do
    {:noreply, assign(socket, :killing_hash, nil)}
  end

  def handle_event("kill_species_confirm", _params, socket) do
    case {socket.assigns[:current_scope], socket.assigns.killing_hash} do
      {%{user: %{} = user}, hash} when is_binary(hash) ->
        {:ok, _killed} = Lenies.Arena.kill_species(user, hash)
        # Arena broadcasts :arena_lineage_changed; the species table refreshes
        # on the next tick (which recomputes owned_hashes and re-streams).
        {:noreply, assign(socket, :killing_hash, nil)}

      _ ->
        {:noreply, assign(socket, :killing_hash, nil)}
    end
  end

  def handle_event("save_species_init", %{"hash" => hash}, socket) do
    {:noreply, assign(socket, saving_hash: hash, save_error: nil, killing_hash: nil)}
  end

  def handle_event("save_species_cancel", _params, socket) do
    {:noreply, assign(socket, saving_hash: nil, save_error: nil)}
  end

  def handle_event("save_species_confirm", %{"name" => name}, socket) do
    %{current_scope: scope, world_handle: handle, saving_hash: hash} = socket.assigns

    with %{user: %{} = user} <- scope,
         h when is_binary(h) <- hash,
         own_members = own_species_members(Lenies.Species.for_hash(handle, h), user.id),
         %{} = snap <- pick_max_plasmid_member(own_members) do
      attrs = %{
        name: name,
        color_hex: SpeciesColor.hex(handle, h),
        energy_default: 10_000.0,
        opcodes: Enum.map(snap.codeome, &Atom.to_string/1),
        plasmids:
          Enum.map(snap.plasmids, fn %Lenies.Plasmid{opcodes: ops} ->
            %{opcodes: Enum.map(ops, &Atom.to_string/1)}
          end)
      }

      case Lenies.Collection.create_codeome(user, attrs) do
        {:ok, _codeome} ->
          {:noreply,
           socket
           |> assign(saving_hash: nil, save_error: nil)
           |> put_flash(:info, "Saved “#{name}” to your collection.")}

        {:error, :name_taken} ->
          {:noreply, assign(socket, :save_error, "Name “#{name}” already taken.")}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, assign(socket, :save_error, "Invalid codeome — try another name.")}
      end
    else
      _ -> {:noreply, assign(socket, saving_hash: nil, save_error: nil)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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

  def handle_info({tag, %{} = info}, socket) when tag in [:division, :death, :predation] do
    {name, payload} = fx_client_event({tag, info})
    {:noreply, push_event(socket, name, payload)}
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

  # Singular/plural for the species-table plasmid count annotation.
  defp plasmid_word(1), do: "plasmid"
  defp plasmid_word(_), do: "plasmids"

  # Species-table load annotation: "N plasmids" when the whole species carries
  # the same count, "min–max plasmids" when members differ (segregational loss).
  defp plasmid_badge(n, n), do: "#{n} #{plasmid_word(n)}"
  defp plasmid_badge(min, max), do: "#{min}–#{max} plasmids"

  # Format large counters (resources / carcasses) so the user can read
  # them at a glance: thousand-separated below 1k, then k/M/B suffixes
  # so a runaway carcass_decay = 0 simulation doesn't render as an
  # unreadable 14-digit number that looks like a bug.
  # Re-stream the species table only when its rendered content would actually
  # change. Skips the full `reset: true` re-patch on a stable / paused world.
  # The signature folds in `selected_hash` because the row highlight class
  # depends on it.
  defp maybe_stream_species(socket, all_species) do
    sorted = sort_species(all_species, socket.assigns.sort_by, socket.assigns.sort_dir)
    owned = owned_hashes(socket)
    # Fold `owned` into the signature so the per-row KILL affordance refreshes
    # when the user's ownership changes (seed/kill/apoptosis), even if the
    # species set itself is otherwise unchanged.
    sig = :erlang.phash2({socket.assigns.selected_hash, owned, sorted})

    if sig == socket.assigns.species_sig do
      socket
    else
      socket
      |> assign(:species_sig, sig)
      |> assign(:owned_hashes, owned)
      |> stream(:species_table, sorted, reset: true)
    end
  end

  # MapSet of codeome hashes the current viewer owns alive members of in the
  # Arena (empty for anonymous viewers). Drives the per-row KILL button.
  defp owned_hashes(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: id}} -> MapSet.new(Lenies.Arena.owned_species_hashes(id))
      _ -> MapSet.new()
    end
  end

  # Pick the living member of a species carrying the most plasmids (ties: the
  # first encountered). `for_hash/2` returns `{id, snapshot}` tuples; we save
  # the snapshot's codeome + plasmids. Returns nil when no members are alive.
  defp pick_max_plasmid_member([]), do: nil

  defp pick_max_plasmid_member(members) do
    {_id, snap} =
      Enum.max_by(members, fn {_id, snap} -> length(Map.get(snap, :plasmids, [])) end)

    snap
  end

  # Keep only the snapshots seeded by `user_id`. SAVE captures the user's own
  # evolved member, never another seeder's — two users can seed an identical
  # codeome (same hash), so `Species.for_hash/2` alone is not ownership-scoped.
  # Mirrors `Lenies.Arena.kill_species`, which is likewise per-user scoped.
  defp own_species_members(members, user_id) do
    Enum.filter(members, fn {_id, snap} -> Map.get(snap, :seeder_user_id) == user_id end)
  end

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
