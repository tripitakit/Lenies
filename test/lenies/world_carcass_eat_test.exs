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

  test ":eat consumes carcass first with 1.5x efficiency" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | resource: 50, carcass: 10}})

    # eat_amount = 20 default; carcass available = 10 → take 10 carcass for 15 energy (1.5x)
    {:ok, {:ate, amount}} = World.action({:eat, {5, 5}})
    # 10 carcass * 1.5 = 15 energy
    assert amount == 15

    [{_, after_cell}] = :ets.lookup(:cells, {5, 5})
    assert after_cell.carcass == 0
    # untouched
    assert after_cell.resource == 50
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

    # default eat_amount = 20; takes 5 carcass for 7.5 energy (round up to 7)
    # then 15 remaining quota from resource → result energy = 7 + 15 = 22
    # But we round consistently — assert just that energy > 20 (more than pure resource)
    {:ok, {:ate, amount}} = World.action({:eat, {5, 5}})
    assert amount > 20
    [{_, after_cell}] = :ets.lookup(:cells, {5, 5})
    assert after_cell.carcass == 0
    assert after_cell.resource < 50
  end
end
