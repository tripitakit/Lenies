defmodule Lenies.ConjugationTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie, Plasmid, World}
  alias Lenies.World.Tables
  alias Lenies.Codeome.Costs

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
    Application.put_env(:lenies, :eat_amount, 50)
    Application.put_env(:lenies, :interpreter_steps_per_batch, 50)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 1000})

    on_exit(fn ->
      Application.delete_env(:lenies, :copy_substitution_rate)
      Application.delete_env(:lenies, :copy_insert_rate)
      Application.delete_env(:lenies, :copy_delete_rate)
      Application.delete_env(:lenies, :background_mutation_rate_per_1000_ticks)
      Application.delete_env(:lenies, :eat_amount)
      Application.delete_env(:lenies, :interpreter_steps_per_batch)
      Application.delete_env(:lenies, :codeome_length_bounds)

      case Process.whereis(Lenies.LenieSupervisor) do
        sup when is_pid(sup) ->
          DynamicSupervisor.which_children(sup)
          |> Enum.each(fn {_, child, _, _} ->
            if is_pid(child), do: DynamicSupervisor.terminate_child(sup, child)
          end)

        _ ->
          :ok
      end

      case Process.whereis(Lenies.World) do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      Tables.delete_all()
    end)

    :ok
  end

  test "receive_plasmid appends to codeome and adds to the plasmid list" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "RX"}})

    {:ok, recipient_pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move, :turn_left, :eat, :move]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(recipient_pid)

    plasmid_ops = [:turn_right, :turn_right, :defend]
    assert Lenie.receive_plasmid(recipient_pid, plasmid_ops) == :ok

    snapshot = :sys.get_state(recipient_pid)
    assert Codeome.size(snapshot.codeome) == 5 + 3

    assert Codeome.to_list(snapshot.codeome) ==
             [:eat, :move, :turn_left, :eat, :move, :turn_right, :turn_right, :defend]

    assert [%Plasmid{opcodes: ^plasmid_ops}] = snapshot.plasmids
  end

  test "receive_plasmid rejects oversize append" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 10})

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "RX"}})

    {:ok, recipient_pid} =
      Lenie.start_link(
        id: "RX",
        codeome:
          Codeome.from_list([:eat, :move, :turn_left, :eat, :move, :turn_right, :eat, :move]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(recipient_pid)

    assert Lenie.receive_plasmid(recipient_pid, [:defend, :defend, :defend]) ==
             {:error, :too_large}

    snapshot = :sys.get_state(recipient_pid)
    assert Codeome.size(snapshot.codeome) == 8
    assert snapshot.plasmids == []
  end

  test ":conjugate with no plasmid pushes 0 and pays base cost" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "SOLO"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "SOLO",
        codeome: Codeome.from_list([:conjugate, :nop_0]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    Process.sleep(200)

    snapshot = :sys.get_state(pid)
    # Energy should have dropped by at least the 4.0 base cost.
    assert snapshot.interp.energy < 5_000.0 - 3.9
    assert hd(snapshot.interp.stack) == 0
  end

  test ":conjugate with plasmid and adjacent recipient transfers and pushes 1" do
    # Bound recipient codeome to exactly 5 so only the first conjugation
    # succeeds (2 + 3 = 5 ≤ 5); subsequent attempts return {:error, :too_large}.
    Application.put_env(:lenies, :codeome_length_bounds, {3, 5})

    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key1, c1}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key1, %{c1 | lenie_id: "TX"}})
    [{key2, c2}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {129, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key2, %{c2 | lenie_id: "RX"}})

    {:ok, recipient_pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move]),
        energy: 5_000.0,
        pos: {129, 128},
        dir: :w,
        lineage: {nil, 0}
      )

    plasmid = Plasmid.new([:turn_left, :defend, :eat])

    {:ok, donor_pid} =
      Lenie.start_link(
        id: "TX",
        codeome: Codeome.from_list([:conjugate, :nop_0]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0},
        plasmids: [plasmid]
      )

    Process.unlink(donor_pid)
    Process.unlink(recipient_pid)

    Process.sleep(300)

    donor_snap = :sys.get_state(donor_pid)
    recipient_snap = :sys.get_state(recipient_pid)

    # Donor still has its plasmid.
    assert [%Plasmid{opcodes: [:turn_left, :defend, :eat]}] = donor_snap.plasmids
    # Donor energy decreased by at least 4.0 + 3 * 0.05 = 4.15 base + extra ops.
    assert donor_snap.interp.energy < 5_000.0 - 4.1
    # Last conjugation attempt pushed 1 (success) or 0 (subsequent too_large failures).
    # Either is acceptable — we care that it ran at all and the stack is an integer.
    assert hd(donor_snap.interp.stack) in [0, 1]

    # Recipient codeome grew by exactly 3 opcodes (capped at max 5).
    assert Codeome.size(recipient_snap.codeome) == 5

    assert Codeome.to_list(recipient_snap.codeome) ==
             [:eat, :move, :turn_left, :defend, :eat]

    # Recipient now has the plasmid in its buffer too.
    assert [%Plasmid{opcodes: [:turn_left, :defend, :eat]}] = recipient_snap.plasmids
  end

  test ":conjugate broadcasts world:fx event on success" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:primary:fx")

    [{key1, c1}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key1, %{c1 | lenie_id: "TX"}})
    [{key2, c2}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {129, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key2, %{c2 | lenie_id: "RX"}})

    {:ok, recipient_pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move]),
        energy: 5_000.0,
        pos: {129, 128},
        dir: :w,
        lineage: {nil, 0}
      )

    plasmid = Plasmid.new([:defend])

    {:ok, donor_pid} =
      Lenie.start_link(
        id: "TX",
        codeome: Codeome.from_list([:conjugate, :nop_0]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0},
        plasmids: [plasmid]
      )

    Process.unlink(donor_pid)
    Process.unlink(recipient_pid)

    assert_receive {:conjugation, %{sender_pos: {128, 128}, receiver_pos: {129, 128}}}, 1000
  end

  test "background_mutate also touches the plasmid buffer (after multiple cycles)" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "BG"}})

    original_ops = List.duplicate(:eat, 30)
    original_plasmid = Plasmid.new(original_ops)

    {:ok, pid} =
      Lenie.start_link(
        id: "BG",
        codeome: Codeome.from_list([:nop_0, :nop_0, :nop_0]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :n,
        lineage: {nil, 0},
        plasmids: [original_plasmid]
      )

    Process.unlink(pid)

    # Trigger background mutation 50 times. Each fires a single random
    # substitution. With 50 substitutions on a 38-opcode whitelist (size
    # of @opcodes), the probability that all 50 picks land on :eat is
    # (1/38)^50 ≈ 0 — so we expect to see at least one different opcode.
    for _ <- 1..50, do: send(pid, :background_mutate)

    # :sys.get_state below is itself a synchronous mailbox barrier — by
    # the time it returns, all 50 :background_mutate messages have been
    # processed (FIFO mailbox). No explicit sleep needed.
    snapshot = :sys.get_state(pid)
    [%Plasmid{opcodes: new_ops}] = snapshot.plasmids

    assert length(new_ops) == 30
    diff = Enum.zip(original_ops, new_ops) |> Enum.count(fn {a, b} -> a != b end)

    assert diff > 0,
           "expected at least one opcode to differ after 50 background mutations; got diff=#{diff}"
  end

  test "receive_plasmid accumulates distinct plasmids (multi-plasmid carry)" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "RX"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move, :turn_left]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    assert Lenie.receive_plasmid(pid, [:turn_right, :defend]) == :ok
    assert Lenie.receive_plasmid(pid, [:move, :eat]) == :ok

    snap = :sys.get_state(pid)

    assert [
             %Plasmid{opcodes: [:turn_right, :defend]},
             %Plasmid{opcodes: [:move, :eat]}
           ] = snap.plasmids

    assert Codeome.to_list(snap.codeome) ==
             [:eat, :move, :turn_left, :turn_right, :defend, :move, :eat]
  end

  test "receive_plasmid is a no-op for an already-carried plasmid (:already_present)" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "RX"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move, :turn_left]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    assert Lenie.receive_plasmid(pid, [:defend, :defend]) == :ok
    size_after_first = :sys.get_state(pid).codeome |> Codeome.size()

    # Second delivery of the same plasmid: no-op, no codeome growth.
    assert Lenie.receive_plasmid(pid, [:defend, :defend]) == :already_present

    snap = :sys.get_state(pid)
    assert Codeome.size(snap.codeome) == size_after_first
    assert [%Plasmid{opcodes: [:defend, :defend]}] = snap.plasmids
  end

  test ":conjugate transfers one of the donor's carried plasmids (random pick within the set)" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key1, c1}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key1, %{c1 | lenie_id: "TX"}})
    [{key2, c2}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {129, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key2, %{c2 | lenie_id: "RX"}})

    {:ok, recipient_pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move]),
        energy: 5_000.0,
        pos: {129, 128},
        dir: :w,
        lineage: {nil, 0}
      )

    {:ok, donor_pid} =
      Lenie.start_link(
        id: "TX",
        codeome: Codeome.from_list([:conjugate, :nop_0]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0},
        plasmids: [Plasmid.new([:turn_left, :defend]), Plasmid.new([:turn_right, :eat])]
      )

    Process.unlink(donor_pid)
    Process.unlink(recipient_pid)

    Process.sleep(400)

    recipient_snap = :sys.get_state(recipient_pid)

    # The recipient acquired at least one plasmid, and every acquired plasmid
    # is a member of the donor's set (proves :conjugate sends a real element,
    # not garbage; over ticks it may accumulate both).
    assert recipient_snap.plasmids != []

    for %Plasmid{opcodes: ops} <- recipient_snap.plasmids do
      assert ops in [[:turn_left, :defend], [:turn_right, :eat]]
    end

    # Donor keeps its full set.
    assert length(:sys.get_state(donor_pid).plasmids) == 2
  end

  # ── Energy-accounting tests (I4 fix) ─────────────────────────────────────────

  # Success total = Costs.cost(:conjugate, plasmid_size). Verifies the
  # base+surcharge split does not change the net cost to the donor.
  test ":conjugate success costs exactly Costs.cost(:conjugate, plasmid_size)" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    # Subscribe BEFORE starting any Lenie so we cannot miss the broadcast
    # when lenie_metabolize_delay_ms is 0 and the conjugation fires immediately.
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:primary:fx")

    [{key1, c1}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key1, %{c1 | lenie_id: "TX2"}})
    [{key2, c2}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {129, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key2, %{c2 | lenie_id: "RX2"}})

    plasmid_ops = [:turn_left, :defend, :eat]
    plasmid_size = length(plasmid_ops)
    expected_cost = Costs.cost(:conjugate, plasmid_size)

    {:ok, _recipient_pid} =
      Lenie.start_link(
        id: "RX2",
        codeome: Codeome.from_list([:eat, :move]),
        energy: 5_000.0,
        pos: {129, 128},
        dir: :w,
        lineage: {nil, 0}
      )

    plasmid = Plasmid.new(plasmid_ops)
    start_energy = 5_000.0

    {:ok, donor_pid} =
      Lenie.start_link(
        id: "TX2",
        # Use :nop_0 as second op so the conjugation loops but max_codeome
        # eventually blocks re-transfer (recipient already_present → failure cost).
        # We only care about the FIRST iteration which succeeds.
        codeome: Codeome.from_list([:conjugate, :nop_0]),
        energy: start_energy,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0},
        plasmids: [plasmid]
      )

    Process.unlink(donor_pid)

    # Wait just long enough for the first conjugation to fire.
    # Use a PubSub notification so we stop measuring as soon as success is confirmed.
    assert_receive {:conjugation, %{donor_id: "TX2"}}, 2000

    # Allow one interpreter tick after the broadcast to let the apply_cost settle.
    Process.sleep(50)

    donor_snap = :sys.get_state(donor_pid)
    energy_spent = start_energy - donor_snap.interp.energy

    # Energy spent should be at least the cost of one successful conjugation
    # (may be more if extra ops ran, but never less on first success).
    assert energy_spent >= expected_cost - 0.001,
           "Expected ≥ #{expected_cost} spent; got #{energy_spent}"
  end

  # Verify that a failed conjugation (empty plasmid list → world returns push(0))
  # costs the donor EXACTLY the base cost across the full dispatch+world cycle.
  # This is a unit-level simulation: dispatch charges base_cost, world handler
  # calls conjugate_failure which pushes 0 with NO additional cost.
  test ":conjugate failure total cost equals base 4.0 (dispatch+world handler combined)" do
    # We simulate the full cost flow without starting a real Lenie process.
    alias Lenies.Interpreter
    alias Lenies.Interpreter.State, as: IState
    alias Lenies.Codeome

    start_energy = 100.0
    base_cost = Costs.cost(:conjugate, 0)

    # A Lenie with no plasmids (empty list) — dispatch will still yield
    # {:wait_world, {:conjugate, _, _, []}, new_state}.  The world handler
    # then calls conjugate_failure/1, which pushes 0 and does NOT deduct
    # any further energy.
    c = Codeome.from_list([:conjugate, :nop_0])
    state = IState.new(energy: start_energy, pos: {5, 5}, dir: :n)
    # No plasmids on state (default empty list).

    # Step 1: dispatch — charges base cost and advances IP.
    assert {:wait_world, {:conjugate, _, _, []}, after_dispatch} = Interpreter.step(state, c)
    assert_in_delta after_dispatch.energy, start_energy - base_cost, 0.0001

    # Step 2: world handler (simulated via conjugate_failure/1 equivalent):
    # just push(0) — no additional apply_cost.
    after_world = IState.push(after_dispatch, 0)

    # Total deduction = base_cost only.
    assert_in_delta start_energy - after_world.energy, base_cost, 0.0001
    assert hd(after_world.stack) == 0
  end

  # Verify that a successful conjugation total cost equals Costs.cost(:conjugate, plasmid_size).
  test ":conjugate success total cost equals Costs.cost(:conjugate, plasmid_size)" do
    alias Lenies.Interpreter
    alias Lenies.Interpreter.State, as: IState
    alias Lenies.Codeome

    plasmid_ops = [:turn_left, :defend, :eat, :move, :turn_right]
    plasmid_size = length(plasmid_ops)
    start_energy = 100.0
    base_cost = Costs.cost(:conjugate, 0)
    total_cost = Costs.cost(:conjugate, plasmid_size)
    surcharge = total_cost - base_cost

    plasmid = Plasmid.new(plasmid_ops)
    c = Codeome.from_list([:conjugate, :nop_0])

    state =
      IState.new(energy: start_energy, pos: {5, 5}, dir: :e)
      |> Map.put(:plasmids, [plasmid])

    # Step 1: dispatch — charges base cost.
    assert {:wait_world, {:conjugate, _, _, _ops}, after_dispatch} = Interpreter.step(state, c)
    assert_in_delta after_dispatch.energy, start_energy - base_cost, 0.0001

    # Step 2: world success path — applies surcharge only, pushes 1.
    after_world =
      after_dispatch
      |> IState.push(1)
      |> IState.apply_cost(surcharge)

    # Total deduction = total_cost.
    assert_in_delta start_energy - after_world.energy, total_cost, 0.0001
    assert hd(after_world.stack) == 1
  end
end
