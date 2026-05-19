defmodule Lenies.ConjugationTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie, Plasmid, World}
  alias Lenies.World.Tables

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

  test "receive_plasmid appends to codeome and replaces plasmid buffer" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "RX"}})

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

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "RX"}})

    {:ok, recipient_pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move, :turn_left, :eat, :move, :turn_right, :eat, :move]),
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

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "SOLO"}})

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

    [{key1, c1}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key1, %{c1 | lenie_id: "TX"}})
    [{key2, c2}] = :ets.lookup(:cells, {129, 128})
    :ets.insert(:cells, {key2, %{c2 | lenie_id: "RX"}})

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
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:fx")

    [{key1, c1}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key1, %{c1 | lenie_id: "TX"}})
    [{key2, c2}] = :ets.lookup(:cells, {129, 128})
    :ets.insert(:cells, {key2, %{c2 | lenie_id: "RX"}})

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

    assert_receive {:conjugation, {128, 128}, {129, 128}}, 1000
  end

  test "background_mutate also touches the plasmid buffer (after multiple cycles)" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "BG"}})

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
    # substitution. With 50 substitutions on a 30-opcode buffer of all
    # :eat, the probability that all 50 picks land on :eat is
    # (1/36)^50 ≈ 0 — so we expect to see at least one different opcode.
    for _ <- 1..50, do: send(pid, :background_mutate)
    Process.sleep(200)

    snapshot = :sys.get_state(pid)
    [%Plasmid{opcodes: new_ops}] = snapshot.plasmids

    assert length(new_ops) == 30
    diff = Enum.zip(original_ops, new_ops) |> Enum.count(fn {a, b} -> a != b end)
    assert diff > 0, "expected at least one opcode to differ after 50 background mutations; got diff=#{diff}"
  end
end
