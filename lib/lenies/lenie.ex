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

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  defstruct [
    :id,
    :codeome,
    :interp,
    :lineage,
    :seed_origin,
    # nil for Sandbox/test Lenies; integer for Arena lineages (sub-project #4).
    :seeder_user_id,
    # The handle of the world this Lenie belongs to. Carries the world
    # GenServer pid (for `:action`/`:lenie_died` calls), the ETS tids
    # (for fast-path reads/writes on `:cells`/`:lenies`), and the
    # scoped PubSub prefix (for `:lenie_update` / `:fx` broadcasts and
    # the `:control` subscription).
    :world,
    batch_count: 0,
    # When true, in-flight :metabolize messages are dropped and no
    # follow-up is scheduled. Set to true on `:world_paused` (broadcast
    # by Lenies.World on pause) and back to false on `:world_resumed`,
    # at which point we re-arm the metabolize loop.
    paused?: false,
    plasmids: []
  ]

  # ----- Public API -----

  @doc """
  Start a Lenie under a specific world.

  The first init arg is the `%Lenies.WorldHandle{}` of the world the Lenie
  belongs to. `opts` is the existing keyword list (`:id`, `:codeome`,
  `:energy`, `:pos`, `:dir`, `:lineage`, `:seed_origin`, `:paused?`,
  `:plasmids`).
  """
  def start_link({%Lenies.WorldHandle{} = handle, opts}) when is_list(opts) do
    GenServer.start_link(__MODULE__, {handle, opts})
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
  def init({%Lenies.WorldHandle{} = handle, opts}) do
    # Lenies are simulation workers — deprioritize so Phoenix/PubSub/LiveView
    # (running at :normal) stay responsive under load.
    Process.flag(:priority, :low)

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
    # Arena lineage tag (sub-project #4). `nil` for Sandbox/test Lenies; the
    # Arena uses this via :ets.select on handle.tables.lenies to enforce
    # "one alive lineage per user".
    seeder_user_id = Keyword.get(opts, :seeder_user_id, nil)

    :erlang.process_flag(:max_heap_size, %{
      size: Application.get_env(:lenies, :lenie_max_heap_size, 1_000_000),
      kill: true,
      error_logger: false
    })

    # Per-world Registry key — `{:lenie, world_id, id}` — so the same
    # Lenie id can coexist in different worlds without colliding. Replaces
    # the legacy bare-id registration (multi-world refactor T6).
    {:ok, _} = Registry.register(Lenies.Registry, {:lenie, handle.id, id}, nil)

    interp = State.new(energy: energy, pos: pos, dir: dir)

    # Pause state must come via spawn opts — calling `World.paused?()`
    # here would deadlock (we're typically inside World's
    # handle_call({:spawn_lenie, ...}) callback). World.spawn_lenie /
    # spawn_child pass the current flag down; direct `Lenie.start_link`
    # callers (tests) default to false.
    paused? = Keyword.get(opts, :paused?, false)
    plasmids = Keyword.get(opts, :plasmids, [])
    interp = %{interp | plasmids: plasmids}

    # Subscribe to the world's scoped control topic so pause/resume
    # broadcasts from THAT world (and only that world) gate the
    # metabolize loop.
    if Process.whereis(Lenies.PubSub) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{handle.pubsub_prefix}:control")
    end

    state = %__MODULE__{
      id: id,
      codeome: codeome,
      interp: interp,
      lineage: lineage,
      seed_origin: seed_origin,
      seeder_user_id: seeder_user_id,
      world: handle,
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
        case apply_world_action(action, state, new_interp) do
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

    # new_energy uses the full unclamped amount (not `actual`) intentionally:
    # this drives energy below zero when the hit exceeds what the victim has,
    # triggering the lethality check below. The reward uses `actual` (clamped)
    # so the attacker only gains what the victim truly possessed.
    new_energy = state.interp.energy - amount
    new_interp = %{state.interp | energy: new_energy}
    new_state = %{state | interp: new_interp}

    # Reward the attacker with exactly what this victim lost.
    # Do this BEFORE returning {:stop, ...} so a dying victim still pays out.
    case Registry.lookup(Lenies.Registry, {:lenie, state.world.id, attacker_id}) do
      [{pid, _}] -> send(pid, {:attack_reward, actual})
      [] -> :ok
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
    # Cast to the world pid directly. World handles `{:lenie_died, id, pos,
    # energy, hash, seeder_user_id}` (see lib/lenies/world.ex handle_cast).
    # The trailing `seeder_user_id` (nil for non-Arena Lenies) lets the World
    # broadcast `:arena_lineage_changed` on the user's per-user topic so
    # ArenaLive's Seed/Apoptosis UI refreshes on natural death.
    GenServer.cast(
      state.world.pid,
      {:lenie_died, state.id, state.interp.pos, state.interp.energy, hash, state.seeder_user_id}
    )

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

  # No lost-update race with World.update_lenie_record/2:
  # This snapshot write happens ONLY between batches (in age_and_continue/2 or
  # init/1), never while a World.action call is in flight. World only mutates
  # this Lenie's :lenies record while the Lenie is blocked inside World.action —
  # so the two read-modify-writes are mutually exclusive. Preserve this invariant.
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
        # Persist the full opcode list, not just its hash. Required by
        # snapshot restore (`Lenies.World.handle_call({:restore_snapshot, …})`)
        # to respawn ghost Lenies after `:lenies` ETS is reloaded from disk
        # — without the opcodes, the World can only fall back to the
        # node-wide `:species_codeomes` cache, which is empty after a node
        # restart.
        codeome: state.codeome,
        codeome_hash: Lenies.Codeome.hash(state.codeome),
        lineage: state.lineage,
        seed_origin: state.seed_origin,
        seeder_user_id: state.seeder_user_id,
        plasmids: state.plasmids
      }

      existing =
        case :ets.lookup(state.world.tables.lenies, state.id) do
          [{_, record}] -> record
          [] -> %{}
        end

      merged = Map.merge(existing, new_snap)
      :ets.insert(state.world.tables.lenies, {state.id, merged})

      Phoenix.PubSub.broadcast(
        Lenies.PubSub,
        "#{state.world.pubsub_prefix}:lenie:#{state.id}",
        {:lenie_update, merged}
      )
    end
  end

  defp apply_world_action({:sense_front, _pos, _dir} = action, state, interp) do
    case world_call(state, action) do
      {:ok, :empty} -> {:ok, State.push(interp, 0)}
      {:ok, {:resource, n}} -> {:ok, State.push(interp, n)}
      {:ok, {:lenie, _id}} -> {:ok, State.push(interp, -1)}
    end
  end

  defp apply_world_action({:move, _pos, _dir}, state, interp) do
    case world_call(state, {:move, interp.pos, interp.dir, state.id}) do
      {:ok, {:moved, new_pos}} -> {:ok, %{interp | pos: new_pos}}
      {:ok, :blocked} -> {:ok, interp}
    end
  end

  defp apply_world_action({:eat, _pos} = action, state, interp) do
    case world_call(state, action) do
      {:ok, {:ate, amount}} -> {:ok, %{interp | energy: interp.energy + amount}}
    end
  end

  defp apply_world_action({:allocate, size, _pos, _dir}, state, interp) do
    case world_call(state, {:allocate, size, interp.pos, interp.dir, state.id}) do
      {:ok, {:allocated, _slot_id, _target_cell}} ->
        {:ok, State.push(interp, 1)}

      {:ok, _failure_reason} ->
        # blocked, already_allocated, invalid_size
        {:ok, State.push(interp, 0)}
    end
  end

  defp apply_world_action({:write_child, opcode_int, child_addr}, state, interp) do
    case world_call(state, {:write_child, opcode_int, child_addr, state.id}) do
      {:ok, :written} -> {:ok, State.push(interp, 1)}
      {:ok, :no_slot} -> {:ok, State.push(interp, 0)}
    end
  end

  defp apply_world_action({:divide, _new_energy, _pos, _dir}, state, interp) do
    case world_call(state, {:divide, interp.energy, interp.pos, interp.dir, state.id}) do
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

  defp apply_world_action({:attack, _pos, _dir}, state, interp) do
    case world_call(state, {:attack, interp.pos, interp.dir, state.id}) do
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

  defp apply_world_action(:defend, state, interp) do
    case world_call(state, {:defend, state.id}) do
      {:ok, :defending} -> {:ok, interp}
      {:ok, :no_lenie} -> {:ok, interp}
    end
  end

  defp apply_world_action({:conjugate, pos, dir, plasmid_opcodes}, state, interp) do
    cond do
      plasmid_opcodes == [] ->
        conjugate_failure(interp)

      true ->
        target_pos = front_cell(pos, dir)

        case :ets.lookup(state.world.tables.cells, target_pos) do
          [{_, %{lenie_id: nil}}] ->
            conjugate_failure(interp)

          [{_, %{lenie_id: recipient_id}}] when is_binary(recipient_id) ->
            case Registry.lookup(Lenies.Registry, {:lenie, state.world.id, recipient_id}) do
              [{recipient_pid, _}] ->
                attempt_transfer(
                  interp,
                  state.id,
                  recipient_pid,
                  recipient_id,
                  plasmid_opcodes,
                  state
                )

              [] ->
                conjugate_failure(interp)
            end

          _ ->
            conjugate_failure(interp)
        end
    end
  end

  # Direct GenServer call to the per-world pid (multi-world refactor T6).
  # Replaces the long-gone module-level `Lenies.World.action/1` singleton
  # delegator (removed in Task 11).
  defp world_call(state, action_spec) do
    GenServer.call(state.world.pid, {:action, action_spec})
  end

  defp front_cell({x, y}, dir) do
    Lenies.World.Geometry.step({x, y}, dir, Lenies.Config.grid_size())
  end

  # Read the seed_origin of a Lenie from the :lenies ETS snapshot. Lenies
  # spawned directly via start_link (tests) without a seed_origin opt
  # snapshot as nil; fall back to "?" for the dashboard display.
  defp lookup_seed_origin(state, lenie_id) do
    case :ets.lookup(state.world.tables.lenies, lenie_id) do
      [{_, snap}] -> Map.get(snap, :seed_origin) || "?"
      [] -> "?"
    end
  end

  # Base cost is now charged in the interpreter dispatch; the failure path
  # only pushes 0 (no additional energy deduction).
  defp conjugate_failure(interp) do
    {:ok, Lenies.Interpreter.State.push(interp, 0)}
  end

  # Symmetric-donor case: A facing east at {x,y}, B facing west at
  # {x+1,y} both call receive_plasmid on each other in the same iter.
  # We use a 50ms timeout + catch :exit so the donor survives the
  # deadlock (recipient is busy → conjugate fails, donor stays alive
  # and pays only the base cost). 50ms is generous for any non-deadlock
  # GenServer.call (microseconds in-process); 5_000ms (default) used to
  # kill both Lenies in dense MR-Twitch populations where :conjugate
  # fires every forage iter.
  defp attempt_transfer(interp, donor_id, recipient_pid, recipient_id, plasmid_opcodes, state) do
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
          "#{state.world.pubsub_prefix}:fx",
          {:conjugation,
           %{
             donor_id: donor_id,
             donor_seed: lookup_seed_origin(state, donor_id),
             recipient_id: recipient_id,
             recipient_seed: lookup_seed_origin(state, recipient_id),
             plasmid_hash: plasmid_hash,
             sender_pos: interp.pos,
             receiver_pos: front_cell(interp.pos, interp.dir)
           }}
        )

        # Base cost was already charged in dispatch; apply only the size
        # surcharge here.  Net = base + surcharge = Costs.cost(:conjugate, plasmid_size).
        surcharge =
          Lenies.Codeome.Costs.cost(:conjugate, plasmid_size) -
            Lenies.Codeome.Costs.cost(:conjugate, 0)

        new_interp =
          interp
          |> Lenies.Interpreter.State.push(1)
          |> Lenies.Interpreter.State.apply_cost(surcharge)

        {:ok, new_interp}

      :already_present ->
        # Recipient already carries this plasmid — nothing transferred, no
        # broadcast. Donor pays only the base cost and reads failure (push
        # 0), so a tight forage loop stops re-conjugating the same neighbour
        # every tick (one transfer per plasmid per encounter).
        # (base cost was charged in dispatch)
        conjugate_failure(interp)

      {:error, :too_large} ->
        conjugate_failure(interp)

      :timeout ->
        conjugate_failure(interp)
    end
  end
end
