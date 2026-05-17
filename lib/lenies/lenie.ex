defmodule Lenies.Lenie do
  @moduledoc """
  A single digital organism. GenServer whose shape and behaviour derive from
  executing its own Codeome via `Lenies.Interpreter`.

  Lifecycle:
  - `start_link/1` receives id, codeome, initial energy, position, direction, lineage
  - In `init/1`: registers in `Lenies.Registry`, sets `max_heap_size`, schedules
    the first metabolic tick
  - Loop: on each `:metabolize` runs a batch of K instructions; if the world is
    needed, calls `World.action/1` and applies the result; increments `age`; dies
    if energy ≤ 0
  - `terminate/2`: notifies the World to free the cell and leave a carcass

  See spec §4.4, §4.5.
  """

  use GenServer

  alias Lenies.{Codeome, Interpreter, World}
  alias Lenies.Interpreter.State

  defstruct [:id, :codeome, :interp, :lineage, batch_count: 0]

  # ----- Public API -----

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Returns a snapshot of the internal state (for inspection/test)."
  def inspect_state(pid), do: GenServer.call(pid, :inspect_state)

  # ----- Server -----

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    codeome = Keyword.fetch!(opts, :codeome)
    energy = Keyword.fetch!(opts, :energy)
    pos = Keyword.fetch!(opts, :pos)
    dir = Keyword.get(opts, :dir, :n)
    lineage = Keyword.get(opts, :lineage, {nil, 0})

    :erlang.process_flag(:max_heap_size, %{
      size: Application.get_env(:lenies, :lenie_max_heap_size, 1_000_000),
      kill: true,
      error_logger: false
    })

    {:ok, _} = Lenies.Registry.register(id)

    interp = State.new(energy: energy, pos: pos, dir: dir)

    state = %__MODULE__{
      id: id,
      codeome: codeome,
      interp: interp,
      lineage: lineage,
      batch_count: 0
    }

    maybe_write_snapshot(state)
    schedule_metabolize()
    {:ok, state}
  end

  @impl true
  def handle_call(:get_codeome, _from, state) do
    {:reply, {:ok, state.codeome}, state}
  end

  @impl true
  def handle_call(:inspect_state, _from, state) do
    snapshot = %{
      id: state.id,
      energy: state.interp.energy,
      age: state.interp.age,
      pos: state.interp.pos,
      dir: state.interp.dir,
      ip: state.interp.ip,
      stack: state.interp.stack,
      slots: state.interp.slots,
      codeome_size: Codeome.size(state.codeome)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info(:metabolize, state) do
    batch = Application.get_env(:lenies, :interpreter_steps_per_batch, 10)

    case Interpreter.run_k_instructions(state.interp, state.codeome, batch) do
      {:cont, new_interp} ->
        new_state = age_and_continue(state, new_interp)
        {:noreply, new_state}

      {:wait_world, action, new_interp} ->
        case apply_world_action(action, state.id, new_interp) do
          {:ok, updated_interp} ->
            new_state = age_and_continue(state, updated_interp)
            {:noreply, new_state}
        end

      {:halt, reason, _new_interp} ->
        {:stop, reason, state}
    end
  end

  def handle_info(:sterilize, state), do: {:stop, :sterilized, state}

  def handle_info(:background_mutate, state) do
    new_codeome = Lenies.Mutator.background_mutation(state.codeome)
    {:noreply, %{state | codeome: new_codeome}}
  end

  def handle_info({:take_damage, amount}, state) do
    new_energy = state.interp.energy - amount
    new_interp = %{state.interp | energy: new_energy}
    new_state = %{state | interp: new_interp}

    if new_energy <= 0 do
      {:stop, :killed, new_state}
    else
      {:noreply, new_state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    hash = Lenies.Codeome.hash(state.codeome)
    World.lenie_died(state.id, state.interp.pos, state.interp.energy, hash)
    :ok
  end

  # ----- internals -----

  defp schedule_metabolize do
    delay = Application.get_env(:lenies, :lenie_metabolize_delay_ms, 0)
    Process.send_after(self(), :metabolize, delay)
  end

  defp age_and_continue(state, new_interp) do
    new_interp = %{new_interp | age: new_interp.age + 1}
    new_batch_count = state.batch_count + 1
    new_state = %{state | interp: new_interp, batch_count: new_batch_count}

    maybe_write_snapshot(new_state)
    schedule_metabolize()
    new_state
  end

  defp maybe_write_snapshot(state) do
    cadence = Application.get_env(:lenies, :snapshot_every_batches, 10)

    if rem(state.batch_count, cadence) == 0 do
      new_snap = %{
        id: state.id,
        pid: self(),
        pos: state.interp.pos,
        dir: state.interp.dir,
        energy: state.interp.energy,
        age: state.interp.age,
        ip: state.interp.ip,
        codeome_hash: Lenies.Codeome.hash(state.codeome),
        lineage: state.lineage
      }

      existing =
        case :ets.lookup(:lenies, state.id) do
          [{_, record}] -> record
          [] -> %{}
        end

      merged = Map.merge(existing, new_snap)
      :ets.insert(:lenies, {state.id, merged})

      Phoenix.PubSub.broadcast(
        Lenies.PubSub,
        "lenie:#{state.id}",
        {:lenie_update, merged}
      )
    end
  end

  defp apply_world_action({:sense_front, _pos, _dir} = action, _id, interp) do
    case World.action(action) do
      {:ok, :empty} -> {:ok, State.push(interp, 0)}
      {:ok, {:resource, n}} -> {:ok, State.push(interp, n)}
      {:ok, {:lenie, _id}} -> {:ok, State.push(interp, -1)}
    end
  end

  defp apply_world_action({:move, _pos, _dir}, id, interp) do
    case World.action({:move, interp.pos, interp.dir, id}) do
      {:ok, {:moved, new_pos}} -> {:ok, %{interp | pos: new_pos}}
      {:ok, :blocked} -> {:ok, interp}
    end
  end

  defp apply_world_action({:eat, _pos} = action, _id, interp) do
    case World.action(action) do
      {:ok, {:ate, amount}} -> {:ok, %{interp | energy: interp.energy + amount}}
    end
  end

  defp apply_world_action({:allocate, size, _pos, _dir}, id, interp) do
    case World.action({:allocate, size, interp.pos, interp.dir, id}) do
      {:ok, {:allocated, _slot_id, _target_cell}} ->
        {:ok, State.push(interp, 1)}

      {:ok, _failure_reason} ->
        # blocked, already_allocated, invalid_size
        {:ok, State.push(interp, 0)}
    end
  end

  defp apply_world_action({:write_child, opcode_int, child_addr}, id, interp) do
    case World.action({:write_child, opcode_int, child_addr, id}) do
      {:ok, :written} -> {:ok, State.push(interp, 1)}
      {:ok, :no_slot} -> {:ok, State.push(interp, 0)}
    end
  end

  defp apply_world_action({:divide, _new_energy, _pos, _dir}, id, interp) do
    case World.action({:divide, interp.energy, interp.pos, interp.dir, id}) do
      {:ok, {:divided, _child_id, energy_given}} ->
        {:ok, %{interp | energy: interp.energy - energy_given}}

      {:ok, _failure} ->
        # Failed: stillborn, target_blocked, no_slot — energy already deducted by opcode cost
        {:ok, interp}
    end
  end

  defp apply_world_action({:attack, _pos, _dir}, id, interp) do
    case World.action({:attack, interp.pos, interp.dir, id}) do
      {:ok, {:attacked, damage}} ->
        {:ok, %{interp | energy: interp.energy + damage}}

      {:ok, {:defended, damage}} ->
        penalty = Application.get_env(:lenies, :defense_attacker_penalty, 5)
        {:ok, %{interp | energy: interp.energy + damage - penalty}}

      {:ok, :no_target} ->
        {:ok, interp}
    end
  end

  defp apply_world_action(:defend, id, interp) do
    case World.action({:defend, id}) do
      {:ok, :defending} -> {:ok, interp}
      {:ok, :no_lenie} -> {:ok, interp}
    end
  end
end
