defmodule Lenies.WorldActionTest do
  use ExUnit.Case, async: false

  setup do
    # Pin eat_amount so the eat assertions are independent of the project default.
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0, eat_amount: 20)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id}
  end

  describe "sense_front" do
    test "returns :empty when the front cell is empty", %{world_id: world_id} do
      result = Lenies.Worlds.action(world_id, {:sense_front, {10, 10}, :e})
      assert result == {:ok, :empty}
    end

    test "returns {:resource, n} when the front cell has biomass", %{world_id: world_id} do
      # inject resource in cell {11, 10} (front of {10,10} facing east)
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {11, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 50}})

      result = Lenies.Worlds.action(world_id, {:sense_front, {10, 10}, :e})
      assert result == {:ok, {:resource, 50}}
    end
  end

  describe "move" do
    test "succeeds when the target cell is free", %{world_id: world_id} do
      # mark current cell as occupied by Lenie "L1"
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {10, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L1"}})

      # before
      assert :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {10, 10})
             |> hd()
             |> elem(1)
             |> Map.get(:lenie_id) == "L1"

      result = Lenies.Worlds.action(world_id, {:move, {10, 10}, :e, "L1"})
      assert {:ok, {:moved, {11, 10}}} = result

      # after: old cell free, new cell has L1
      assert :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {10, 10})
             |> hd()
             |> elem(1)
             |> Map.get(:lenie_id) == nil

      assert :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {11, 10})
             |> hd()
             |> elem(1)
             |> Map.get(:lenie_id) == "L1"
    end

    test "fails (no-op) when the target cell is occupied", %{world_id: world_id} do
      [{k1, c1}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {10, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {k1, %{c1 | lenie_id: "L1"}})
      [{k2, c2}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {11, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {k2, %{c2 | lenie_id: "L2"}})

      result = Lenies.Worlds.action(world_id, {:move, {10, 10}, :e, "L1"})
      assert result == {:ok, :blocked}

      assert :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {10, 10})
             |> hd()
             |> elem(1)
             |> Map.get(:lenie_id) == "L1"
    end

    test "wraps around toroidal boundary", %{world_id: world_id} do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {127, 0})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L1"}})

      result = Lenies.Worlds.action(world_id, {:move, {127, 0}, :e, "L1"})
      assert {:ok, {:moved, {0, 0}}} = result
    end
  end

  describe "eat" do
    test "transfers min(eat_amount, cell.resource) and clears that much",
         %{world_id: world_id} do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 30}})

      # default eat_amount = 20
      result = Lenies.Worlds.action(world_id, {:eat, {5, 5}})
      assert result == {:ok, {:ate, 20}}

      assert :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
             |> hd()
             |> elem(1)
             |> Map.get(:resource) == 10
    end

    test "returns {:ate, 0} if cell has no resource", %{world_id: world_id} do
      result = Lenies.Worlds.action(world_id, {:eat, {5, 5}})
      assert result == {:ok, {:ate, 0}}
    end
  end
end
