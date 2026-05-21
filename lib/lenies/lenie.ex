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

  defstruct [
    :id,
    :codeome,
    :interp,
    :lineage,
    :seed_origin,
    batch_count: 0,
    # When true, in-flight :metabolize messages are dropped and no
    # follow-up is scheduled. Set to true on `:world_paused` (broadcast
    # by Lenies.World on pause) and back to false on `:world_resumed`,
    # at which point we re-arm the metabolize loop.
    paused?: false,
    plasmids: []
  ]

  # ----- Public API -----

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Returns a snapshot of the internal state (for inspection/test)."
  def inspect_state(pid), do: GenServer.call(pid, :inspect_state)

  @doc """
  Synchronous call invoked by another Lenie's `:conjugate` opcode. Appends
  the plasmid opcodes to this Lenie's codeome and adds the plasmid to its
  (multi-plasmid) buffer. Returns `:ok` on a real transfer,
  `:already_present` if the Lenie already carries that exact plasmid (a
  no-op — limits a transfer to once per plasmid per encounter), or
  `{:error, :too_large}` if appending would exceed `codeome_length_bounds`.
  """
  @spec receive_plasmid(pid(), [atom()], timeout()) ::
          :ok | :already_present | {:error, :too_large}
  def receive_plasmid(pid, plasmid_opcodes, timeout \\ 5_000)
      when is_pid(pid) and is_list(plasmid_opcodes) do
    GenServer.call(pid, {:receive_plasmid, plasmid_opcodes}, timeout)
  end

  # ----- Server -----

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    codeome = Keyword.fetch!(opts, :codeome)
    energy = Keyword.fetch!(opts, :energy)
    pos = Keyword.fetch!(opts, :pos)
    dir = Keyword.get(opts, :dir, :n)
    lineage = Keyword.get(opts, :lineage, {nil, 0})
    # Seed of origin — propagates through replication and mutation so the
    # species table can show "evolved from <seed>" for descendants of a
    # known seed. `nil` for Lenies whose origin isn't tracked (e.g. tests
    # spawning directly via `Lenie.start_link`).
    seed_origin = Keyword.get(opts, :seed_origin)

    :erlang.process_flag(:max_heap_size, %{
      size: Application.get_env(:lenies, :lenie_max_heap_size, 1_000_000),
      kill: true,
      error_logger: false
    })

    {:ok, _} = Lenies.Registry.register(id)

    interp = State.new(energy: energy, pos: pos, dir: dir)

    # Pause state must come via spawn opts — calling `World.paused?()`
    # here would deadlock (we're typically inside World's
    # handle_call({:spawn_lenie, ...}) callback). World.spawn_lenie /
    # spawn_child pass the current flag down; direct `Lenie.start_link`
    # callers (tests) default to false.
    paused? = Keyword.get(opts, :paused?, false)
    plasmids = Keyword.get(opts, :plasmids, [])
    interp = %{interp | plasmids: plasmids}

    # Subscribe to world:control so future pause/resume broadcasts
    # gate the metabolize loop.
    if Process.whereis(Lenies.PubSub) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:control")
    end

    state = %__MODULE__{
      id: id,
      codeome: codeome,
      interp: interp,
      lineage: lineage,
      seed_origin: seed_origin,
      batch_count: 0,
      paused?: paused?,
      plasmids: plasmids
    }

    maybe_write_snapshot(state)
    cache_codeome_by_hash(state.codeome)
    unless paused?, do: schedule_metabolize()
    {:ok, state}
  end

  # First Lenie of a species writes its codeome into the per-hash cache
  # so the species table can show size / cost / max-gain without a
  # `GenServer.call` round-trip for every species on every dashboard
  # render. Subsequent Lenies of the same hash skip the insert (hash →
  # codeome is invariant by definition).
  defp cache_codeome_by_hash(codeome) do
    if :ets.info(:species_codeomes) != :undefined do
      hash = Codeome.hash(codeome)

      case :ets.lookup(:species_codeomes, hash) do
        [] -> :ets.insert(:species_codeomes, {hash, Codeome.to_list(codeome)})
        _ -> :ok
      end
    end

    :ok
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
  def handle_call({:receive_plasmid, plasmid_opcodes}, _from, state) do
    already_carries =
      Enum.any?(state.plasmids, fn %Lenies.Plasmid{opcodes: ops} -> ops == plasmid_opcodes end)

    current_size = Lenies.Codeome.size(state.codeome)
    new_size = current_size + length(plasmid_opcodes)
    {_min, max} = Application.get_env(:lenies, :codeome_length_bounds, {3, 1000})

    cond do
      already_carries ->
        # Already carries this exact plasmid — report the no-op so the donor
        # stops re-broadcasting the same transfer each tick, and avoid
        # codeome bloat from re-appending it.
        {:reply, :already_present, state}

      new_size > max ->
        {:reply, {:error, :too_large}, state}

      true ->
        new_codeome =
          state.codeome
          |> Lenies.Codeome.to_list()
          |> Kernel.++(plasmid_opcodes)
          |> Lenies.Codeome.from_list()

        new_plasmid = Lenies.Plasmid.new(plasmid_opcodes)
        # Accumulate: a Lenie can carry several distinct plasmids. The
        # codeome already runs all of them (they're appended above); this
        # list also drives the dashboard species annotation and the random
        # outgoing pick in `:conjugate`.
        new_plasmids = state.plasmids ++ [new_plasmid]
        new_interp = %{state.interp | plasmids: new_plasmids}
        new_state = %{state | codeome: new_codeome, plasmids: new_plasmids, interp: new_interp}

        cache_codeome_by_hash(new_codeome)

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info(:metabolize, %{paused?: true} = state) do
    # Discard the timer that fired in flight when the world paused —
    # the next :world_resumed will re-schedule us.
    {:noreply, state}
  end

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

  def handle_info(:world_paused, state) do
    {:noreply, %{state | paused?: true}}
  end

  def handle_info(:world_resumed, %{paused?: true} = state) do
    schedule_metabolize()
    {:noreply, %{state | paused?: false}}
  end

  # Already running — broadcast may arrive at a Lenie that was never
  # paused (e.g. spawned post-resume); leave the metabolize loop alone.
  def handle_info(:world_resumed, state), do: {:noreply, state}

  def handle_info(:sterilize, state), do: {:stop, :sterilized, state}

  def handle_info(:background_mutate, state) do
    new_codeome = Lenies.Mutator.background_mutation(state.codeome)
    cache_codeome_by_hash(new_codeome)

    new_plasmids =
      Enum.map(state.plasmids, fn %Lenies.Plasmid{opcodes: ops} = p ->
        %{p | opcodes: Lenies.Mutator.background_mutation_list(ops)}
      end)

    new_interp = %{state.interp | plasmids: new_plasmids}

    {:noreply, %{state | codeome: new_codeome, plasmids: new_plasmids, interp: new_interp}}
  end

  def handle_info({:take_damage, amount, attacker_id}, state) do
    # Compute what energy the victim can actually lose — clamped so we
    # never reward the attacker more than the victim actually had.
    actual = min(amount, max(state.interp.energy, 0))

    new_energy = state.interp.energy - amount
    new_interp = %{state.interp | energy: new_energy}
    new_state = %{state | interp: new_interp}

    # Reward the attacker with exactly what this victim lost.
    # Do this BEFORE returning {:stop, ...} so a dying victim still pays out.
    case Lenies.Registry.whereis(attacker_id) do
      pid when is_pid(pid) -> send(pid, {:attack_reward, actual})
      _ -> :ok
    end

    if new_energy <= 0 do
      {:stop, :killed, new_state}
    else
      {:noreply, new_state}
    end
  end

  def handle_info({:attack_reward, amount}, state) do
    new_interp = %{state.interp | energy: state.interp.energy + amount}
    {:noreply, %{state | interp: new_interp}}
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

    new_state = %{
      state
      | interp: new_interp,
        batch_count: new_batch_count,
        plasmids: new_interp.plasmids
    }

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
        lineage: state.lineage,
        seed_origin: state.seed_origin,
        plasmids: state.plasmids
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
        plasmid_size =
          case interp.plasmids do
            [%Lenies.Plasmid{opcodes: ops} | _] -> length(ops)
            _ -> 0
          end

        tax = 0.5 * plasmid_size
        {:ok, %{interp | energy: interp.energy - energy_given - tax}}

      {:ok, _failure} ->
        # Failed: stillborn, target_blocked, no_slot — energy already deducted by opcode cost
        {:ok, interp}
    end
  end

  defp apply_world_action({:attack, _pos, _dir}, id, interp) do
    case World.action({:attack, interp.pos, interp.dir, id}) do
      {:ok, {:attacked, _damage}} ->
        # Reward arrives asynchronously via {:attack_reward, amount}.
        # Do NOT credit damage here — that was the energy-from-nothing bug.
        {:ok, interp}

      {:ok, {:defended, _damage}} ->
        # Apply the attacker penalty synchronously (metabolic cost of a
        # failed strike against a defender); the actual reward for the
        # damage dealt arrives asynchronously via {:attack_reward, amount}.
        penalty = Application.get_env(:lenies, :defense_attacker_penalty, 5)
        {:ok, %{interp | energy: interp.energy - penalty}}

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

  defp apply_world_action({:conjugate, pos, dir, plasmid_opcodes}, donor_id, interp) do
    cond do
      plasmid_opcodes == [] ->
        conjugate_failure(interp, 0)

      true ->
        target_pos = front_cell(pos, dir)

        case :ets.lookup(:cells, target_pos) do
          [{_, %{lenie_id: nil}}] ->
            conjugate_failure(interp, 0)

          [{_, %{lenie_id: recipient_id}}] when is_binary(recipient_id) ->
            case Lenies.Registry.whereis(recipient_id) do
              recipient_pid when is_pid(recipient_pid) ->
                attempt_transfer(interp, donor_id, recipient_pid, recipient_id, plasmid_opcodes)

              nil ->
                conjugate_failure(interp, 0)
            end

          _ ->
            conjugate_failure(interp, 0)
        end
    end
  end

  defp front_cell({x, y}, dir) do
    {w, h} = Lenies.Config.grid_size()

    case dir do
      :n -> {x, Integer.mod(y - 1, h)}
      :s -> {x, Integer.mod(y + 1, h)}
      :e -> {Integer.mod(x + 1, w), y}
      :w -> {Integer.mod(x - 1, w), y}
    end
  end

  # Read the seed_origin of a Lenie from the :lenies ETS snapshot. Lenies
  # spawned directly via start_link (tests) without a seed_origin opt
  # snapshot as nil; fall back to "?" for the dashboard display.
  defp lookup_seed_origin(lenie_id) do
    case :ets.lookup(:lenies, lenie_id) do
      [{_, snap}] -> Map.get(snap, :seed_origin) || "?"
      [] -> "?"
    end
  end

  defp conjugate_failure(interp, plasmid_size) do
    new_interp =
      interp
      |> Lenies.Interpreter.State.push(0)
      |> Lenies.Interpreter.State.apply_cost(Lenies.Codeome.Costs.cost(:conjugate, plasmid_size))

    {:ok, new_interp}
  end

  # Symmetric-donor case: A facing east at {x,y}, B facing west at
  # {x+1,y} both call receive_plasmid on each other in the same iter.
  # We use a 50ms timeout + catch :exit so the donor survives the
  # deadlock (recipient is busy → conjugate fails, donor stays alive
  # and pays only the base cost). 50ms is generous for any non-deadlock
  # GenServer.call (microseconds in-process); 5_000ms (default) used to
  # kill both Lenies in dense MR-Twitch populations where :conjugate
  # fires every forage iter.
  defp attempt_transfer(interp, donor_id, recipient_pid, recipient_id, plasmid_opcodes) do
    plasmid_size = length(plasmid_opcodes)

    result =
      try do
        Lenies.Lenie.receive_plasmid(recipient_pid, plasmid_opcodes, 50)
      catch
        # Recipient is busy (most often a symmetric-donor deadlock with us
        # both calling receive_plasmid on each other simultaneously). 50ms
        # is generous for any non-deadlock call (microseconds in-process).
        # Treat as a normal failure: donor stays alive, no broadcast, no
        # state change in either Lenie, donor pays only the base cost.
        :exit, _reason -> :timeout
      end

    case result do
      :ok ->
        plasmid_hash =
          :erlang.phash2(plasmid_opcodes, 16_777_216)
          |> Integer.to_string(16)
          |> String.pad_leading(6, "0")

        Phoenix.PubSub.broadcast(
          Lenies.PubSub,
          "world:fx",
          {:conjugation,
           %{
             donor_id: donor_id,
             donor_seed: lookup_seed_origin(donor_id),
             recipient_id: recipient_id,
             recipient_seed: lookup_seed_origin(recipient_id),
             plasmid_hash: plasmid_hash,
             sender_pos: interp.pos,
             receiver_pos: front_cell(interp.pos, interp.dir)
           }}
        )

        new_interp =
          interp
          |> Lenies.Interpreter.State.push(1)
          |> Lenies.Interpreter.State.apply_cost(
            Lenies.Codeome.Costs.cost(:conjugate, plasmid_size)
          )

        {:ok, new_interp}

      :already_present ->
        # Recipient already carries this plasmid — nothing transferred, no
        # broadcast. Donor pays only the base cost and reads failure (push
        # 0), so a tight forage loop stops re-conjugating the same neighbour
        # every tick (one transfer per plasmid per encounter).
        conjugate_failure(interp, 0)

      {:error, :too_large} ->
        conjugate_failure(interp, 0)

      :timeout ->
        conjugate_failure(interp, 0)
    end
  end
end
