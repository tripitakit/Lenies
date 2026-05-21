defmodule Lenies.WorldCarcassEatTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
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

  test "lenie_died accumulates carcass instead of replacing" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    World.lenie_died("dead1", {3, 3}, 20.0, "test-hash")
    # wait for the async cast to complete
    GenServer.call(Lenies.World, :tick_now)

    [{_, cell1}] = :ets.lookup(:cells, {3, 3})
    # 20 * 0.5 = 10
    assert cell1.carcass == 10

    World.lenie_died("dead2", {3, 3}, 30.0, "test-hash")
    GenServer.call(Lenies.World, :tick_now)

    [{_, cell2}] = :ets.lookup(:cells, {3, 3})
    # Existing 10 + new 15 (30*0.5) = 25, possibly minus 5% decay from one tick
    assert cell2.carcass >= 23
  end

  # MH3: updated from 1.5x to 1:1 energy conservation
  test ":eat consumes carcass first, energy 1:1 (no bonus)" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | resource: 50, carcass: 10}})

    # eat_amount = 20 default. Carcass-first: carcass_taken = 10 (1:1 energy),
    # remaining_quota = 10, resource_taken = min(50, 10) = 10. total = 10 + 10 = 20.
    {:ok, {:ate, amount}} = World.action({:eat, {5, 5}})
    # 10 carcass (1:1) + 10 resource = 20 total
    assert amount == 20

    [{_, after_cell}] = :ets.lookup(:cells, {5, 5})
    assert after_cell.carcass == 0
    # 10 resource consumed to fill remaining quota
    assert after_cell.resource == 40
  end

  # MH3: conservation check — carcass-only cell, carcass ≤ eat_amount
  test ":eat on carcass-only cell conserves energy (carcass_taken == energy_gained)" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {6, 6})
    :ets.insert(:cells, {key, %{cell | resource: 0, carcass: 8}})

    # eat_amount = 20; carcass = 8 < 20, so carcass_taken = 8, resource_taken = 0
    # total_energy must equal 8 (1:1 conservation, not 12 from 1.5x)
    {:ok, {:ate, amount}} = World.action({:eat, {6, 6}})
    assert amount == 8

    [{_, after_cell}] = :ets.lookup(:cells, {6, 6})
    assert after_cell.carcass == 0
    assert after_cell.resource == 0
  end

  # MH3: conservation check — carcass-only partial (carcass > eat_amount)
  test ":eat on carcass-only cell with carcass > eat_amount yields exactly eat_amount" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {7, 7})
    :ets.insert(:cells, {key, %{cell | resource: 0, carcass: 100}})

    # eat_amount = 20; carcass = 100, so carcass_taken = 20, energy = 20
    {:ok, {:ate, amount}} = World.action({:eat, {7, 7}})
    assert amount == 20

    [{_, after_cell}] = :ets.lookup(:cells, {7, 7})
    assert after_cell.carcass == 80
    assert after_cell.resource == 0
  end

  # MH3: conservation in mixed cell — energy_gained == carcass_taken + resource_taken
  test ":eat mixed cell conserves energy (energy == carcass_taken + resource_taken)" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    # Set eat_amount explicitly to avoid config dependency
    original_eat_amount = Application.get_env(:lenies, :eat_amount)
    Application.put_env(:lenies, :eat_amount, 15)

    on_exit(fn ->
      if original_eat_amount,
        do: Application.put_env(:lenies, :eat_amount, original_eat_amount),
        else: Application.delete_env(:lenies, :eat_amount)
    end)

    [{key, cell}] = :ets.lookup(:cells, {8, 8})
    # carcass=5 < eat_amount=15, so carcass_taken=5, remaining=10, resource_taken=min(20,10)=10
    :ets.insert(:cells, {key, %{cell | resource: 20, carcass: 5}})

    {:ok, {:ate, amount}} = World.action({:eat, {8, 8}})
    # energy must equal carcass_taken + resource_taken = 5 + 10 = 15
    assert amount == 15

    [{_, after_cell}] = :ets.lookup(:cells, {8, 8})
    assert after_cell.carcass == 0
    assert after_cell.resource == 10
  end

  test ":eat falls through to resource when carcass empty" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | resource: 30}})

    {:ok, {:ate, amount}} = World.action({:eat, {5, 5}})
    # eat_amount
    assert amount == 20

    [{_, after_cell}] = :ets.lookup(:cells, {5, 5})
    assert after_cell.resource == 10
  end

  test ":eat takes carcass + resource if both present and eat_amount is large" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | resource: 50, carcass: 5}})

    # default eat_amount = 20; takes 5 carcass (5 energy, 1:1)
    # then 15 remaining quota from resource → result energy = 5 + 15 = 20
    # exactly 20 now (no bonus), but carcass IS depleted and resource IS consumed
    {:ok, {:ate, amount}} = World.action({:eat, {5, 5}})
    assert amount == 20
    [{_, after_cell}] = :ets.lookup(:cells, {5, 5})
    assert after_cell.carcass == 0
    assert after_cell.resource == 35
  end

  # Regression for the astronomical-detritus bug: eating a carcass repeatedly
  # must never yield MORE total energy than the carcass held. The old 1.5x
  # bonus created 0.5x energy per eat, which — in the energy→death→carcass→eat
  # loop — accumulated without bound (detritus blew up to ~1e23). With 1:1
  # conservation the total extracted equals exactly the carcass, never more.
  test "repeatedly eating a carcass creates no energy (sum == carcass, not 1.5x)" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    original_eat_amount = Application.get_env(:lenies, :eat_amount)
    Application.put_env(:lenies, :eat_amount, 20)

    on_exit(fn ->
      if original_eat_amount,
        do: Application.put_env(:lenies, :eat_amount, original_eat_amount),
        else: Application.delete_env(:lenies, :eat_amount)
    end)

    carcass = 1000
    [{key, cell}] = :ets.lookup(:cells, {9, 9})
    :ets.insert(:cells, {key, %{cell | resource: 0, carcass: carcass}})

    # Drain the carcass with repeated eats; sum every unit of energy handed out.
    total =
      Enum.reduce_while(1..1000, 0, fn _, acc ->
        {:ok, {:ate, amount}} = World.action({:eat, {9, 9}})

        if amount == 0 do
          {:halt, acc}
        else
          {:cont, acc + amount}
        end
      end)

    # Total energy extracted equals the carcass exactly — no creation.
    # (Old 1.5x code would have produced 1500.)
    assert total == carcass

    [{_, after_cell}] = :ets.lookup(:cells, {9, 9})
    assert after_cell.carcass == 0
  end
end
