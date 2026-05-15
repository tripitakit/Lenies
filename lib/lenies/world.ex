defmodule Lenies.World do
  @moduledoc """
  Il "mondo" della sandbox Lenies. GenServer singleton che possiede le tabelle
  ETS, batte il tick ambientale, applica radiazione e decay carcasse, e fornisce
  API pubblica per snapshot e sterilizzazione.

  Vedi `docs/superpowers/specs/2026-05-11-lenies-design.md` §3, §6, §9.
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

  @doc "Statistiche rapide della sandbox per console/test."
  def snapshot_stats, do: GenServer.call(@name, :snapshot_stats)

  @doc "Forza un singolo tick sincrono (per test deterministici)."
  def tick_now, do: GenServer.call(@name, :tick_now)

  @doc "Reset completo: kill di tutti i Lenies, clear ETS, riavvio del tick."
  def sterilize, do: GenServer.call(@name, :sterilize)

  @doc """
  Esegue un'azione richiesta da un Lenie. Chiamata sincrona.

  Forms:
  - `{:sense_front, {x, y}, dir}` — restituisce `{:ok, :empty | {:resource, n} | {:lenie, id}}`
  - `{:move, {x, y}, dir, lenie_id}` — restituisce `{:ok, {:moved, {x2, y2}} | :blocked}`
  - `{:eat, {x, y}}` — restituisce `{:ok, {:ate, amount}}`
  """
  def action(action_spec), do: GenServer.call(@name, {:action, action_spec})

  @doc "Pause the environmental tick (auto-tick stops; tick_now still works)."
  def pause, do: GenServer.call(@name, :pause)

  @doc "Resume the environmental tick."
  def resume, do: GenServer.call(@name, :resume)

  @doc "Query current pause status."
  def paused?, do: GenServer.call(@name, :paused?)

  @doc "Notifica al World che un Lenie è morto (libera cella, eventuale carcassa)."
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

    state = %{
      grid: grid,
      hotspots: hotspots,
      tick_interval_ms: tick_interval,
      tick_ref: nil,
      tick_count: 0,
      paused?: false
    }

    state = prewarm_radiation(state)
    state = maybe_schedule_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot_stats, _from, state) do
    stats = %{
      cells: :ets.info(:cells, :size),
      population: :ets.info(:lenies, :size),
      total_resource: sum_cell_field(:resource),
      total_carcass: sum_cell_field(:carcass),
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
    Tables.clear_all()
    init_cells(state.grid)
    hotspots = Hotspots.initial(state.grid, Config.hotspot_count())
    new_state = %{state | hotspots: hotspots, tick_count: 0, tick_ref: nil}
    new_state = prewarm_radiation(new_state)
    new_state = maybe_schedule_tick(new_state)

    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "world:control",
      {:sterilized, System.system_time(:millisecond)}
    )

    {:reply, :ok, new_state}
  end

  def handle_call(:pause, _from, state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    {:reply, :ok, %{state | paused?: true, tick_ref: nil}}
  end

  def handle_call(:resume, _from, state) do
    new_state = %{state | paused?: false}
    new_state = maybe_schedule_tick(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:paused?, _from, state) do
    {:reply, state.paused?, state}
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

        child_opts = [
          id: lenie_id,
          codeome: codeome,
          energy: energy * 1.0,
          pos: pos,
          dir: dir,
          lineage: lineage
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

  # ----- internals -----

  defp init_cells({w, h}) do
    initial_resource = Application.get_env(:lenies, :initial_resource_per_cell, 30)

    for x <- 0..(w - 1), y <- 0..(h - 1) do
      :ets.insert(:cells, {{x, y}, %Cell{resource: initial_resource}})
    end

    :ok
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
    apply_carcass_decay()
    maybe_background_mutation(state)

    hotspots = Hotspots.drift(state.hotspots, state.grid)

    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "world:tick",
      {:tick, state.tick_count + 1}
    )

    %{state | hotspots: hotspots, tick_count: state.tick_count + 1}
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

  defp apply_carcass_decay do
    rate = Config.carcass_decay()

    if rate > 0 do
      :ets.foldl(
        fn {key, cell}, _acc ->
          if cell.carcass > 0 do
            :ets.insert(:cells, {key, Cell.decay_carcass(cell, rate)})
          end

          nil
        end,
        nil,
        :cells
      )
    end
  end

  defp maybe_background_mutation(state) do
    interval = Application.get_env(:lenies, :background_mutation_interval_ticks, 1000)

    if interval > 0 and rem(state.tick_count + 1, interval) == 0 do
      apply_random_background_mutation()
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

  defp sum_cell_field(field) do
    :ets.foldl(
      fn {_key, cell}, acc -> acc + Map.get(cell, field, 0) end,
      0,
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
    bounds = Application.get_env(:lenies, :codeome_length_bounds, {5, 500})
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

  defp do_action({:attack, {x, y}, dir, _attacker_id}, state) do
    target_cell = front_cell({x, y}, dir, state.grid)

    case :ets.lookup(:cells, target_cell) do
      [{_, %{lenie_id: target_id}}] when is_binary(target_id) ->
        resolve_attack(target_id, state)

      _ ->
        {{:ok, :no_target}, state}
    end
  end

  defp do_action(_unknown, state), do: {{:ok, {:error, :unknown_action}}, state}

  defp resolve_attack(target_id, state) do
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

        # Send async damage message to the target Lenie
        case Lenies.Registry.whereis(target_id) do
          pid when is_pid(pid) -> send(pid, {:take_damage, damage})
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

    child_opts = [
      id: child_id,
      codeome: child_codeome,
      energy: child_energy * 1.0,
      pos: slot.target_cell,
      dir: parent_record.dir,
      lineage: {parent_id, parent_generation + 1}
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
end
