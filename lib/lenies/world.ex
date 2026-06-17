defmodule Lenies.World do
  @moduledoc """
  The Lenies sandbox "world". GenServer that owns the ETS tables, drives the
  environmental tick, applies the resource field and carcass decay, and provides
  the public API for snapshots and sterilization.

  ## Multi-world

  Each World carries:

  - `world_id` — an atom or `{atom, term}` tuple identifying the world
    (required at `start_link/1`).
  - `config` — a `%Lenies.World.Config{}` struct, the source of truth at
    runtime for tunable simulation parameters. The struct is seeded from
    `Application.get_env(:lenies, …)` at `init/1` and then never re-read
    from app env (except for live-tuning paths we haven't migrated yet).
  - `tables` — a map of unnamed ETS tids (`%{cells, lenies, child_slots,
    history, color_overrides, occupancy}`) owned by THIS GenServer.
  - `handle` — a `%Lenies.WorldHandle{}` rendered once in `init/1` and
    exposed via `handle_call(:get_handle, …)`.

  Each World registers under `{:via, Registry, {Lenies.Registry, {:world,
  world_id}}}`. All external callers go through the `Lenies.Worlds.X(world_id,
  …)` facade.

  See `docs/superpowers/specs/2026-05-11-lenies-design.md` §3, §6, §9.
  """

  use GenServer

  alias Lenies.Config
  alias Lenies.World.{Cell, ChildSlots, Field, Tables}
  alias Lenies.{Codeome, Mutator}

  require Logger

  # ----- Public API -----

  def start_link(opts) do
    world_id = Keyword.fetch!(opts, :world_id)
    config_overrides = Keyword.get(opts, :config, %{})

    GenServer.start_link(__MODULE__, {world_id, config_overrides, opts},
      name: server_name(world_id)
    )
  end

  defp server_name(world_id),
    do: {:via, Registry, {Lenies.Registry, {:world, world_id}}}

  # ----- Server -----

  @impl true
  def init({world_id, config_overrides, opts}) do
    # Run the simulation engine below normal-priority Phoenix/PubSub/LiveView
    # work so the UI stays responsive when the world saturates the scheduler.
    Process.flag(:priority, :low)

    # Seed per-world Config from Application env, then layer caller overrides.
    # The legacy `tick_interval_ms:` keyword opt (heavily used by tests to
    # disable auto-ticking with `0`) wins over both config_overrides and
    # defaults — we fold it into the per-world Config so the engine has a
    # single source of truth and the cfg/2 helper just reads state.config.
    base_config = Lenies.World.Config.merge(Lenies.World.Config.defaults(), config_overrides)

    config =
      case Keyword.fetch(opts, :tick_interval_ms) do
        {:ok, value} -> %{base_config | tick_interval_ms: value}
        :error -> base_config
      end

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
    field = Field.new(:erlang.phash2(world_id))

    init_cells_from_field(field, grid, tables, 3 * config.eat_amount)

    state = %{
      world_id: world_id,
      config: config,
      tables: tables,
      handle: handle,
      grid: grid,
      field: field,
      tick_ref: nil,
      tick_count: 0,
      paused?: false,
      reconcile_ref: nil,
      # Incrementally-maintained indices (see put_cell/4). Seeded authoritatively
      # by reseed_indices/1 below.
      occupancy: %{},
      carcass_cells: MapSet.new(),
      total_resource: 0,
      total_carcass: 0
    }
    state = reseed_indices(state)
    state = maybe_schedule_tick(state)
    state = schedule_reconcile(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_handle, _from, state) do
    {:reply, state.handle, state}
  end

  def handle_call(:snapshot_stats, _from, state) do
    # total_resource and total_carcass are maintained incrementally in state by
    # put_cell/4 (radiation, eat, death, decay), so they are always current here
    # without folding the grid.
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
    new_state = do_sterilize(state)
    broadcast(state, "control", {:sterilized, System.system_time(:millisecond)})
    {:reply, :ok, new_state}
  end

  def handle_call({:cull_species, hash}, _from, state) do
    # Mirror Lenies.Arena apoptosis: select matching Lenies straight from the
    # :lenies ETS table, terminate each process, then replay the :lenie_died
    # cast on its behalf. Lenies do not trap exits, so a supervisor shutdown
    # bypasses Lenie.terminate/2 — replaying keeps the cell grid + carcass
    # bookkeeping consistent (frees the cell, deletes the :lenies row).
    ms = [
      {{:"$1", %{pos: :"$2", energy: :"$3", codeome_hash: :"$4", seeder_user_id: :"$5"}},
       [{:==, :"$4", hash}], [{{:"$1", :"$2", :"$3", :"$5"}}]}
    ]

    rows = :ets.select(state.tables.lenies, ms)
    sup = Lenies.LenieSupervisor.via(state.world_id)

    count =
      Enum.reduce(rows, 0, fn {id, pos, energy, seeder_user_id}, acc ->
        case Registry.lookup(Lenies.Registry, {:lenie, state.world_id, id}) do
          [{pid, _}] ->
            _ = DynamicSupervisor.terminate_child(sup, pid)
            GenServer.cast(self(), {:lenie_died, id, pos, energy, hash, seeder_user_id, :culled})
            acc + 1

          [] ->
            acc
        end
      end)

    {:reply, {:ok, count}, state}
  end

  # Reset the distributed energy (per-cell resource + carcass) back to the flat
  # baseline, WITHOUT touching the Lenies (lenie_id is preserved). Used by the
  # Arena when it goes unobserved so the world doesn't restore saturated with
  # accumulated radiation. Carcass is cleared too — it's distributed energy that
  # would otherwise persist across the dormancy snapshot.
  def handle_call(:reset_energy, _from, state) do
    initial = Application.get_env(:lenies, :initial_resource_per_cell, 30)
    cells = state.tables.cells

    :ets.foldl(
      fn {key, cell}, _acc ->
        :ets.insert(cells, {key, %{cell | resource: initial, carcass: 0, carcass_hue: 0}})
        :ok
      end,
      :ok,
      cells
    )

    # Bulk rewrite bypassed put_cell/4 — rebuild the indices from the result.
    {:reply, :ok, reseed_indices(state)}
  end

  def handle_call({:save_snapshot, name}, _from, state) do
    result = Lenies.Snapshot.save(state.handle, name, state.config)
    {:reply, result, state}
  end

  def handle_call({:restore_snapshot, name}, _from, state) do
    # Only the load phase runs in the World GenServer; the caller
    # (`Lenies.Worlds.restore_snapshot/2`) has already validated the snapshot
    # AND issued a separate `:sterilize` call. The separate sterilize call is
    # load-bearing: it drains the resulting `:lenie_died` casts from the
    # world's mailbox before this call is dequeued, so the freshly restored
    # `:cells` / `:lenies` tables aren't clobbered.
    case Lenies.Snapshot.load_validated(state.handle, name) do
      :ok ->
        # After load_validated, ETS.lenies contains records whose `pid`
        # fields are stale (the saved GenServer pids died long ago).
        # Without a respawn, those records are ghosts — Species.aggregate
        # filters them out via Process.alive?, Population shows N but
        # the world is effectively empty, and the reconcile loop reaps
        # them after ~130 ticks. Respawn a fresh Lenie GenServer for
        # each ghost so the world is actually populated post-restore.
        respawned = respawn_lenies_from_snapshots(state)

        Logger.info(
          "World #{inspect(state.world_id)} restored from snapshot \"#{name}\" — respawned #{respawned} Lenies"
        )

        # Restore the per-world tuning config from its sidecar so the user's
        # tunables survive a stop/restore (disconnect/reconnect, arena round-trip
        # past the grace window). Legacy snapshots without the sidecar keep the
        # world's current config.
        restored_config =
          case Lenies.Snapshot.load_config(state.world_id, name) do
            {:ok, cfg_map} ->
              # Spawn/replication caps are start-time policy, NOT user tuning —
              # never resurrect them from an old sidecar (a pre-uncap Sandbox
              # snapshot would otherwise reimpose the old replication_cap). Keep
              # the world's current caps; restore the rest of the tunables.
              tunables = Map.drop(cfg_map, [:spawn_cap, :replication_cap])
              Lenies.World.Config.merge(state.config, tunables)

            :none ->
              state.config
          end

        # Bulk reload bypassed put_cell/4 — rebuild indices from the loaded
        # cells and publish the occupancy snapshot so the restored lenies appear
        # on the canvas without waiting for a tick (restore can run while paused).
        new_state = reseed_indices(%{state | config: restored_config})

        # Stats payload: gives Telemetry + Dashboards everything they
        # need to refresh `:latest` without waiting for the next tick.
        # Solves the "Population stays at 0 after restore" symptom when
        # the world is paused (no tick) immediately post-restore.
        stats = %{
          tick: new_state.tick_count,
          population: :ets.info(new_state.tables.lenies, :size) || 0,
          total_resource: new_state.total_resource,
          total_carcass: new_state.total_carcass
        }

        broadcast(new_state, "control", {:restored, System.system_time(:millisecond), stats})
        {:reply, :ok, new_state}

      {:error, _} = err ->
        # Sterilize already ran in a previous call. The simulation tables
        # are empty; rebuild the cached indices so they reflect reality.
        {:reply, err, reseed_indices(state)}
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

  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:tune, key, value}, _from, state) do
    if Map.has_key?(Map.from_struct(state.config), key) do
      new_config = Map.put(state.config, key, value)
      broadcast(state, "control", {:config_changed, key, value})
      {:reply, :ok, %{state | config: new_config}}
    else
      {:reply, {:error, {:unknown_tunable, key}}, state}
    end
  end

  def handle_call(:reconcile, _from, state) do
    {result, new_state} = do_reconcile(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:action, action_spec}, _from, state) do
    {result, new_state} = do_action(action_spec, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:spawn_lenie, codeome, opts}, _from, state) do
    current_pop = :ets.info(state.tables.lenies, :size)

    if state.config.spawn_cap != :infinity and current_pop >= state.config.spawn_cap do
      {:reply, {:error, :spawn_cap_exceeded}, state}
    else
      do_spawn_lenie(codeome, opts, state)
    end
  end

  defp do_spawn_lenie(codeome, opts, state) do
    case find_random_free_cell(state.grid, state.tables) do
      {:ok, pos} ->
        lenie_id = generate_lenie_id()
        energy = Keyword.get(opts, :energy, 500.0)
        dir = Keyword.get(opts, :dir, :n)
        lineage = Keyword.get(opts, :lineage, {nil, 0})
        seed_origin = Keyword.get(opts, :seed_origin)
        # Arena lineage tag (sub-project #4). `nil` for Sandbox spawns; the
        # Arena passes the user's id so the "one alive lineage per user" rule
        # can be enforced via :ets.select on handle.tables.lenies.
        seeder_user_id = Keyword.get(opts, :seeder_user_id)
        plasmids = Keyword.get(opts, :plasmids, [])

        child_opts = [
          id: lenie_id,
          codeome: codeome,
          energy: energy * 1.0,
          pos: pos,
          dir: dir,
          lineage: lineage,
          seed_origin: seed_origin,
          seeder_user_id: seeder_user_id,
          # Inherit the world's current pause flag so a Lenie spawned
          # while the world is paused stays dormant until resume.
          paused?: state.paused?,
          plasmids: plasmids
        ]

        # A child whose init fails must NOT crash the World — that would drop
        # every Lenie in this world and reset it to empty (the ETS tables are
        # owned by this process). Handle the error like the snapshot-restore
        # path does: leave the cell free and report the failure to the caller.
        case start_lenie_child(state, child_opts) do
          {:ok, _pid} ->
            [{key, cell}] = :ets.lookup(state.tables.cells, pos)
            state = put_cell(state, key, cell, %{cell | lenie_id: lenie_id})

            # User spawn can happen while paused: publish the snapshot so the new
            # lenie appears immediately (no tick to refresh it otherwise).
            state = store_occupancy(state)

            {:reply, {:ok, {lenie_id, pos}}, state}

          other ->
            Logger.warning(
              "World #{inspect(state.world_id)}: spawn_lenie failed to start child: #{inspect(other)}"
            )

            {:reply, {:error, :spawn_failed}, state}
        end

      :no_free_cell ->
        {:reply, {:error, :no_free_cell}, state}
    end
  end

  # Single choke point for starting a Lenie process under this world's
  # LenieSupervisor. Returns the raw `DynamicSupervisor.start_child/2` result so
  # every caller can decide how to handle a failed start WITHOUT a strict match
  # that would crash the World (and wipe its ETS-owned population).
  defp start_lenie_child(state, child_opts) do
    DynamicSupervisor.start_child(
      Lenies.LenieSupervisor.via(state.world_id),
      Supervisor.child_spec({Lenies.Lenie, {state.handle, child_opts}}, restart: :temporary)
    )
  end

  def handle_cast({:lenie_died, id, pos, energy, hash, seeder_user_id}, state),
    do: handle_cast({:lenie_died, id, pos, energy, hash, seeder_user_id, :natural}, state)

  @impl true
  def handle_cast(
        {:lenie_died, id, {x, y}, energy_at_death, codeome_hash, seeder_user_id, cause},
        state
      ) do
    state =
      case :ets.lookup(state.tables.cells, {x, y}) do
        [{key, cell}] ->
          carcass_value = max(0, trunc(energy_at_death * 0.5))
          hue = Lenies.SpeciesColor.hue_byte(state.handle, codeome_hash)

          if cause == :natural do
            broadcast(state, "fx", {:death, %{x: x, y: y, hue: hue}})
          end

          new_cell = %{
            cell
            | lenie_id: nil,
              carcass: cell.carcass + carcass_value,
              carcass_hue: hue
          }

          put_cell(state, key, cell, new_cell)

        _ ->
          state
      end

    :ets.delete(state.tables.lenies, id)

    # Sub-project #4: if the dead Lenie carried a seeder_user_id (Arena lineage),
    # broadcast on the user's per-user topic so ArenaLive's Seed/Apoptosis UI
    # refreshes. Covers natural death (starvation, attack) — the seed and
    # apoptosis paths broadcast from Lenies.Arena directly.
    if state.world_id == :arena and is_integer(seeder_user_id) do
      Phoenix.PubSub.broadcast(
        Lenies.PubSub,
        "arena:user:#{seeder_user_id}",
        {:arena_lineage_changed, seeder_user_id}
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    state = maybe_schedule_tick(%{state | tick_ref: nil})
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    {_counts, state} = do_reconcile(state)
    state = schedule_reconcile(%{state | reconcile_ref: nil})
    {:noreply, state}
  end

  # Diagnostic net: if the World GenServer ever dies for an abnormal reason, its
  # ETS tables die with it and `rest_for_one` resets the world to empty (see
  # Lenies.World.Supervisor). That presents to the user as "the sandbox got
  # killed and restarts empty". Log the crash reason + key state BEFORE the
  # tables vanish so the cause is captured instead of lost. Normal shutdowns
  # (`:normal`, `:shutdown`, `{:shutdown, _}`) are silent.
  @impl true
  def terminate(reason, state)
      when reason not in [:normal, :shutdown] and
             not (is_tuple(reason) and elem(reason, 0) == :shutdown) do
    Logger.error(
      "Lenies.World #{inspect(state.world_id)} TERMINATING abnormally " <>
        "(pop=#{safe_size(state)}, tick=#{Map.get(state, :tick_count)}): " <>
        Exception.format_exit(reason)
    )

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp safe_size(%{tables: %{lenies: t}}) do
    case :ets.info(t, :size) do
      n when is_integer(n) -> n
      _ -> "?"
    end
  rescue
    _ -> "?"
  end

  defp safe_size(_), do: "?"

  # ----- internals -----

  # Wipes the simulation tables (cells, lenies, child_slots, history),
  # terminates all live Lenies, cancels timers, reseeds the cell grid from the
  # resource field, and reschedules the tick and reconcile timers. Returns the
  # new state. Color overrides are
  # preserved per the SpeciesColor contract — they represent user intent,
  # not simulation state.
  #
  # Shared by the `:sterilize` and `:restore_snapshot` handle_calls. Note: this
  # helper does NOT broadcast the `{:sterilized, …}` event — the caller is
  # expected to broadcast whatever event matches its semantics (`:sterilized`
  # vs `:restored`).
  defp do_sterilize(state) do
    terminate_all_lenies(state.world_id)
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    if state.reconcile_ref, do: Process.cancel_timer(state.reconcile_ref)
    Tables.clear_all(Map.drop(state.tables, [:color_overrides]))
    init_cells_from_field(state.field, state.grid, state.tables, 3 * cfg(state, :eat_amount))

    new_state = %{
      state
      | tick_count: 0,
        tick_ref: nil,
        reconcile_ref: nil,
        occupancy: %{},
        carcass_cells: MapSet.new(),
        total_resource: 0,
        total_carcass: 0
    }
    # Rebuild indices + publish the (now empty-of-lenies) occupancy snapshot so
    # the canvas clears immediately — sterilize can run while paused (no tick).
    new_state = reseed_indices(new_state)
    new_state = maybe_schedule_tick(new_state)
    schedule_reconcile(new_state)
  end

  # Runtime source of truth for per-world tunables. The keys previously
  # served by @cfg_defaults (eat_amount, carcass_decay, tick_interval_ms,
  # copy_substitution_rate, copy_insert_rate, copy_delete_rate,
  # background_mutation_rate_per_1000_ticks, attack_damage)
  # have all been promoted to %Lenies.World.Config{} fields (see config.ex).
  # `Lenies.Worlds.tune/3` mutates state.config and broadcasts
  # {:config_changed, key, value} on the world's control topic — the engine
  # just reads from state. `Map.fetch!` crashes loudly on a typo, which is
  # what we want.
  defp cfg(state, key) do
    Map.fetch!(state.config, key)
  end

  # Seed every cell's resource from the field at tick 0 → a coherent fluctuating
  # field immediately, no radiation warmup loop.
  defp init_cells_from_field(field, {w, h}, tables, cap) do
    for x <- 0..(w - 1), y <- 0..(h - 1) do
      target = round(Field.level(field, x, y, 0) * cap)
      :ets.insert(tables.cells, {{x, y}, %Cell{resource: target}})
    end

    :ok
  end

  defp do_tick(state) do
    # Resource/carcass totals and the occupancy/carcass indices are maintained
    # incrementally via put_cell/4, so a tick no longer folds the whole grid:
    # field relaxation runs every FIELD_PERIOD ticks, decay only the carcass set.
    state = apply_field(state)
    state = decay_carcasses(state)
    maybe_background_mutation(state)

    # Publish the occupancy snapshot the renderer reads (one atomic key write).
    state = store_occupancy(state)

    stats = %{
      population: :ets.info(state.tables.lenies, :size),
      total_resource: state.total_resource,
      total_carcass: state.total_carcass
    }

    broadcast(state, "tick", {:tick, state.tick_count + 1, stats})

    %{state | tick_count: state.tick_count + 1}
  end

  # Field-relaxation sweep: every FIELD_PERIOD ticks, pull each cell's resource
  # toward field(x,y,tick) * cap. Deadband skips near-target cells (cheap under
  # slow fields). Valleys (target ~0) recede → moving deserts.
  @field_period 5
  @relax_rate 0.15
  @deadband 3

  defp apply_field(%{tick_count: tc} = state) when rem(tc, @field_period) != 0, do: state

  defp apply_field(state) do
    cap = 3 * cfg(state, :eat_amount)
    {w, h} = state.grid

    Enum.reduce(0..(h - 1), state, fn y, acc_y ->
      Enum.reduce(0..(w - 1), acc_y, fn x, acc ->
        target = round(Field.level(acc.field, x, y, acc.tick_count) * cap)

        case :ets.lookup(acc.tables.cells, {x, y}) do
          [{key, cell}] ->
            if abs(target - cell.resource) <= @deadband do
              acc
            else
              new_cell = Cell.relax_resource(cell, target, @relax_rate)
              if new_cell == cell, do: acc, else: put_cell(acc, key, cell, new_cell)
            end

          [] ->
            acc
        end
      end)
    end)
  end

  # The single choke point for EVERY `:cells` write. It updates the cell in ETS
  # and keeps the in-state indices exact by diffing old vs new:
  #   - `occupancy`     — `%{ {x,y} => lenie_id }` of occupied cells
  #   - `carcass_cells` — `MapSet` of cells with `carcass > 0`
  #   - `total_resource` / `total_carcass` — running grid sums
  #
  # Because deltas are derived from old→new (never hand-computed per call site),
  # the indices cannot drift as long as every cell write goes through here. The
  # rare bulk paths (init / sterilize / reset_energy / restore) skip this and
  # call `reseed_indices/1` to rebuild from a full scan instead.
  defp put_cell(state, key, old_cell, new_cell) do
    :ets.insert(state.tables.cells, {key, new_cell})

    occupancy =
      cond do
        old_cell.lenie_id == new_cell.lenie_id -> state.occupancy
        is_binary(new_cell.lenie_id) -> Map.put(state.occupancy, key, new_cell.lenie_id)
        true -> Map.delete(state.occupancy, key)
      end

    carcass_cells =
      cond do
        old_cell.carcass > 0 == new_cell.carcass > 0 -> state.carcass_cells
        new_cell.carcass > 0 -> MapSet.put(state.carcass_cells, key)
        true -> MapSet.delete(state.carcass_cells, key)
      end

    %{
      state
      | occupancy: occupancy,
        carcass_cells: carcass_cells,
        total_resource: state.total_resource + (new_cell.resource - old_cell.resource),
        total_carcass: state.total_carcass + (new_cell.carcass - old_cell.carcass)
    }
  end

  # Carcass decay, per tick. Iterates ONLY the carcass-cell index (typically a
  # few dozen cells) instead of folding all 16 384 cells. `put_cell/4` keeps the
  # index and `total_carcass` exact (cells decayed to 0 drop out of the set).
  defp decay_carcasses(state) do
    rate = cfg(state, :carcass_decay)

    if rate > 0 do
      Enum.reduce(MapSet.to_list(state.carcass_cells), state, fn key, acc ->
        case :ets.lookup(acc.tables.cells, key) do
          [{^key, %{carcass: c} = cell}] when c > 0 ->
            put_cell(acc, key, cell, Cell.decay_carcass(cell, rate))

          _ ->
            acc
        end
      end)
    else
      state
    end
  end

  # Persist the occupancy snapshot under a single ETS key. A single-key
  # `:ets.insert` is atomic, so the renderer's single-key `:ets.lookup` always
  # reads a coherent whole-map snapshot (never a half-applied move).
  defp store_occupancy(state) do
    :ets.insert(state.tables.occupancy, {:snapshot, state.occupancy})
    state
  end

  # Authoritative rebuild of ALL cached indices from a full `:cells` scan, and
  # publish the occupancy snapshot. Used by the bulk paths (init / sterilize /
  # reset_energy / restore) and as the periodic self-heal inside `do_reconcile/1`
  # — so any drift from a missed `put_cell/4` site is corrected within one
  # reconcile cycle (~30 s).
  defp reseed_indices(state) do
    {occ, carc, total_r, total_c} =
      :ets.foldl(
        fn {key, cell}, {occ, carc, total_r, total_c} ->
          occ = if is_binary(cell.lenie_id), do: Map.put(occ, key, cell.lenie_id), else: occ
          carc = if cell.carcass > 0, do: MapSet.put(carc, key), else: carc
          {occ, carc, total_r + cell.resource, total_c + cell.carcass}
        end,
        {%{}, MapSet.new(), 0, 0},
        state.tables.cells
      )

    %{
      state
      | occupancy: occ,
        carcass_cells: carc,
        total_resource: total_r,
        total_carcass: total_c
    }
    |> store_occupancy()
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

  defp maybe_schedule_tick(%{paused?: true} = state), do: state

  defp maybe_schedule_tick(state) do
    # state.config.tick_interval_ms is the single source of truth (seeded from
    # opts in init/1, mutated live by Lenies.Worlds.tune/3). 0 or nil disables
    # auto-ticking — heavily used by tests via start_link(tick_interval_ms: 0).
    case state.config.tick_interval_ms do
      interval when interval in [0, nil] ->
        state

      interval ->
        ref = Process.send_after(self(), :tick, interval)
        %{state | tick_ref: ref}
    end
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
      {{0, 0}, state}
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

      # Self-heal: rebuild all cached indices from the now-corrected cells. This
      # both reflects the freed stale cells AND repairs any drift that could have
      # crept into the incremental indices since the last reconcile.
      new_state = reseed_indices(state)

      {{length(stale_cell_keys), length(stale_lenie_ids)}, new_state}
    end
  end

  defp terminate_all_lenies(world_id) do
    case Registry.lookup(Lenies.Registry, {:lenie_sup, world_id}) do
      [] ->
        :ok

      [{_pid, _}] ->
        sup = Lenies.LenieSupervisor.via(world_id)

        sup
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_, child_pid, _, _} ->
          if is_pid(child_pid),
            do: DynamicSupervisor.terminate_child(sup, child_pid)
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
        # move successful: clear the source cell, occupy the front cell
        [{src_key, src_cell}] = :ets.lookup(state.tables.cells, {x, y})

        state =
          state
          |> put_cell(src_key, src_cell, %{src_cell | lenie_id: nil})
          |> put_cell(front, front_cell, %{front_cell | lenie_id: lenie_id})

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
        state = put_cell(state, key, cell, new_cell)
        {{:ok, {:ate, energy_gained}}, state}

      _ ->
        {{:ok, {:ate, 0}}, state}
    end
  end

  defp do_action({:allocate, size, {x, y}, dir, parent_id}, state) do
    {min_size, max_size} = Lenies.Config.codeome_length_bounds()

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
    current_pop = :ets.info(state.tables.lenies, :size)

    if state.config.replication_cap != :infinity and
         current_pop >= state.config.replication_cap do
      # Hit replication cap — Lenie skips this divide (treated identically to
      # :no_slot by the calling Lenie's apply_world_action({:divide, …})
      # which has a catch-all {:ok, _failure} branch at lenie.ex:449).
      {{:ok, :replication_cap_exceeded}, state}
    else
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

        case record do
          %{pos: {vx, vy}} -> broadcast(state, "fx", {:predation, %{x: vx, y: vy}})
          _ -> :ok
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
    # Extra-chromosomal inheritance: each plasmid segregates to the child with
    # probability 1 - p_loss, then mutates. This is what bounds the carried
    # count at equilibrium (vs. the old unbounded full-list inheritance).
    kept_plasmids = segregate_plasmids(parent_plasmids, Lenies.Config.plasmid_loss_probability())
    child_plasmids = mutate_plasmids(kept_plasmids, state)

    child_opts = [
      id: child_id,
      codeome: child_codeome,
      energy: child_energy * 1.0,
      pos: slot.target_cell,
      dir: parent_record.dir,
      lineage: {parent_id, parent_generation + 1},
      seed_origin: parent_seed_origin,
      paused?: state.paused?,
      plasmids: child_plasmids,
      seeder_user_id: Map.get(parent_record, :seeder_user_id)
    ]

    # A failed child start must not crash the World (that would wipe the whole
    # population to empty). On failure, release the parent's slot and report a
    # benign failure — the calling Lenie treats it like any other failed divide.
    case start_lenie_child(state, child_opts) do
      {:ok, _child_pid} ->
        # Mark child cell occupied
        [{key, cell}] = :ets.lookup(state.tables.cells, slot.target_cell)
        state = put_cell(state, key, cell, %{cell | lenie_id: child_id})

        # Clean up parent's slot
        ChildSlots.delete(state.tables.child_slots, slot_id)
        update_lenie_record(parent_id, &Map.put(&1, :child_slot_id, nil), state)

        {cx, cy} = slot.target_cell
        child_hue = Lenies.SpeciesColor.hue_byte(state.handle, Codeome.hash(child_codeome))
        broadcast(state, "fx", {:division, %{x: cx, y: cy, hue: child_hue}})

        {{:ok, {:divided, child_id, child_energy}}, state}

      other ->
        Logger.warning(
          "World #{inspect(state.world_id)}: divide failed to start child: #{inspect(other)}"
        )

        ChildSlots.delete(state.tables.child_slots, slot_id)
        update_lenie_record(parent_id, &Map.put(&1, :child_slot_id, nil), state)
        {{:ok, :spawn_failed}, state}
    end
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

  # Eat empties the cell: the Lenie gains ALL resource + carcass in one bite.
  # Cells are batteries the field recharges (toward field*cap); a bite drains
  # one fully, forcing graze-and-move foraging.
  defp consume_eat(cell, _eat_amount) do
    total_energy = cell.resource + cell.carcass
    new_cell = %{cell | resource: 0, carcass: 0, carcass_hue: 0}
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

  @doc """
  Stochastic segregational loss: each plasmid is independently kept with
  probability `1 - p_loss`. `p_loss = 0.0` keeps all; `p_loss = 1.0` drops all
  (`:rand.uniform/0` returns a value in `(0.0, 1.0]`, so `> 1.0` is never true).
  Public for unit testing.
  """
  @spec segregate_plasmids([Lenies.Plasmid.t()], float()) :: [Lenies.Plasmid.t()]
  def segregate_plasmids(plasmids, p_loss) when is_list(plasmids) do
    Enum.filter(plasmids, fn _ -> :rand.uniform() > p_loss end)
  end

  defp mutate_plasmids(plasmids, state) when is_list(plasmids) do
    %{substitution: sub_rate, insert: ins_rate, delete: del_rate} = current_copy_rates(state)

    Enum.map(plasmids, fn %Lenies.Plasmid{opcodes: ops} = p ->
      %{p | opcodes: Lenies.Mutator.copy_mutate_list(ops, sub_rate, ins_rate, del_rate)}
    end)
  end

  # ----- PubSub helpers -----
  #
  # Each broadcast goes to the world's scoped topic
  # (`"world:<id>:<channel>"`). Subscribers (LiveViews, Telemetry, tests)
  # subscribe via the handle's `pubsub_prefix`.

  defp broadcast(state, channel, message) do
    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "#{state.handle.pubsub_prefix}:#{channel}",
      message
    )
  end

  # ----- snapshot restore: respawn ghost Lenies -----

  # Iterate every entry in the freshly-loaded :lenies ETS and start a
  # corresponding Lenie GenServer for each. The new GenServer's init/2
  # will write a fresh snapshot back into ETS, which Map.merges over the
  # existing record — preserving fields outside the snapshot map (e.g.
  # :child_slot_id set by World on previous :allocate calls) while
  # updating pid/pos/dir/energy/lineage/seed_origin/seeder_user_id/
  # plasmids to the values we passed as opts.
  #
  # Trade-off: interpreter state (ip, stack, slots, call_stack, age)
  # is NOT preserved — the respawned Lenie restarts execution from
  # ip=0 with empty stack/slots/call_stack and age=0. Preserving the
  # interpreter state would require extending Lenie.init/1 with an
  # :interp_state opt; out of scope for this fix.
  defp respawn_lenies_from_snapshots(state) do
    state.tables.lenies
    |> :ets.tab2list()
    |> Enum.reduce(0, fn {_id, snap}, acc ->
      case respawn_one_from_snap(snap, state) do
        :ok -> acc + 1
        :skip -> acc
      end
    end)
  end

  defp respawn_one_from_snap(snap, state) do
    case codeome_from_snap(snap) do
      nil ->
        Logger.warning(
          "Snapshot restore: skipping Lenie #{inspect(snap[:id])} — codeome not recoverable (old snapshot format and codeome_hash not in :species_codeomes cache)"
        )

        :skip

      codeome ->
        # codeome_from_snap returns a plain [opcode] list; Lenie.init expects
        # a %Lenies.Codeome{} struct (do_spawn_lenie's normal flow passes one
        # via Worlds.spawn_lenie/3, and Lenie.init then calls Codeome.hash/1
        # which only accepts the struct). Wrap before passing.
        child_opts = [
          id: snap.id,
          codeome: Lenies.Codeome.from_list(codeome),
          energy: Map.get(snap, :energy, 500.0) * 1.0,
          pos: Map.get(snap, :pos, {0, 0}),
          dir: Map.get(snap, :dir, :n),
          lineage: Map.get(snap, :lineage, {nil, 0}),
          seed_origin: Map.get(snap, :seed_origin),
          seeder_user_id: Map.get(snap, :seeder_user_id),
          paused?: state.paused?,
          plasmids: Map.get(snap, :plasmids, [])
        ]

        case start_lenie_child(state, child_opts) do
          {:ok, _pid} ->
            :ok

          other ->
            Logger.warning(
              "Snapshot restore: failed to respawn Lenie #{inspect(snap[:id])}: #{inspect(other)}"
            )

            :skip
        end
    end
  end

  # New-format snapshots (post-2026-06-01) persist the full opcode list
  # under :codeome. Older snapshots only have :codeome_hash — for those
  # we fall back to the node-wide :species_codeomes cache (populated by
  # Lenie.init/1 across every Lenie ever spawned on this node, plus by
  # the snapshot sidecar at restore time). Cache miss (e.g. fresh node
  # restart with no prior Lenies of that species AND no sidecar) returns
  # nil, and the caller skips the entry with a warning.
  #
  # Accepts both `[opcode]` (current shape, written by lenie.ex
  # `maybe_write_snapshot/1`) and `%Lenies.Codeome{}` (legacy shape
  # written by a brief window of snapshots saved between 164cf30 and
  # the fix that flattens to a list). Both decode to the same list.
  defp codeome_from_snap(snap) do
    case Map.get(snap, :codeome) do
      list when is_list(list) and list != [] ->
        list

      %Lenies.Codeome{} = c ->
        case Lenies.Codeome.to_list(c) do
          [] -> codeome_from_hash(snap)
          list -> list
        end

      _ ->
        codeome_from_hash(snap)
    end
  end

  defp codeome_from_hash(snap) do
    case Map.get(snap, :codeome_hash) do
      hash when is_binary(hash) ->
        case :ets.lookup(:species_codeomes, hash) do
          [{^hash, opcodes}] when is_list(opcodes) -> opcodes
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
