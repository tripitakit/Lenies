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

  # MH3: updated from 1.5x to 1:1 energy conservation
  test ":eat consumes carcass first, energy 1:1 (no bonus)", %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})

    :ets.insert(
      Lenies.WorldTestHelpers.cells(world_id),
      {key, %{cell | resource: 50, carcass: 10}}
    )

    # eat_amount = 20 default. Carcass-first: carcass_taken = 10 (1:1 energy),
    # remaining_quota = 10, resource_taken = min(50, 10) = 10. total = 10 + 10 = 20.
    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {5, 5}})
    # 10 carcass (1:1) + 10 resource = 20 total
    assert amount == 20

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert after_cell.carcass == 0
    # 10 resource consumed to fill remaining quota
    assert after_cell.resource == 40
  end

  # MH3: conservation check — carcass-only cell, carcass ≤ eat_amount
  test ":eat on carcass-only cell conserves energy (carcass_taken == energy_gained)",
       %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {6, 6})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 0, carcass: 8}})

    # eat_amount = 20; carcass = 8 < 20, so carcass_taken = 8, resource_taken = 0
    # total_energy must equal 8 (1:1 conservation, not 12 from 1.5x)
    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {6, 6}})
    assert amount == 8

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {6, 6})
    assert after_cell.carcass == 0
    assert after_cell.resource == 0
  end

  # MH3: conservation check — carcass-only partial (carcass > eat_amount)
  test ":eat on carcass-only cell with carcass > eat_amount yields exactly eat_amount",
       %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {7, 7})

    :ets.insert(
      Lenies.WorldTestHelpers.cells(world_id),
      {key, %{cell | resource: 0, carcass: 100}}
    )

    # eat_amount = 20; carcass = 100, so carcass_taken = 20, energy = 20
    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {7, 7}})
    assert amount == 20

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {7, 7})
    assert after_cell.carcass == 80
    assert after_cell.resource == 0
  end

  # MH3: conservation in mixed cell — energy_gained == carcass_taken + resource_taken
  test ":eat mixed cell conserves energy (energy == carcass_taken + resource_taken)",
       %{world_id: world_id} do
    # World already booted; mutate state.config live via the facade.
    :ok = Lenies.Worlds.tune(world_id, :eat_amount, 15)

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {8, 8})
    # carcass=5 < eat_amount=15, so carcass_taken=5, remaining=10, resource_taken=min(20,10)=10
    :ets.insert(
      Lenies.WorldTestHelpers.cells(world_id),
      {key, %{cell | resource: 20, carcass: 5}}
    )

    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {8, 8}})
    # energy must equal carcass_taken + resource_taken = 5 + 10 = 15
    assert amount == 15

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {8, 8})
    assert after_cell.carcass == 0
    assert after_cell.resource == 10
  end

  test ":eat falls through to resource when carcass empty", %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 30}})

    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {5, 5}})
    # eat_amount
    assert amount == 20

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert after_cell.resource == 10
  end

  test ":eat takes carcass + resource if both present and eat_amount is large",
       %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})

    :ets.insert(
      Lenies.WorldTestHelpers.cells(world_id),
      {key, %{cell | resource: 50, carcass: 5}}
    )

    # default eat_amount = 20; takes 5 carcass (5 energy, 1:1)
    # then 15 remaining quota from resource → result energy = 5 + 15 = 20
    # exactly 20 now (no bonus), but carcass IS depleted and resource IS consumed
    {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {5, 5}})
    assert amount == 20
    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert after_cell.carcass == 0
    assert after_cell.resource == 35
  end

  # Regression for the astronomical-detritus bug: eating a carcass repeatedly
  # must never yield MORE total energy than the carcass held. The old 1.5x
  # bonus created 0.5x energy per eat, which — in the energy→death→carcass→eat
  # loop — accumulated without bound (detritus blew up to ~1e23). With 1:1
  # conservation the total extracted equals exactly the carcass, never more.
  test "repeatedly eating a carcass creates no energy (sum == carcass, not 1.5x)",
       %{world_id: world_id} do
    # World already booted; mutate state.config live via the facade.
    :ok = Lenies.Worlds.tune(world_id, :eat_amount, 20)

    carcass = 1000
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {9, 9})

    :ets.insert(
      Lenies.WorldTestHelpers.cells(world_id),
      {key, %{cell | resource: 0, carcass: carcass}}
    )

    # Drain the carcass with repeated eats; sum every unit of energy handed out.
    total =
      Enum.reduce_while(1..1000, 0, fn _, acc ->
        {:ok, {:ate, amount}} = Lenies.Worlds.action(world_id, {:eat, {9, 9}})

        if amount == 0 do
          {:halt, acc}
        else
          {:cont, acc + amount}
        end
      end)

    # Total energy extracted equals the carcass exactly — no creation.
    # (Old 1.5x code would have produced 1500.)
    assert total == carcass

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {9, 9})
    assert after_cell.carcass == 0
  end
end
