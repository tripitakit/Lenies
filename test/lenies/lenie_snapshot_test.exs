defmodule Lenies.LenieSnapshotTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie}

  setup do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id, handle: handle}
  end

  test "Lenie writes a snapshot to :lenies ETS within a few batches",
       %{world_id: world_id, handle: handle} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L1"}})

    codeome = Codeome.from_list([:nop_0, :nop_1])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L1",
           codeome: codeome,
           energy: 100_000.0,
           pos: {5, 5},
           dir: :e,
           lineage: {nil, 0}
         ]}
      )

    # Unlink so that if the Lenie dies of starvation during the sleep,
    # the EXIT does not propagate to the test process.
    Process.unlink(pid)

    # snapshot_every_batches default 10, batch is fast — wait a bit
    Process.sleep(200)

    case :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), "L1") do
      [{"L1", snap}] ->
        assert snap.id == "L1"
        assert is_float(snap.energy) or is_integer(snap.energy)
        assert snap.pos == {5, 5}
        assert snap.dir == :e
        assert is_integer(snap.age)
        assert is_binary(snap.codeome_hash)

      [] ->
        flunk("expected :lenies ETS entry for L1, found none")
    end

    GenServer.stop(pid)
  end

  test "still metabolizes with hibernation enabled between batches",
       %{world_id: world_id, handle: handle} do
    Application.put_env(:lenies, :lenie_hibernate_after_batch, true)
    on_exit(fn -> Application.delete_env(:lenies, :lenie_hibernate_after_batch) end)

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {6, 6})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "HIB"}})

    codeome = Codeome.from_list([:nop_0, :nop_1])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [id: "HIB", codeome: codeome, energy: 100_000.0, pos: {6, 6}, dir: :n, lineage: {nil, 0}]}
      )

    Process.unlink(pid)
    Process.sleep(200)

    # The Lenie woke from hibernation, ran batches, and persisted a snapshot.
    assert [{"HIB", snap}] = :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), "HIB")
    assert snap.age >= 1
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end

  test "snapshot is removed on death (via World.lenie_died)",
       %{world_id: world_id, handle: handle} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L2"}})

    codeome = Codeome.from_list([:nop_0])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L2",
           codeome: codeome,
           energy: 0.3,
           pos: {5, 5},
           dir: :n,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(pid)

    # let it die of starvation
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :starvation}, 1_000

    # death is async (cast) — wait for World to process
    Process.sleep(100)

    assert :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), "L2") == []
  end

  test "snapshot preserves World-added fields like child_slot_id",
       %{world_id: world_id, handle: handle} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L4"}})

    codeome = Codeome.from_list([:nop_0, :nop_1])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L4",
           codeome: codeome,
           energy: 100_000.0,
           pos: {5, 5},
           dir: :e,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(pid)

    # World adds child_slot_id
    Process.sleep(50)
    [{"L4", record}] = :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), "L4")
    merged = Map.put(record, :child_slot_id, "fake-slot-123")
    :ets.insert(Lenies.WorldTestHelpers.lenies(world_id), {"L4", merged})

    # Let the Lenie write another snapshot (cadence = 10, batches happen fast)
    Process.sleep(500)

    [{"L4", record_after}] = :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), "L4")

    assert record_after.child_slot_id == "fake-slot-123",
           "Lenie snapshot should NOT clobber World-added child_slot_id field"

    GenServer.stop(pid)
  end
end
