defmodule Lenies.WorldCarcassEatTest do
  use ExUnit.Case, async: false

  setup do
    # Pin eat_amount so the carcass/eat assertions are independent of the default.
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(eat_amount: 20)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id}
  end

  test "lenie_died accumulates carcass instead of replacing", %{world_id: world_id} do
    Lenies.Worlds.lenie_died(world_id, "dead1", {3, 3}, 20.0, "test-hash")
    # wait for the async cast to complete
    Lenies.Worlds.tick_now(world_id)

    [{_, cell1}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {3, 3})
    # 20 * 0.5 = 10
    assert cell1.carcass == 10

    Lenies.Worlds.lenie_died(world_id, "dead2", {3, 3}, 30.0, "test-hash")
    Lenies.Worlds.tick_now(world_id)

    [{_, cell2}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {3, 3})
    # Existing 10 + new 15 (30*0.5) = 25, possibly minus 5% decay from one tick
    assert cell2.carcass >= 23
  end

  # Eat empties the cell: Lenie gains ALL resource + carcass in one bite.
  test ":eat empties the cell — returns resource + carcass, zeros both",
       %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})

    :ets.insert(
      Lenies.WorldTestHelpers.cells(world_id),
      {key, %{cell | resource: 50, carcass: 10}}
    )

    # Eat empties the whole cell: gains resource(50) + carcass(10) = 60
    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {5, 5}})
    assert amount == 60

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert after_cell.resource == 0
    assert after_cell.carcass == 0
    assert after_cell.carcass_hue == 0
  end

  # Carcass-only cell: eat drains everything.
  test ":eat on carcass-only cell empties it (returns all carcass)",
       %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {6, 6})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 0, carcass: 8}})

    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {6, 6}})
    assert amount == 8

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {6, 6})
    assert after_cell.carcass == 0
    assert after_cell.resource == 0
  end

  # Large carcass: eat still drains everything in one bite.
  test ":eat on carcass-only cell with large carcass drains all in one bite",
       %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {7, 7})

    :ets.insert(
      Lenies.WorldTestHelpers.cells(world_id),
      {key, %{cell | resource: 0, carcass: 100}}
    )

    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {7, 7}})
    assert amount == 100

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {7, 7})
    assert after_cell.carcass == 0
    assert after_cell.resource == 0
  end

  # Mixed cell: eat returns resource + carcass total and clears both.
  test ":eat mixed cell returns sum of resource and carcass",
       %{world_id: world_id} do
    :ok = Lenies.Worlds.tune(world_id, :eat_amount, 15)

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {8, 8})
    :ets.insert(
      Lenies.WorldTestHelpers.cells(world_id),
      {key, %{cell | resource: 20, carcass: 5}}
    )

    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {8, 8}})
    # empties all: resource(20) + carcass(5) = 25
    assert amount == 25

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {8, 8})
    assert after_cell.carcass == 0
    assert after_cell.resource == 0
  end

  test ":eat falls through to resource when carcass empty", %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 30, carcass: 0}})

    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {5, 5}})
    # empties all resource
    assert amount == 30

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert after_cell.resource == 0
  end

  test ":eat takes carcass + resource if both present — drains cell fully",
       %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})

    :ets.insert(
      Lenies.WorldTestHelpers.cells(world_id),
      {key, %{cell | resource: 50, carcass: 5}}
    )

    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {5, 5}})
    # empties all: resource(50) + carcass(5) = 55
    assert amount == 55
    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert after_cell.carcass == 0
    assert after_cell.resource == 0
  end

  # Eat on an already-empty cell returns 0 (no energy to extract).
  # Eating a carcass once empties it; a second eat returns 0 — no energy creation.
  test "repeatedly eating a carcass: first eat drains all, second eat returns 0",
       %{world_id: world_id} do
    :ok = Lenies.Worlds.tune(world_id, :eat_amount, 20)

    carcass = 1000
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {9, 9})

    :ets.insert(
      Lenies.WorldTestHelpers.cells(world_id),
      {key, %{cell | resource: 0, carcass: carcass}}
    )

    # First eat drains the entire carcass in one bite.
    {:ok, {:ate, first}} = Lenies.Worlds.action(world_id, {:eat, {9, 9}})
    assert first == carcass

    # Second eat on now-empty cell returns 0.
    {:ok, {:ate, second}} = Lenies.Worlds.action(world_id, {:eat, {9, 9}})
    assert second == 0

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {9, 9})
    assert after_cell.carcass == 0
  end
end
