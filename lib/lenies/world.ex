defmodule Lenies.World do
  @moduledoc """
  The Lenies sandbox "world". Singleton GenServer that owns the ETS tables,
  drives the environmental tick, applies radiation and carcass decay, and
  provides the public API for snapshots and sterilization.

  See `docs/superpowers/specs/2026-05-11-lenies-design.md` §3, §6, §9.
  """

  use GenServer

  alias Lenies.Config
  alias Lenies.World.{Cell, ChildSlots, Hotspots, Radiation, Tables}
  alias Lenies.{Codeome, Mutator}

  @name __MODULE__

  # ----- Public API -----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

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
  def init(opts) do
    Tables.create_all()
    grid = Config.grid_size()
    init_cells(grid)

    tick_interval = Keyword.get(opts, :tick_interval_ms, Config.tick_interval_ms())
    hotspots = Hotspots.initial(grid, Config.hotspot_count())

    {total_resource, total_carcass} = sum_cells()

    state = %{
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
    {r, c} = sum_cells()
    state = %{state | total_resource: r, total_carcass: c}
    state = maybe_schedule_tick(state)
    state = schedule_reconcile(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot_stats, _from, state) do
    # total_resource and total_carcass are maintained as cached values in state,
    # updated once per tick in decay_and_sum_cells/0. Between ticks the values
    # may be up to one tick stale, which is acceptable for a stats display.
    stats = %{
      cells: :ets.info(:cells, :size),
      population: :ets.info(:lenies, :size),
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
    Tables.clear_all()
    init_cells(state.grid)
    hotspots = Hotspots.initial(state.grid, Config.hotspot_count())
    {total_resource, total_carcass} = sum_cells()

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
    {r, c} = sum_cells()
    new_state = %{new_state | total_resource: r, total_carcass: c}
    new_state = maybe_schedule_tick(new_state)
    new_state = schedule_reconcile(new_state)

    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "world:control",
      {:sterilized, System.system_time(:millisecond)}
    )

    {:reply, :ok, new_state}
  end

  def handle_call({:restore_tables, dir}, _from, state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    if state.reconcile_ref, do: Process.cancel_timer(state.reconcile_ref)

    result =
      try do
        Enum.reduce_while(Lenies.Snapshot.tables(), :ok, fn table, _acc ->
          path = Path.join(dir, "#{table}.tab") |> String.to_charlist()

          # The table still exists after sterilize; delete it so file2tab can
          # recreate it owned by THIS (World) process.
          if :ets.whereis(table) != :undefined, do: :ets.delete(table)

          case :ets.file2tab(path) do
            {:ok, _} -> {:cont, :ok}
            _error -> {:halt, {:error, {:restore_failed, table}}}
          end
        end)
      rescue
        _ -> {:error, {:restore_failed, :unknown}}
      end

    # Reset tick bookkeeping like sterilize does and reschedule the tick and reconcile.
    new_state = %{state | tick_count: 0, tick_ref: nil, reconcile_ref: nil}
    new_state = maybe_schedule_tick(new_state)
    new_state = schedule_reconcile(new_state)

    case result do
      :ok ->
        # Recompute totals from the freshly loaded :cells table.
        {r, c} = sum_cells()
        new_state = %{new_state | total_resource: r, total_carcass: c}

        Phoenix.PubSub.broadcast(
          Lenies.PubSub,
          "world:control",
          {:restored, System.system_time(:millisecond)}
        )

        {:reply, :ok, new_state}

      {:error, _} = err ->
        # Recovery: if file2tab failed partway through the loop, one or more
        # snapshot tables may be missing (deleted but not recreated). An absent
        # named table would cause World to crash on the next ETS lookup, so we
        # recreate all 4 as fresh empty tables and re-initialise the :cells grid
        # to leave the world in a valid, consistent (empty) state.
        recover_tables(state.grid)
        {r, c} = sum_cells()
        new_state = %{new_state | total_resource: r, total_carcass: c}
        {:reply, err, new_state}
    end
  end

  def handle_call(:pause, _from, state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    # Broadcast pause/resume on world:control so each Lenie can suspend
    # its metabolize loop too — otherwise the environmental tick stops
    # but the Lenies keep moving in the background and the canvas
    # silently goes out of sync with reality.
    Phoenix.PubSub.broadcast(Lenies.PubSub, "world:control", :world_paused)
    {:reply, :ok, %{state | paused?: true, tick_ref: nil}}
  end

  def handle_call(:resume, _from, state) do
    new_state = %{state | paused?: false}
    new_state = maybe_schedule_tick(new_state)
    Phoenix.PubSub.broadcast(Lenies.PubSub, "world:control", :world_resumed)
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
    case find_random_free_cell(state.grid) do
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
            Supervisor.child_spec({Lenies.Lenie, child_opts}, restart: :temporary)
          )

        [{key, cell}] = :ets.lookup(:cells, pos)
        :ets.insert(:cells, {key, %{cell | lenie_id: lenie_id}})

        {:reply, {:ok, {lenie_id, pos}}, state}

      :no_free_cell ->
        {:reply, {:error, :no_free_cell}, state}
    end
  end

  @impl true
  def handle_cast({:lenie_died, id, {x, y}, energy_at_death, codeome_hash}, state) do
    case :ets.lookup(:cells, {x, y}) do
      [{key, cell}] ->
        carcass_value = max(0, trunc(energy_at_death * 0.5))
        hue = Lenies.SpeciesColor.hue_byte(codeome_hash)

        :ets.insert(:cells, {
          key,
          %{cell | lenie_id: nil, carcass: cell.carcass + carcass_value, carcass_hue: hue}
        })

      _ ->
        :ok
    end

    :ets.delete(:lenies, id)
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

  defp init_cells({w, h}) do
    initial_resource = Application.get_env(:lenies, :initial_resource_per_cell, 30)

    for x <- 0..(w - 1), y <- 0..(h - 1) do
      :ets.insert(:cells, {{x, y}, %Cell{resource: initial_resource}})
    end

    :ok
  end

  # Recreate all 4 snapshot tables from scratch when a restore fails mid-loop.
  # Any table that currently exists is deleted first so the :new/2 call can
  # register the :named_table. The :cells grid is then populated the same way
  # init/1 does it, so the world is immediately usable after recovery.
  defp recover_tables(grid) do
    table_opts = [:set, :named_table, :public, read_concurrency: true, write_concurrency: true]

    for table <- Lenies.Snapshot.tables() do
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
      :ets.new(table, table_opts)
    end

    init_cells(grid)
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
    {total_resource, total_carcass} = decay_and_sum_cells()
    maybe_background_mutation(state)

    hotspots = Hotspots.drift(state.hotspots, state.grid)

    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "world:tick",
      {:tick, state.tick_count + 1}
    )

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
        Config.radiation_per_tick(),
        state.hotspots,
        uniform_ratio: Config.radiation_uniform_ratio()
      )

    Enum.each(deposit, fn {{x, y}, amount} ->
      case :ets.lookup(:cells, {x, y}) do
        [{key, cell}] ->
          :ets.insert(:cells, {key, Cell.add_resource(cell, amount)})

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
  defp decay_and_sum_cells do
    rate = Config.carcass_decay()

    :ets.foldl(
      fn {key, cell}, {sum_r, sum_c} ->
        effective_cell =
          if rate > 0 and cell.carcass > 0 do
            decayed = Cell.decay_carcass(cell, rate)
            :ets.insert(:cells, {key, decayed})
            decayed
          else
            cell
          end

        {sum_r + effective_cell.resource, sum_c + effective_cell.carcass}
      end,
      {0, 0},
      :cells
    )
  end

  # Background mutations are configured as a RATE — N mutations per 1000
  # world ticks (0 = off) — because a rate scale is monotone with the
  # observed mutation pressure (higher = more), unlike an interval scale
  # where bigger numbers mean rarer events. We convert internally to a
  # tick interval so the rest of the logic stays modular arithmetic.
  defp maybe_background_mutation(state) do
    rate = Application.get_env(:lenies, :background_mutation_rate_per_1000_ticks, 1)

    if rate > 0 do
      interval = max(1, div(1000, rate))

      if rem(state.tick_count + 1, interval) == 0 do
        apply_random_background_mutation()
      end
    end

    :ok
  end

  defp apply_random_background_mutation do
    case :ets.tab2list(:lenies) do
      [] ->
        :ok

      records ->
        # Pick a random Lenie's id
        {id, _record} = Enum.random(records)

        case Lenies.Registry.whereis(id) do
          pid when is_pid(pid) -> send(pid, :background_mutate)
          _ -> :ok
        end
    end
  end

  # One fold returning {total_resource, total_carcass} without side effects.
  # Used at init, sterilize, and restore_tables to seed the cached totals.
  defp sum_cells do
    :ets.foldl(
      fn {_key, cell}, {r, c} -> {r + cell.resource, c + cell.carcass} end,
      {0, 0},
      :cells
    )
  end

  defp maybe_schedule_tick(%{tick_interval_ms: 0} = state), do: state
  defp maybe_schedule_tick(%{tick_interval_ms: nil} = state), do: state
  defp maybe_schedule_tick(%{paused?: true} = state), do: state

  defp maybe_schedule_tick(state) do
    # Re-read from Application env so the dashboard slider can change tick rate
    # live on a running world. Falls back to the value supplied at start_link.
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
  defp do_reconcile(_state) do
    # Guard: if the Registry is not available (e.g. supervisor not started)
    # return immediately without crashing World.
    if Process.whereis(Lenies.Registry) == nil do
      {0, 0}
    else
      # Pass 1 — collect keys of cells occupied by dead Lenies
      stale_cell_keys =
        :ets.foldl(
          fn {key, cell}, acc ->
            if is_binary(cell.lenie_id) and not is_pid(Lenies.Registry.whereis(cell.lenie_id)) do
              [key | acc]
            else
              acc
            end
          end,
          [],
          :cells
        )

      # Apply: free each stale cell (no carcass — we have no reliable energy)
      Enum.each(stale_cell_keys, fn key ->
        case :ets.lookup(:cells, key) do
          [{^key, cell}] -> :ets.insert(:cells, {key, %{cell | lenie_id: nil}})
          _ -> :ok
        end
      end)

      # Pass 2 — collect ids of orphaned :lenies records
      stale_lenie_ids =
        :ets.foldl(
          fn {id, _record}, acc ->
            if not is_pid(Lenies.Registry.whereis(id)) do
              [id | acc]
            else
              acc
            end
          end,
          [],
          :lenies
        )

      # Apply: delete each orphaned record
      Enum.each(stale_lenie_ids, fn id -> :ets.delete(:lenies, id) end)

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

    case :ets.lookup(:cells, front) do
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

    case :ets.lookup(:cells, front) do
      [{_, %{lenie_id: nil} = front_cell}] ->
        # move successful
        [{src_key, src_cell}] = :ets.lookup(:cells, {x, y})
        :ets.insert(:cells, {src_key, %{src_cell | lenie_id: nil}})
        :ets.insert(:cells, {front, %{front_cell | lenie_id: lenie_id}})
        {{:ok, {:moved, front}}, state}

      _ ->
        {{:ok, :blocked}, state}
    end
  end

  defp do_action({:eat, {x, y}}, state) do
    case :ets.lookup(:cells, {x, y}) do
      [{key, cell}] ->
        eat_amount = Application.get_env(:lenies, :eat_amount, 20)
        {energy_gained, new_cell} = consume_eat(cell, eat_amount)
        :ets.insert(:cells, {key, new_cell})
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

      parent_already_allocated?(parent_id) ->
        {{:ok, :already_allocated}, state}

      true ->
        target_cell = front_cell({x, y}, dir, state.grid)

        case :ets.lookup(:cells, target_cell) do
          [{_, %{lenie_id: nil}}] ->
            {:ok, slot_id} = ChildSlots.create(parent_id, target_cell, size)
            update_lenie_record(parent_id, &Map.put(&1, :child_slot_id, slot_id))
            {{:ok, {:allocated, slot_id, target_cell}}, state}

          _ ->
            {{:ok, :blocked}, state}
        end
    end
  end

  defp do_action({:write_child, opcode_int, child_addr, parent_id}, state) do
    case :ets.lookup(:lenies, parent_id) do
      [{^parent_id, %{child_slot_id: slot_id}}] when is_binary(slot_id) ->
        rates = current_copy_rates()
        outcome = Mutator.copy_outcome(rates)
        opcode = Codeome.Opcodes.decode(opcode_int)

        :ok = apply_copy_outcome(slot_id, child_addr, opcode, outcome)
        {{:ok, :written}, state}

      _ ->
        {{:ok, :no_slot}, state}
    end
  end

  defp do_action({:divide, parent_energy, _pos, _dir, parent_id}, state) do
    case :ets.lookup(:lenies, parent_id) do
      [{^parent_id, %{child_slot_id: slot_id} = parent_record}] when is_binary(slot_id) ->
        case ChildSlots.get(slot_id) do
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

    case :ets.lookup(:lenies, lenie_id) do
      [{^lenie_id, _record}] ->
        update_lenie_record(lenie_id, &Map.put(&1, :defending_until, state.tick_count + window))
        {{:ok, :defending}, state}

      _ ->
        {{:ok, :no_lenie}, state}
    end
  end

  defp do_action({:attack, {x, y}, dir, attacker_id}, state) do
    target_cell = front_cell({x, y}, dir, state.grid)

    case :ets.lookup(:cells, target_cell) do
      [{_, %{lenie_id: target_id}}] when is_binary(target_id) ->
        resolve_attack(target_id, attacker_id, state)

      _ ->
        {{:ok, :no_target}, state}
    end
  end

  defp do_action(_unknown, state), do: {{:ok, {:error, :unknown_action}}, state}

  defp resolve_attack(target_id, attacker_id, state) do
    base_damage = Application.get_env(:lenies, :attack_damage, 10)

    case :ets.lookup(:lenies, target_id) do
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
        case Lenies.Registry.whereis(target_id) do
          pid when is_pid(pid) -> send(pid, {:take_damage, damage, attacker_id})
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

    case :ets.lookup(:cells, target_cell) do
      [{_, %{lenie_id: nil}}] ->
        min_viable = Application.get_env(:lenies, :min_viable_codeome_opcodes, 10)
        non_nops = Enum.count(Tuple.to_list(slot.opcodes), &(&1 not in [:nop_0, :nop_1]))

        if non_nops < min_viable do
          # slot has too many nops; "stillbirth" — release slot, energy not refunded
          ChildSlots.delete(slot_id)
          update_lenie_record(parent_id, &Map.put(&1, :child_slot_id, nil))
          {{:ok, :stillborn}, state}
        else
          spawn_child(parent_id, parent_record, slot_id, slot, parent_energy, state)
        end

      _ ->
        # target now occupied; release slot, energy not refunded
        ChildSlots.delete(slot_id)
        update_lenie_record(parent_id, &Map.put(&1, :child_slot_id, nil))
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
    child_plasmids = mutate_plasmids(parent_plasmids)

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
        Supervisor.child_spec({Lenies.Lenie, child_opts}, restart: :temporary)
      )

    # Mark child cell occupied
    [{key, cell}] = :ets.lookup(:cells, slot.target_cell)
    :ets.insert(:cells, {key, %{cell | lenie_id: child_id}})

    # Clean up parent's slot
    ChildSlots.delete(slot_id)
    update_lenie_record(parent_id, &Map.put(&1, :child_slot_id, nil))

    {{:ok, {:divided, child_id, child_energy}}, state}
  end

  defp find_random_free_cell({w, h}) do
    max_tries = 100

    case sample_free_cell({w, h}, max_tries) do
      {:ok, pos} ->
        {:ok, pos}

      :exhausted ->
        scan_for_free_cell({w, h})
    end
  end

  defp sample_free_cell(_grid, 0), do: :exhausted

  defp sample_free_cell({w, h} = grid, tries) do
    x = :rand.uniform(w) - 1
    y = :rand.uniform(h) - 1

    case :ets.lookup(:cells, {x, y}) do
      [{_, %{lenie_id: nil}}] -> {:ok, {x, y}}
      _ -> sample_free_cell(grid, tries - 1)
    end
  end

  defp scan_for_free_cell({w, h}) do
    Enum.find_value(0..(w - 1), :no_free_cell, fn x ->
      Enum.find_value(0..(h - 1), nil, fn y ->
        case :ets.lookup(:cells, {x, y}) do
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

  defp parent_already_allocated?(parent_id) do
    case :ets.lookup(:lenies, parent_id) do
      [{^parent_id, record}] -> Map.get(record, :child_slot_id) != nil
      _ -> false
    end
  end

  # No lost-update race with Lenie.maybe_write_snapshot/1:
  # World mutates a Lenie's :lenies record (defending_until, child_slot_id) ONLY
  # while that Lenie is blocked in a synchronous World.action call; the Lenie
  # writes its own snapshot ONLY between batches, never mid-call — so these
  # read-modify-writes are mutually exclusive. Preserve this invariant.
  defp update_lenie_record(id, fun) do
    case :ets.lookup(:lenies, id) do
      [{^id, record}] -> :ets.insert(:lenies, {id, fun.(record)})
      _ -> :ok
    end
  end

  defp consume_eat(cell, eat_amount) do
    # Consume carcass first with 1.5x efficiency.
    # remaining_quota is in raw food units; if carcass_energy already covers it
    # (thanks to the 1.5x bonus), skip the resource phase entirely.
    carcass_taken = min(cell.carcass, eat_amount)
    carcass_energy = trunc(carcass_taken * 1.5)
    remaining_quota = eat_amount - carcass_taken

    # Only draw on biomass when carcass energy falls short of the remaining quota
    {resource_taken, resource_energy} =
      if carcass_energy >= remaining_quota do
        {0, 0}
      else
        taken = min(cell.resource, remaining_quota)
        {taken, taken}
      end

    total_energy = carcass_energy + resource_energy

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
    case dir do
      :n -> {x, Integer.mod(y - 1, h)}
      :e -> {Integer.mod(x + 1, w), y}
      :s -> {x, Integer.mod(y + 1, h)}
      :w -> {Integer.mod(x - 1, w), y}
    end
  end

  defp current_copy_rates do
    %{
      substitution: Application.get_env(:lenies, :copy_substitution_rate, 0.005),
      insert: Application.get_env(:lenies, :copy_insert_rate, 0.0005),
      delete: Application.get_env(:lenies, :copy_delete_rate, 0.0005)
    }
  end

  defp apply_copy_outcome(slot_id, child_addr, opcode, :write) do
    ChildSlots.set_opcode(slot_id, child_addr, opcode)
    :ok
  end

  defp apply_copy_outcome(slot_id, child_addr, _opcode, :substitute) do
    ChildSlots.set_opcode(slot_id, child_addr, Mutator.random_opcode())
    :ok
  end

  defp apply_copy_outcome(slot_id, child_addr, opcode, :insert) do
    # Insert a random opcode AT child_addr, shifting subsequent positions
    {:ok, slot} = ChildSlots.get(slot_id)
    new_opcodes = insert_at(slot.opcodes, child_addr, Mutator.random_opcode(), slot.size)
    :ets.insert(:child_slots, {slot_id, %{slot | opcodes: new_opcodes}})
    # Then write the requested opcode at the next position (the original target shifted by 1)
    ChildSlots.set_opcode(slot_id, child_addr + 1, opcode)
    :ok
  end

  defp apply_copy_outcome(_slot_id, _child_addr, _opcode, :delete) do
    # Skip the write entirely; downstream positions in the slot remain
    # whatever they were (initialized to :nop_0). This effectively shortens
    # the executed program by 1.
    :ok
  end

  # Insert `op` at position `idx` in the tuple, shifting elements rightward.
  # Last element is dropped to keep tuple size constant.
  defp insert_at(opcodes_tuple, idx, op, size) do
    idx = Integer.mod(idx, size)

    list = Tuple.to_list(opcodes_tuple)
    {head, tail} = Enum.split(list, idx)
    # Drop the last element of tail to keep size constant
    new_tail = [op | tail] |> Enum.take(length(tail))
    (head ++ new_tail) |> List.to_tuple()
  end

  defp mutate_plasmids(plasmids) when is_list(plasmids) do
    %{substitution: sub_rate, insert: ins_rate, delete: del_rate} = current_copy_rates()

    Enum.map(plasmids, fn %Lenies.Plasmid{opcodes: ops} = p ->
      %{p | opcodes: Lenies.Mutator.copy_mutate_list(ops, sub_rate, ins_rate, del_rate)}
    end)
  end
end
