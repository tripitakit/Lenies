defmodule Lenies.World do
  @moduledoc """
  The Lenies sandbox "world". GenServer that owns the ETS tables, drives the
  environmental tick, applies radiation and carcass decay, and provides the
  public API for snapshots and sterilization.

  ## Multi-world (Task 5)

  Each World now carries:

  - `world_id` — an atom or `{atom, term}` tuple identifying the world
    (defaults to `:primary`).
  - `config` — a `%Lenies.World.Config{}` struct, the source of truth at
    runtime for tunable simulation parameters. The struct is seeded from
    `Application.get_env(:lenies, …)` at `init/1` and then never re-read
    from app env (except for live-tuning paths we haven't migrated yet).
  - `tables` — a map of unnamed ETS tids (`%{cells, lenies, child_slots,
    history}`) owned by THIS GenServer.
  - `handle` — a `%Lenies.WorldHandle{}` rendered once in `init/1` and
    exposed via `handle_call(:get_handle, …)`.

  ### Compat shims (removed in later tasks)

  - The `:primary` world is STILL registered globally as
    `name: Lenies.World` (in addition to the via-Registry name) so legacy
    callers can `GenServer.call(Lenies.World, …)`. **Removed in Task 10.**
  - For the `:primary` world the 4 ETS tables are ALSO created as
    `:named_table` (`:cells`, `:lenies`, `:child_slots`, `:history`) so
    legacy callers reading by atom name still work. **Removed in Task 6.**
  - PubSub broadcasts for `:primary` are dual-published to BOTH the new
    scoped topic (`"world:primary:tick"`) AND the legacy unscoped topic
    (`"world:tick"`). **Removed once subscribers migrate.**

  See `docs/superpowers/specs/2026-05-11-lenies-design.md` §3, §6, §9.
  """

  use GenServer

  alias Lenies.Config
  alias Lenies.World.{Cell, ChildSlots, Hotspots, Radiation, Tables}
  alias Lenies.{Codeome, Mutator}

  @name __MODULE__

  # ----- Public API -----

  def start_link(opts \\ []) do
    world_id = Keyword.get(opts, :world_id, :primary)
    config_overrides = Keyword.get(opts, :config, %{})
    GenServer.start_link(__MODULE__, {world_id, config_overrides, opts}, name: server_name(world_id))
  end

  # The `:primary` world keeps the global atom name (compat shim, removed in
  # Task 10). All other worlds register under the via-Registry tuple.
  defp server_name(:primary), do: @name
  defp server_name(world_id), do: {:via, Registry, {Lenies.Registry, {:world, world_id}}}

  @doc "Quick sandbox stats for console/test."
  def snapshot_stats, do: GenServer.call(@name, :snapshot_stats)

  @doc "Force a single synchronous tick (for deterministic tests)."
  def tick_now, do: GenServer.call(@name, :tick_now)

  @doc "Full reset: kill all Lenies, clear ETS, restart the tick."
  def sterilize, do: GenServer.call(@name, :sterilize)

  @doc """
  Swap the 4 snapshot tables (`Lenies.Snapshot.tables/0`) for the `.tab` files
  in `dir`, running in the World process so World owns the reloaded tables.

  Intended to be called by `Lenies.Snapshot.restore_from_disk/1` AFTER a
  separate `sterilize/0` call (so terminated-Lenie `:lenie_died` casts are
  drained first) and AFTER the files have been validated. Does NOT recreate
  `:cells` contents (they come from the file) nor touch `:species_codeomes`.
  """
  def restore_tables(dir), do: GenServer.call(@name, {:restore_tables, dir})

  @doc """
  Execute an action requested by a Lenie. Synchronous call.

  Forms:
  - `{:sense_front, {x, y}, dir}` — returns `{:ok, :empty | {:resource, n} | {:lenie, id}}`
  - `{:move, {x, y}, dir, lenie_id}` — returns `{:ok, {:moved, {x2, y2}} | :blocked}`
  - `{:eat, {x, y}}` — returns `{:ok, {:ate, amount}}`
  """
  def action(action_spec), do: GenServer.call(@name, {:action, action_spec})

  @doc "Pause the environmental tick (auto-tick stops; tick_now still works)."
  def pause, do: GenServer.call(@name, :pause)

  @doc "Resume the environmental tick."
  def resume, do: GenServer.call(@name, :resume)

  @doc "Query current pause status."
  def paused?, do: GenServer.call(@name, :paused?)

  @doc """
  Synchronous reconciliation sweep: frees cells and deletes :lenies records
  whose Lenie is no longer alive in the Registry.

  Returns `{freed_cells, deleted_records}`.  Useful for tests and diagnostics;
  the same sweep runs automatically on the `:reconcile_interval_ms` timer.
  """
  def reconcile, do: GenServer.call(@name, :reconcile)

  @doc "Notify the World that a Lenie has died (frees the cell, optionally leaves a carcass)."
  def lenie_died(id, pos, energy_at_death, codeome_hash)
      when is_binary(codeome_hash) do
    GenServer.cast(@name, {:lenie_died, id, pos, energy_at_death, codeome_hash})
  end

  @doc """
  Spawn a new Lenie with `codeome` on a random free cell.

  Options:
  - `:energy` (default 500.0)
  - `:dir` (default `:n`)
  - `:lineage` (default `{nil, 0}`)

  Returns `{:ok, {id, pos}}` on success or `{:error, :no_free_cell}` if the grid is full.
  """
  def spawn_lenie(codeome, opts \\ []) do
    GenServer.call(@name, {:spawn_lenie, codeome, opts})
  end

  # ----- Server -----

  @impl true
  def init({world_id, config_overrides, opts}) do
    # Seed per-world Config from Application env, then layer caller overrides.
    config = Lenies.World.Config.merge(Lenies.World.Config.defaults(), config_overrides)
    tables = Tables.create_all(world_id)

    pubsub_prefix = "world:" <> Lenies.Worlds.id_to_path(world_id)

    handle = %Lenies.WorldHandle{
      id: world_id,
      pid: self(),
      tables: tables,
      pubsub_prefix: pubsub_prefix
    }

    # `grid` is still sourced from Lenies.Config (system bounds), not from the
    # per-world Config. Multi-grid support is a later step.
    grid = Config.grid_size()
    tick_interval = Keyword.get(opts, :tick_interval_ms, config.tick_interval_ms)
    hotspots = Hotspots.initial(grid, Config.hotspot_count())

    init_cells(grid, tables)
    {total_resource, total_carcass} = sum_cells(tables)

    state = %{
      world_id: world_id,
      config: config,
      tables: tables,
      handle: handle,
      grid: grid,
      hotspots: hotspots,
      tick_interval_ms: tick_interval,
      tick_ref: nil,
      tick_count: 0,
      paused?: false,
      reconcile_ref: nil,
      total_resource: total_resource,
      total_carcass: total_carcass
    }

    state = prewarm_radiation(state)
    # After prewarm, recompute totals to reflect the radiation deposited.
    {r, c} = sum_cells(tables)
    state = %{state | total_resource: r, total_carcass: c}
    state = maybe_schedule_tick(state)
    state = schedule_reconcile(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_handle, _from, state) do
    {:reply, state.handle, state}
  end

  def handle_call(:snapshot_stats, _from, state) do
    # total_resource and total_carcass are maintained as cached values in state,
    # updated once per tick in decay_and_sum_cells/0. Between ticks the values
    # may be up to one tick stale, which is acceptable for a stats display.
    stats = %{
      cells: :ets.info(state.tables.cells, :size),
      population: :ets.info(state.tables.lenies, :size),
      total_resource: state.total_resource,
      total_carcass: state.total_carcass,
      tick_count: state.tick_count
    }

    {:reply, stats, state}
  end

  def handle_call(:tick_now, _from, state) do
    state = do_tick(state)
    {:reply, :ok, state}
  end

  def handle_call(:sterilize, _from, state) do
    terminate_all_lenies()
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    if state.reconcile_ref, do: Process.cancel_timer(state.reconcile_ref)
    Tables.clear_all(state.tables)
    init_cells(state.grid, state.tables)
    hotspots = Hotspots.initial(state.grid, Config.hotspot_count())
    {total_resource, total_carcass} = sum_cells(state.tables)

    new_state = %{
      state
      | hotspots: hotspots,
        tick_count: 0,
        tick_ref: nil,
        reconcile_ref: nil,
        total_resource: total_resource,
        total_carcass: total_carcass
    }

    new_state = prewarm_radiation(new_state)
    # Recompute totals after prewarm radiation has deposited resources.
    {r, c} = sum_cells(state.tables)
    new_state = %{new_state | total_resource: r, total_carcass: c}
    new_state = maybe_schedule_tick(new_state)
    new_state = schedule_reconcile(new_state)

    broadcast(state, "control", {:sterilized, System.system_time(:millisecond)})

    {:reply, :ok, new_state}
  end

  def handle_call({:restore_tables, dir}, _from, state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    if state.reconcile_ref, do: Process.cancel_timer(state.reconcile_ref)

    # Delete the existing (sterilized) tables so file2tab can recreate them
    # owned by THIS World process. Each file2tab returns {:ok, tid}; we
    # collect the new tids into a map shaped like Tables.create_all/1.
    delete_tables(state.tables)

    {result, restored_tables} =
      try do
        Enum.reduce_while(Lenies.Snapshot.tables(), {:ok, %{}}, fn table, {:ok, acc} ->
          path = Path.join(dir, "#{table}.tab") |> String.to_charlist()

          case :ets.file2tab(path) do
            {:ok, tid} -> {:cont, {:ok, Map.put(acc, table, tid)}}
            _error -> {:halt, {{:error, {:restore_failed, table}}, acc}}
          end
        end)
      rescue
        _ -> {{:error, {:restore_failed, :unknown}}, %{}}
      end

    new_state =
      case result do
        :ok ->
          # All 4 tables restored — adopt the new tids into state + handle.
          new_state = %{
            state
            | tables: restored_tables,
              handle: %{state.handle | tables: restored_tables},
              tick_count: 0,
              tick_ref: nil,
              reconcile_ref: nil
          }

          {r, c} = sum_cells(new_state.tables)
          new_state = %{new_state | total_resource: r, total_carcass: c}

          new_state = maybe_schedule_tick(new_state)
          new_state = schedule_reconcile(new_state)
          broadcast(new_state, "control", {:restored, System.system_time(:millisecond)})
          new_state

        {:error, _} ->
          # Recovery: file2tab failed partway through the loop. Some tables may
          # have been restored; some are missing. Drop whatever we partially
          # restored and replace ALL 4 with fresh empty tables so the world is
          # in a valid (empty) state.
          delete_tables(restored_tables)
          recovered_tables = recover_tables(state.grid)

          new_state = %{
            state
            | tables: recovered_tables,
              handle: %{state.handle | tables: recovered_tables},
              tick_count: 0,
              tick_ref: nil,
              reconcile_ref: nil
          }

          {r, c} = sum_cells(new_state.tables)
          new_state = %{new_state | total_resource: r, total_carcass: c}

          new_state = maybe_schedule_tick(new_state)
          new_state = schedule_reconcile(new_state)
          new_state
      end

    case result do
      :ok -> {:reply, :ok, new_state}
      err -> {:reply, err, new_state}
    end
  end

  def handle_call(:pause, _from, state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    # Broadcast pause/resume on the world's control topic so each Lenie can
    # suspend its metabolize loop too — otherwise the environmental tick
    # stops but the Lenies keep moving in the background and the canvas
    # silently goes out of sync with reality.
    broadcast(state, "control", :world_paused)
    {:reply, :ok, %{state | paused?: true, tick_ref: nil}}
  end

  def handle_call(:resume, _from, state) do
    new_state = %{state | paused?: false}
    new_state = maybe_schedule_tick(new_state)
    broadcast(state, "control", :world_resumed)
    {:reply, :ok, new_state}
  end

  def handle_call(:paused?, _from, state) do
    {:reply, state.paused?, state}
  end

  def handle_call(:reconcile, _from, state) do
    result = do_reconcile(state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:action, action_spec}, _from, state) do
    {result, new_state} = do_action(action_spec, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:spawn_lenie, codeome, opts}, _from, state) do
    case find_random_free_cell(state.grid, state.tables) do
      {:ok, pos} ->
        lenie_id = generate_lenie_id()
        energy = Keyword.get(opts, :energy, 500.0)
        dir = Keyword.get(opts, :dir, :n)
        lineage = Keyword.get(opts, :lineage, {nil, 0})
        seed_origin = Keyword.get(opts, :seed_origin)
        plasmids = Keyword.get(opts, :plasmids, [])

        child_opts = [
          id: lenie_id,
          codeome: codeome,
          energy: energy * 1.0,
          pos: pos,
          dir: dir,
          lineage: lineage,
          seed_origin: seed_origin,
          # Inherit the world's current pause flag so a Lenie spawned
          # while the world is paused stays dormant until resume.
          paused?: state.paused?,
          plasmids: plasmids
        ]

        {:ok, _pid} =
          DynamicSupervisor.start_child(
            Lenies.LenieSupervisor,
            Supervisor.child_spec({Lenies.Lenie, {state.handle, child_opts}},
              restart: :temporary
            )
          )

        [{key, cell}] = :ets.lookup(state.tables.cells, pos)
        :ets.insert(state.tables.cells, {key, %{cell | lenie_id: lenie_id}})

        {:reply, {:ok, {lenie_id, pos}}, state}

      :no_free_cell ->
        {:reply, {:error, :no_free_cell}, state}
    end
  end

  @impl true
  def handle_cast({:lenie_died, id, {x, y}, energy_at_death, codeome_hash}, state) do
    case :ets.lookup(state.tables.cells, {x, y}) do
      [{key, cell}] ->
        carcass_value = max(0, trunc(energy_at_death * 0.5))
        hue = Lenies.SpeciesColor.hue_byte(codeome_hash)

        :ets.insert(state.tables.cells, {
          key,
          %{cell | lenie_id: nil, carcass: cell.carcass + carcass_value, carcass_hue: hue}
        })

      _ ->
        :ok
    end

    :ets.delete(state.tables.lenies, id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    state = maybe_schedule_tick(%{state | tick_ref: nil})
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    do_reconcile(state)
    state = schedule_reconcile(%{state | reconcile_ref: nil})
    {:noreply, state}
  end

  # ----- internals -----

  defp delete_tables(tables) when is_map(tables) do
    for {_key, tid} <- tables do
      try do
        :ets.delete(tid)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  # Live config read with hardcoded-default fallback (compat shim during the
  # multi-world refactor). The intent of the spec is that `state.config.<key>`
  # be the source of truth — but the existing suite relies on
  # `Application.put_env(:lenies, …)` / `Application.delete_env(:lenies, …)`
  # taking effect on a running World, so we re-read app env on each access.
  # When a test has deleted the key we fall back to the SAME literal default
  # the pre-Task-5 `Application.get_env(:lenies, key, <default>)` calls used,
  # NOT to `state.config.<key>` — otherwise the slightly different defaults
  # in `Lenies.World.Config.defaults/0` would shift behaviour. The shim is
  # removed in a later task once `Worlds.tune/3` writes into state.
  @cfg_defaults %{
    radiation_per_tick: 100,
    eat_amount: 20,
    carcass_decay: 0.05,
    tick_interval_ms: 100,
    copy_substitution_rate: 0.005,
    copy_insert_rate: 0.0005,
    copy_delete_rate: 0.0005,
    background_mutation_rate_per_1000_ticks: 1,
    attack_damage: 10
  }
  defp cfg(_state, key) do
    Application.get_env(:lenies, key, Map.fetch!(@cfg_defaults, key))
  end

  defp init_cells({w, h}, tables) do
    initial_resource = Application.get_env(:lenies, :initial_resource_per_cell, 30)

    for x <- 0..(w - 1), y <- 0..(h - 1) do
      :ets.insert(tables.cells, {{x, y}, %Cell{resource: initial_resource}})
    end

    :ok
  end

  # Recreate all 4 snapshot tables from scratch when a restore fails mid-loop.
  # Any table that currently exists is deleted first so the :new/2 call can
  # recreate it. The :cells grid is then populated the same way init/1 does
  # it, so the world is immediately usable after recovery.
  #
  # NOTE: this path is only reachable via :restore_tables, which is a
  # primary-world-only flow at this stage (snapshot/restore is not yet
  # multi-world). Tables are recreated as unnamed tids and returned as a
  # map matching Tables.create_all/1's output, so the caller can update
  # state.tables / state.handle.tables in place.
  defp recover_tables(grid) do
    table_opts = [:set, :public, read_concurrency: true, write_concurrency: true]
    ordered_opts = [:ordered_set, :public, read_concurrency: true, write_concurrency: true]

    new_tables = %{
      cells: :ets.new(:cells, table_opts),
      lenies: :ets.new(:lenies, table_opts),
      child_slots: :ets.new(:child_slots, table_opts),
      history: :ets.new(:history, ordered_opts)
    }

    initial_resource = Application.get_env(:lenies, :initial_resource_per_cell, 30)
    {w, h} = grid

    for x <- 0..(w - 1), y <- 0..(h - 1) do
      :ets.insert(new_tables.cells, {{x, y}, %Cell{resource: initial_resource}})
    end

    new_tables
  end

  defp prewarm_radiation(state) do
    n = Application.get_env(:lenies, :initial_radiation_ticks, 50)

    if n > 0 do
      Enum.reduce(1..n, state, fn _i, acc ->
        apply_radiation(acc)
        hotspots = Hotspots.drift(acc.hotspots, acc.grid)
        %{acc | hotspots: hotspots}
      end)
    else
      state
    end
  end

  defp do_tick(state) do
    apply_radiation(state)
    # Single fold: apply carcass decay AND accumulate {total_resource, total_carcass}.
    # Runs AFTER radiation so total_resource reflects post-radiation state.
    {total_resource, total_carcass} = decay_and_sum_cells(state)
    maybe_background_mutation(state)

    hotspots = Hotspots.drift(state.hotspots, state.grid)

    broadcast(state, "tick", {:tick, state.tick_count + 1})

    %{
      state
      | hotspots: hotspots,
        tick_count: state.tick_count + 1,
        total_resource: total_resource,
        total_carcass: total_carcass
    }
  end

  defp apply_radiation(state) do
    deposit =
      Radiation.combined(
        state.grid,
        cfg(state, :radiation_per_tick),
        state.hotspots,
        uniform_ratio: Config.radiation_uniform_ratio()
      )

    Enum.each(deposit, fn {{x, y}, amount} ->
      case :ets.lookup(state.tables.cells, {x, y}) do
        [{key, cell}] ->
          :ets.insert(state.tables.cells, {key, Cell.add_resource(cell, amount)})

        [] ->
          :ok
      end
    end)
  end

  # Single fold over :cells that:
  #   1. Applies carcass decay (when rate > 0, only to cells with carcass > 0).
  #   2. Accumulates {total_resource, total_carcass} in one pass.
  #
  # The carcass total is accumulated from the POST-decay value so the cached
  # total reflects what a fresh sum would return immediately after decay.
  # Resource is unchanged by decay, so it is summed as-is.
  #
  # Inserting into :cells during the foldl (for a :set table, updating the
  # same key) is the established pattern here — this is safe for a :set as
  # long as we are only updating existing keys, not inserting new ones.
  defp decay_and_sum_cells(state) do
    rate = cfg(state, :carcass_decay)
    cells = state.tables.cells

    :ets.foldl(
      fn {key, cell}, {sum_r, sum_c} ->
        effective_cell =
          if rate > 0 and cell.carcass > 0 do
            decayed = Cell.decay_carcass(cell, rate)
            :ets.insert(cells, {key, decayed})
            decayed
          else
            cell
          end

        {sum_r + effective_cell.resource, sum_c + effective_cell.carcass}
      end,
      {0, 0},
      cells
    )
  end

  # Background mutations are configured as a RATE — N mutations per 1000
  # world ticks (0 = off) — because a rate scale is monotone with the
  # observed mutation pressure (higher = more), unlike an interval scale
  # where bigger numbers mean rarer events. We convert internally to a
  # tick interval so the rest of the logic stays modular arithmetic.
  defp maybe_background_mutation(state) do
    rate = cfg(state, :background_mutation_rate_per_1000_ticks)

    if rate > 0 do
      interval = max(1, div(1000, rate))

      if rem(state.tick_count + 1, interval) == 0 do
        apply_random_background_mutation(state)
      end
    end

    :ok
  end

  defp apply_random_background_mutation(state) do
    case :ets.tab2list(state.tables.lenies) do
      [] ->
        :ok

      records ->
        # Pick a random Lenie's id
        {id, _record} = Enum.random(records)

        case Registry.lookup(Lenies.Registry, {:lenie, state.world_id, id}) do
          [{pid, _}] -> send(pid, :background_mutate)
          [] -> :ok
        end
    end
  end

  # One fold returning {total_resource, total_carcass} without side effects.
  # Used at init, sterilize, and restore_tables to seed the cached totals.
  defp sum_cells(tables) do
    :ets.foldl(
      fn {_key, cell}, {r, c} -> {r + cell.resource, c + cell.carcass} end,
      {0, 0},
      tables.cells
    )
  end

  defp maybe_schedule_tick(%{tick_interval_ms: 0} = state), do: state
  defp maybe_schedule_tick(%{tick_interval_ms: nil} = state), do: state
  defp maybe_schedule_tick(%{paused?: true} = state), do: state

  defp maybe_schedule_tick(state) do
    # Re-read from Application env so the dashboard slider can change tick rate
    # live on a running world. Falls back to the value supplied at start_link.
    # NOTE: we don't refresh state.config here — the live-tuning path stays on
    # app env for this task; per-world config update is a later step.
    interval = Application.get_env(:lenies, :tick_interval_ms, state.tick_interval_ms)
    ref = Process.send_after(self(), :tick, interval)
    %{state | tick_ref: ref}
  end

  defp schedule_reconcile(state) do
    interval = Config.reconcile_interval_ms()
    ref = Process.send_after(self(), :reconcile, interval)
    %{state | reconcile_ref: ref}
  end

  # Reconciliation sweep — O(grid + registry) but runs infrequently (default
  # 30 s) so the cost is acceptable. Freeing a stale slot unblocks future
  # moves/spawns/divides that would otherwise be permanently rejected.
  #
  # Two passes, both collect-then-apply to avoid mutating ETS tables mid-foldl
  # (ETS foldl is safe to read during iteration but inserting/deleting during
  # the same fold is undefined in concurrent settings).
  #
  # Returns {freed_cells, deleted_records}.
  defp do_reconcile(state) do
    # Guard: if the Registry is not available (e.g. supervisor not started)
    # return immediately without crashing World.
    if Process.whereis(Lenies.Registry) == nil do
      {0, 0}
    else
      cells = state.tables.cells
      lenies = state.tables.lenies

      world_id = state.world_id

      # Pass 1 — collect keys of cells occupied by dead Lenies
      stale_cell_keys =
        :ets.foldl(
          fn {key, cell}, acc ->
            if is_binary(cell.lenie_id) and
                 Registry.lookup(Lenies.Registry, {:lenie, world_id, cell.lenie_id}) == [] do
              [key | acc]
            else
              acc
            end
          end,
          [],
          cells
        )

      # Apply: free each stale cell (no carcass — we have no reliable energy)
      Enum.each(stale_cell_keys, fn key ->
        case :ets.lookup(cells, key) do
          [{^key, cell}] -> :ets.insert(cells, {key, %{cell | lenie_id: nil}})
          _ -> :ok
        end
      end)

      # Pass 2 — collect ids of orphaned :lenies records
      stale_lenie_ids =
        :ets.foldl(
          fn {id, _record}, acc ->
            if Registry.lookup(Lenies.Registry, {:lenie, world_id, id}) == [] do
              [id | acc]
            else
              acc
            end
          end,
          [],
          lenies
        )

      # Apply: delete each orphaned record
      Enum.each(stale_lenie_ids, fn id -> :ets.delete(lenies, id) end)

      {length(stale_cell_keys), length(stale_lenie_ids)}
    end
  end

  defp terminate_all_lenies do
    case Process.whereis(Lenies.LenieSupervisor) do
      nil ->
        :ok

      _pid ->
        Lenies.LenieSupervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_, child_pid, _, _} ->
          if is_pid(child_pid),
            do: DynamicSupervisor.terminate_child(Lenies.LenieSupervisor, child_pid)
        end)
    end
  end

  defp do_action({:sense_front, {x, y}, dir}, state) do
    front = front_cell({x, y}, dir, state.grid)

    case :ets.lookup(state.tables.cells, front) do
      [{_, cell}] ->
        result =
          cond do
            cell.lenie_id != nil -> {:lenie, cell.lenie_id}
            cell.resource > 0 -> {:resource, cell.resource}
            true -> :empty
          end

        {{:ok, result}, state}

      _ ->
        {{:ok, :empty}, state}
    end
  end

  defp do_action({:move, {x, y}, dir, lenie_id}, state) do
    front = front_cell({x, y}, dir, state.grid)

    case :ets.lookup(state.tables.cells, front) do
      [{_, %{lenie_id: nil} = front_cell}] ->
        # move successful
        [{src_key, src_cell}] = :ets.lookup(state.tables.cells, {x, y})
        :ets.insert(state.tables.cells, {src_key, %{src_cell | lenie_id: nil}})
        :ets.insert(state.tables.cells, {front, %{front_cell | lenie_id: lenie_id}})
        {{:ok, {:moved, front}}, state}

      _ ->
        {{:ok, :blocked}, state}
    end
  end

  defp do_action({:eat, {x, y}}, state) do
    case :ets.lookup(state.tables.cells, {x, y}) do
      [{key, cell}] ->
        eat_amount = cfg(state, :eat_amount)
        {energy_gained, new_cell} = consume_eat(cell, eat_amount)
        :ets.insert(state.tables.cells, {key, new_cell})
        {{:ok, {:ate, energy_gained}}, state}

      _ ->
        {{:ok, {:ate, 0}}, state}
    end
  end

  defp do_action({:allocate, size, {x, y}, dir, parent_id}, state) do
    bounds = Application.get_env(:lenies, :codeome_length_bounds, {5, 1000})
    {min_size, max_size} = bounds

    cond do
      size < min_size or size > max_size ->
        {{:ok, :invalid_size}, state}

      parent_already_allocated?(parent_id, state) ->
        {{:ok, :already_allocated}, state}

      true ->
        target_cell = front_cell({x, y}, dir, state.grid)

        case :ets.lookup(state.tables.cells, target_cell) do
          [{_, %{lenie_id: nil}}] ->
            {:ok, slot_id} =
              ChildSlots.create(state.tables.child_slots, parent_id, target_cell, size)

            update_lenie_record(parent_id, &Map.put(&1, :child_slot_id, slot_id), state)
            {{:ok, {:allocated, slot_id, target_cell}}, state}

          _ ->
            {{:ok, :blocked}, state}
        end
    end
  end

  defp do_action({:write_child, opcode_int, child_addr, parent_id}, state) do
    case :ets.lookup(state.tables.lenies, parent_id) do
      [{^parent_id, %{child_slot_id: slot_id}}] when is_binary(slot_id) ->
        rates = current_copy_rates(state)
        outcome = Mutator.copy_outcome(rates)
        opcode = Codeome.Opcodes.decode(opcode_int)

        :ok = apply_copy_outcome(slot_id, child_addr, opcode, outcome, state)
        {{:ok, :written}, state}

      _ ->
        {{:ok, :no_slot}, state}
    end
  end

  defp do_action({:divide, parent_energy, _pos, _dir, parent_id}, state) do
    case :ets.lookup(state.tables.lenies, parent_id) do
      [{^parent_id, %{child_slot_id: slot_id} = parent_record}] when is_binary(slot_id) ->
        case ChildSlots.get(state.tables.child_slots, slot_id) do
          {:ok, slot} ->
            do_divide(parent_id, parent_record, slot_id, slot, parent_energy, state)

          :not_found ->
            {{:ok, :no_slot}, state}
        end

      _ ->
        {{:ok, :no_slot}, state}
    end
  end

  defp do_action({:defend, lenie_id}, state) do
    window = Application.get_env(:lenies, :defense_window_ticks, 5)

    case :ets.lookup(state.tables.lenies, lenie_id) do
      [{^lenie_id, _record}] ->
        update_lenie_record(
          lenie_id,
          &Map.put(&1, :defending_until, state.tick_count + window),
          state
        )

        {{:ok, :defending}, state}

      _ ->
        {{:ok, :no_lenie}, state}
    end
  end

  defp do_action({:attack, {x, y}, dir, attacker_id}, state) do
    target_cell = front_cell({x, y}, dir, state.grid)

    case :ets.lookup(state.tables.cells, target_cell) do
      [{_, %{lenie_id: target_id}}] when is_binary(target_id) ->
        resolve_attack(target_id, attacker_id, state)

      _ ->
        {{:ok, :no_target}, state}
    end
  end

  defp do_action(_unknown, state), do: {{:ok, {:error, :unknown_action}}, state}

  defp resolve_attack(target_id, attacker_id, state) do
    base_damage = cfg(state, :attack_damage)

    case :ets.lookup(state.tables.lenies, target_id) do
      [{^target_id, record}] ->
        defending_until = Map.get(record, :defending_until, 0)

        {damage, result_tag} =
          if state.tick_count < defending_until do
            {div(base_damage, 2), :defended}
          else
            {base_damage, :attacked}
          end

        # Send async damage message to the target Lenie, including the
        # attacker id so the victim can reward the attacker with exactly
        # what it actually lost (energy conservation fix).
        case Registry.lookup(Lenies.Registry, {:lenie, state.world_id, target_id}) do
          [{pid, _}] -> send(pid, {:take_damage, damage, attacker_id})
          [] -> :ok
        end

        {{:ok, {result_tag, damage}}, state}

      _ ->
        # No :lenies record for target (shouldn't happen with snapshot writes)
        {{:ok, :no_target}, state}
    end
  end

  defp do_divide(parent_id, parent_record, slot_id, slot, parent_energy, state) do
    target_cell = slot.target_cell

    case :ets.lookup(state.tables.cells, target_cell) do
      [{_, %{lenie_id: nil}}] ->
        min_viable = Application.get_env(:lenies, :min_viable_codeome_opcodes, 10)
        non_nops = Enum.count(Tuple.to_list(slot.opcodes), &(&1 not in [:nop_0, :nop_1]))

        if non_nops < min_viable do
          # slot has too many nops; "stillbirth" — release slot, energy not refunded
          ChildSlots.delete(state.tables.child_slots, slot_id)
          update_lenie_record(parent_id, &Map.put(&1, :child_slot_id, nil), state)
          {{:ok, :stillborn}, state}
        else
          spawn_child(parent_id, parent_record, slot_id, slot, parent_energy, state)
        end

      _ ->
        # target now occupied; release slot, energy not refunded
        ChildSlots.delete(state.tables.child_slots, slot_id)
        update_lenie_record(parent_id, &Map.put(&1, :child_slot_id, nil), state)
        {{:ok, :target_blocked}, state}
    end
  end

  defp spawn_child(parent_id, parent_record, slot_id, slot, parent_energy, state) do
    child_id = generate_child_id()
    child_energy = trunc(parent_energy / 2)
    child_codeome = Codeome.from_list(Tuple.to_list(slot.opcodes))
    parent_generation = parent_record |> Map.get(:lineage, {nil, 0}) |> elem(1)
    # Inherit the seed_origin from the parent so descendants of a known
    # seed keep their lineage label across replications + mutations.
    parent_seed_origin = Map.get(parent_record, :seed_origin)

    parent_plasmids = Map.get(parent_record, :plasmids, [])
    child_plasmids = mutate_plasmids(parent_plasmids, state)

    child_opts = [
      id: child_id,
      codeome: child_codeome,
      energy: child_energy * 1.0,
      pos: slot.target_cell,
      dir: parent_record.dir,
      lineage: {parent_id, parent_generation + 1},
      seed_origin: parent_seed_origin,
      paused?: state.paused?,
      plasmids: child_plasmids
    ]

    {:ok, _child_pid} =
      DynamicSupervisor.start_child(
        Lenies.LenieSupervisor,
        Supervisor.child_spec({Lenies.Lenie, {state.handle, child_opts}},
          restart: :temporary
        )
      )

    # Mark child cell occupied
    [{key, cell}] = :ets.lookup(state.tables.cells, slot.target_cell)
    :ets.insert(state.tables.cells, {key, %{cell | lenie_id: child_id}})

    # Clean up parent's slot
    ChildSlots.delete(state.tables.child_slots, slot_id)
    update_lenie_record(parent_id, &Map.put(&1, :child_slot_id, nil), state)

    {{:ok, {:divided, child_id, child_energy}}, state}
  end

  defp find_random_free_cell({w, h}, tables) do
    max_tries = 100

    case sample_free_cell({w, h}, max_tries, tables) do
      {:ok, pos} ->
        {:ok, pos}

      :exhausted ->
        scan_for_free_cell({w, h}, tables)
    end
  end

  defp sample_free_cell(_grid, 0, _tables), do: :exhausted

  defp sample_free_cell({w, h} = grid, tries, tables) do
    x = :rand.uniform(w) - 1
    y = :rand.uniform(h) - 1

    case :ets.lookup(tables.cells, {x, y}) do
      [{_, %{lenie_id: nil}}] -> {:ok, {x, y}}
      _ -> sample_free_cell(grid, tries - 1, tables)
    end
  end

  defp scan_for_free_cell({w, h}, tables) do
    Enum.find_value(0..(w - 1), :no_free_cell, fn x ->
      Enum.find_value(0..(h - 1), nil, fn y ->
        case :ets.lookup(tables.cells, {x, y}) do
          [{_, %{lenie_id: nil}}] -> {:ok, {x, y}}
          _ -> nil
        end
      end)
    end)
  end

  defp generate_lenie_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp generate_child_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end

  defp parent_already_allocated?(parent_id, state) do
    case :ets.lookup(state.tables.lenies, parent_id) do
      [{^parent_id, record}] -> Map.get(record, :child_slot_id) != nil
      _ -> false
    end
  end

  # No lost-update race with Lenie.maybe_write_snapshot/1:
  # World mutates a Lenie's :lenies record (defending_until, child_slot_id) ONLY
  # while that Lenie is blocked in a synchronous World.action call; the Lenie
  # writes its own snapshot ONLY between batches, never mid-call — so these
  # read-modify-writes are mutually exclusive. Preserve this invariant.
  defp update_lenie_record(id, fun, state) do
    case :ets.lookup(state.tables.lenies, id) do
      [{^id, record}] -> :ets.insert(state.tables.lenies, {id, fun.(record)})
      _ -> :ok
    end
  end

  defp consume_eat(cell, eat_amount) do
    # Carcass is consumed first (preferentially), then resource fills any remaining quota.
    # Both sources yield energy 1:1 — no bonus multiplier — so energy gained always equals
    # units consumed. This preserves the simulation's energy-conservation invariant:
    # energy enters only via radiation and leaves only via starvation.
    carcass_taken = min(cell.carcass, eat_amount)
    remaining_quota = eat_amount - carcass_taken
    resource_taken = min(cell.resource, remaining_quota)
    total_energy = carcass_taken + resource_taken

    new_carcass = cell.carcass - carcass_taken
    new_carcass_hue = if new_carcass == 0, do: 0, else: cell.carcass_hue

    new_cell = %{
      cell
      | carcass: new_carcass,
        resource: cell.resource - resource_taken,
        carcass_hue: new_carcass_hue
    }

    {total_energy, new_cell}
  end

  defp front_cell({x, y}, dir, {w, h}) do
    Lenies.World.Geometry.step({x, y}, dir, {w, h})
  end

  defp current_copy_rates(state) do
    %{
      substitution: cfg(state, :copy_substitution_rate),
      insert: cfg(state, :copy_insert_rate),
      delete: cfg(state, :copy_delete_rate)
    }
  end

  defp apply_copy_outcome(slot_id, child_addr, opcode, :write, state) do
    ChildSlots.set_opcode(state.tables.child_slots, slot_id, child_addr, opcode)
    :ok
  end

  defp apply_copy_outcome(slot_id, child_addr, _opcode, :substitute, state) do
    ChildSlots.set_opcode(state.tables.child_slots, slot_id, child_addr, Mutator.random_opcode())
    :ok
  end

  defp apply_copy_outcome(slot_id, child_addr, opcode, :insert, state) do
    # Insert a random opcode AT child_addr, shifting subsequent positions
    {:ok, slot} = ChildSlots.get(state.tables.child_slots, slot_id)
    new_opcodes = Mutator.insert_at(slot.opcodes, child_addr, Mutator.random_opcode(), slot.size)
    :ets.insert(state.tables.child_slots, {slot_id, %{slot | opcodes: new_opcodes}})
    # Then write the requested opcode at the next position (the original target shifted by 1)
    ChildSlots.set_opcode(state.tables.child_slots, slot_id, child_addr + 1, opcode)
    :ok
  end

  defp apply_copy_outcome(_slot_id, _child_addr, _opcode, :delete, _state) do
    # Skip the write entirely; downstream positions in the slot remain
    # whatever they were (initialized to :nop_0). This effectively shortens
    # the executed program by 1.
    :ok
  end

  defp mutate_plasmids(plasmids, state) when is_list(plasmids) do
    %{substitution: sub_rate, insert: ins_rate, delete: del_rate} = current_copy_rates(state)

    Enum.map(plasmids, fn %Lenies.Plasmid{opcodes: ops} = p ->
      %{p | opcodes: Lenies.Mutator.copy_mutate_list(ops, sub_rate, ins_rate, del_rate)}
    end)
  end

  # ----- PubSub helpers -----
  #
  # Publishing strategy: each broadcast goes to the world's scoped topic
  # (`"world:<id>:<channel>"`). For the `:primary` world we ALSO publish to
  # the legacy unscoped topic (`"world:<channel>"`) as a compat shim so the
  # existing subscribers (LiveViews, Telemetry, tests) keep working. The
  # shim is removed once subscribers migrate.

  defp broadcast(state, channel, message) do
    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "#{state.handle.pubsub_prefix}:#{channel}",
      message
    )

    if state.world_id == :primary do
      Phoenix.PubSub.broadcast(Lenies.PubSub, "world:#{channel}", message)
    end

    :ok
  end
end
