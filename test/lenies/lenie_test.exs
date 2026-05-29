defmodule Lenies.LenieTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie}

  setup do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id, handle: handle}
  end

  test "start_link/1 registers the Lenie under its id",
       %{world_id: world_id, handle: handle} do
    # mark cell {5,5} as occupied (the Lenie expects to find itself there)
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L1"}})

    codeome = Codeome.from_list([:nop_0, :nop_1])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L1",
           codeome: codeome,
           energy: 50.0,
           pos: {5, 5},
           dir: :e,
           lineage: {nil, 0}
         ]}
      )

    assert Process.alive?(pid)
    assert [{^pid, _}] = Registry.lookup(Lenies.Registry, {:lenie, world_id, "L1"})

    GenServer.stop(pid)
  end

  test "inspect_state/1 returns current snapshot",
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
           energy: 10.0,
           pos: {5, 5},
           dir: :n,
           lineage: {nil, 0}
         ]}
      )

    snapshot = Lenie.inspect_state(pid)
    assert snapshot.id == "L2"
    assert snapshot.energy <= 10.0
    assert snapshot.pos == {5, 5}
    assert snapshot.dir == :n

    GenServer.stop(pid)
  end

  test "dies of starvation when energy depletes",
       %{world_id: world_id, handle: handle} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L3"}})

    # only 0.3 energy — will be consumed by a few nops + age increments
    codeome = Codeome.from_list([:nop_0, :nop_1, :add, :sub])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L3",
           codeome: codeome,
           energy: 0.3,
           pos: {5, 5},
           dir: :n,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(pid)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :starvation}, 1_000

    # cell freed
    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert after_cell.lenie_id == nil
  end

  describe "seeder_user_id propagation (sub-project #4 lineage)" do
    setup do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
      %{world_id: world_id, handle: handle}
    end

    test "Lenie stores seeder_user_id from opts and writes it to its ETS snapshot",
         %{world_id: world_id, handle: handle} do
      codeome = Lenies.Seeds.get(:minimal_replicator).codeome
      {:ok, {id, _pos}} =
        Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0, seeder_user_id: 42)

      Process.sleep(50)  # let the Lenie process write its initial snapshot

      assert [{^id, snap}] = :ets.lookup(handle.tables.lenies, id)
      assert snap.seeder_user_id == 42
    end

    test "Lenie defaults seeder_user_id to nil when opt is absent",
         %{world_id: world_id, handle: handle} do
      codeome = Lenies.Seeds.get(:minimal_replicator).codeome
      {:ok, {id, _pos}} = Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0)
      Process.sleep(50)

      assert [{^id, snap}] = :ets.lookup(handle.tables.lenies, id)
      assert snap.seeder_user_id == nil
    end
  end
end
