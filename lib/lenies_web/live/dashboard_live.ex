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
  alias Lenies.World.Query
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

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    user_id = user.id
    world_id = Lenies.Sandboxes.world_id_for(user_id)

    :ok = Lenies.Sandboxes.attach(user_id)
    {:ok, world_handle} = Lenies.Worlds.handle(world_id)

    if connected?(socket) do
      prefix = world_handle.pubsub_prefix
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:tick")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:control")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:fx")
      # Canvas frames are encoded once per world by Lenies.WorldRenderer and
      # broadcast here — the socket no longer encodes the full grid itself.
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:frame")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "sandboxes:manager_up")
    end

    grid = Lenies.Config.grid_size()
    {species, all_species, species_total} = aggregate_with_top(world_handle, 10)

    sort_by = :population
    sort_dir = :desc

    socket =
      socket
      |> assign(:world_id, world_id)
      |> assign(:world_handle, world_handle)
      |> assign(:grid, grid)
      |> assign(:tick_count, 0)
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
      |> assign(:species_sig, nil)
      |> stream_configure(:species_table, dom_id: fn sp -> "species-row-#{sp.hash}" end)
      |> stream(:species_table, sort_species(all_species, sort_by, sort_dir))

    # Push an initial frame as soon as the websocket is connected so the
    # canvas isn't black between mount and the next broadcast frame
    # (especially after navigating back from the editor). The frame comes
    # from the shared per-world renderer's cache — no per-socket encode.
    socket =
      if connected?(socket) do
        case Lenies.WorldRenderer.current_frame(world_id) do
          nil -> socket
          payload -> push_event(socket, "render_frame", payload)
        end
      else
        socket
      end

    {:ok, socket}
  end

  defp find_selected_record(_handle, nil, _species), do: nil

  defp find_selected_record(handle, hash, species) do
    case Enum.find(species, &(&1.hash == hash)) do
      %{} = found ->
        found

      nil ->
        case Lenies.Species.for_hash(handle, hash) do
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
      class="lenies-dashboard h-full w-full overflow-hidden flex flex-col p-3 gap-3"
      data-inspector-dirty={if @inspector_dirty, do: "true", else: nil}
    >
      <Layouts.flash_group flash={@flash} />
      <header class="flex items-center justify-between px-2 shrink-0">
        <h1 class="text-lg font-bold tracking-widest">⬡ LENIES · SANDBOX</h1>
        <% latest = @latest || %{population: 0, total_resource: 0, total_carcass: 0} %>
        <div class="flex items-center gap-4 text-xs">
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
            ♪ AUDIO
          </button>
        </div>
      </header>

      <div class="flex-1 flex gap-3 min-h-0">
        <section class="panel p-2 flex flex-col gap-2 min-h-0 shrink-0 dashboard-map-pane">
          <h2 class="text-xs flex items-center gap-1.5">
            <span>▮ World</span>
            <span
              class="opacity-40 hover:opacity-80 cursor-help text-[10px] border border-slate-500/40 rounded-full w-4 h-4 inline-flex items-center justify-center"
              title="scroll: zoom · drag: pan · click: focus · dblclick on a Lenie: edit codeome"
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
                            title="Carried plasmid count across living members"
                          >· {plasmid_badge(sp.plasmid_min, sp.plasmid_max)}</span>
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
                world_handle={handle_from_assigns(assigns)}
              />
            <% end %>
          </div>

          <.live_component
            module={LeniesWeb.ControlsPanelComponent}
            id="controls"
            current_scope={@current_scope}
            world_id={@world_id}
            world_handle={handle_from_assigns(assigns)}
          />
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

  # Lookup the world handle from socket assigns. The dashboard mount now
  # always assigns a %WorldHandle{} (the user's sandbox is attached at
  # mount time), so the second clause is a defensive fallback for any
  # stale render path that would otherwise crash.
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
      |> assign(
        :selected_species_record,
        find_selected_record(socket.assigns.world_handle, new_hash, all_species)
      )
      |> maybe_stream_species(all_species)

    socket =
      if is_nil(new_hash),
        do: assign(socket, :inspector_dirty, false),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("kill_species", %{"hash" => hash}, socket) do
    target = socket.assigns.world_handle
    _ = Lenies.Worlds.cull_species(target, hash)

    # cull_species queues async :lenie_died casts; a synchronous world call
    # flushes the mailbox so the re-aggregation below sees the removal.
    _ = Lenies.Worlds.snapshot_stats(target)

    {_species, all_species, species_total} =
      aggregate_with_top(socket.assigns.world_handle, 10)

    {:noreply,
     socket
     |> assign(:species_total, species_total)
     |> assign(:all_species, all_species)
     |> assign(:selected_hash, nil)
     |> assign(:selected_species_record, nil)
     |> assign(:inspector_dirty, false)
     |> maybe_stream_species(all_species)}
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

  # Pushed by the GridCanvas hook on dblclick. We resolve the cell to a
  # Lenie via the :cells / :lenies ETS tables and navigate to its
  # editor; misses (empty cells) are a silent no-op.
  def handle_event("select_lenie_at_cell", %{"x" => x, "y" => y}, socket)
      when is_integer(x) and is_integer(y) do
    case Query.codeome_hash_at(socket.assigns.world_handle, x, y) do
      {:ok, hash} -> {:noreply, push_navigate(socket, to: ~p"/sandbox/editor/edit/#{hash}")}
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
    payload = lenie_hover_payload(socket.assigns.world_handle, x, y)
    {:noreply, push_event(socket, "lenie_hover_info", payload)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:tick, n, stats}, socket) do
    throttle = Application.get_env(:lenies, :dashboard_throttle_ticks, 5)
    new_counter = socket.assigns.throttle_counter + 1

    # `:latest` (World totals panel) comes straight from the tick payload —
    # no ETS history scan. The canvas frame is no longer encoded here; it
    # arrives via the shared renderer's {:frame, _} broadcast.
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
        |> assign(
          :selected_species_record,
          find_selected_record(
            socket.assigns.world_handle,
            socket.assigns.selected_hash,
            all_species
          )
        )
        |> maybe_clear_selected_species(all_species)
        |> maybe_stream_species(all_species)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Canvas frame broadcast by the shared per-world Lenies.WorldRenderer.
  # Forwarded verbatim to the JS hook — the socket does zero encoding.
  def handle_info({:frame, payload}, socket) do
    {:noreply, push_event(socket, "render_frame", payload)}
  end

  # Species table refresh on sterilize. The canvas frame is repainted by the
  # shared renderer (it also receives {:sterilized, _} and broadcasts a fresh
  # {:frame, _}), so the socket no longer encodes here.
  def handle_info({:sterilized, _ts}, socket) do
    {_species, all_species, species_total} = aggregate_with_top(socket.assigns.world_handle, 10)

    socket =
      socket
      |> assign(:species_total, species_total)
      |> assign(:all_species, all_species)
      |> maybe_stream_species(all_species)

    {:noreply, socket}
  end

  # Snapshot restore: refresh :latest directly from the payload (bypassing
  # the tick throttle) so the Population / Resource / Carcass header
  # reflects the restored state immediately — even with the world
  # paused (no upcoming :tick to drive the normal refresh path). The canvas
  # frame is repainted by the shared renderer's {:frame, _} broadcast.
  def handle_info({:restored, _ts, stats}, socket) when is_map(stats) do
    {_species, all_species, species_total} = aggregate_with_top(socket.assigns.world_handle, 10)

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

  def handle_info({:inspector_dirty, dirty}, socket) do
    {:noreply, assign(socket, :inspector_dirty, dirty)}
  end

  def handle_info(:sandboxes_manager_up, socket) do
    :ok = Lenies.Sandboxes.attach(socket.assigns.current_scope.user.id)
    {:noreply, socket}
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

  def handle_info({:flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
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
  # change. `stream(reset: true)` re-sends the whole list and forces the
  # client to re-patch every row, so on a stable / paused world (population
  # and ordering unchanged) we skip it entirely. The signature folds in
  # `selected_hash` because the row highlight class depends on it — selecting
  # a species must re-stream even though the underlying list is identical.
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
