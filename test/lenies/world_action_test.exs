defmodule Lenies.WorldActionTest do
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

  describe "sense_front" do
    test "returns :empty when the front cell is empty" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      result = World.action({:sense_front, {10, 10}, :e})
      assert result == {:ok, :empty}
    end

    test "returns {:resource, n} when the front cell has biomass" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      # inject resource in cell {11, 10} (front of {10,10} facing east)
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {11, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | resource: 50}})

      result = World.action({:sense_front, {10, 10}, :e})
      assert result == {:ok, {:resource, 50}}
    end
  end

  describe "move" do
    test "succeeds when the target cell is free" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      # mark current cell as occupied by Lenie "L1"
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {10, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "L1"}})

      # before
      assert :ets.lookup(Lenies.WorldTestHelpers.cells(), {10, 10}) |> hd() |> elem(1) |> Map.get(:lenie_id) == "L1"

      result = World.action({:move, {10, 10}, :e, "L1"})
      assert {:ok, {:moved, {11, 10}}} = result

      # after: old cell free, new cell has L1
      assert :ets.lookup(Lenies.WorldTestHelpers.cells(), {10, 10}) |> hd() |> elem(1) |> Map.get(:lenie_id) == nil
      assert :ets.lookup(Lenies.WorldTestHelpers.cells(), {11, 10}) |> hd() |> elem(1) |> Map.get(:lenie_id) == "L1"
    end

    test "fails (no-op) when the target cell is occupied" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      [{k1, c1}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {10, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {k1, %{c1 | lenie_id: "L1"}})
      [{k2, c2}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {11, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {k2, %{c2 | lenie_id: "L2"}})

      result = World.action({:move, {10, 10}, :e, "L1"})
      assert result == {:ok, :blocked}
      assert :ets.lookup(Lenies.WorldTestHelpers.cells(), {10, 10}) |> hd() |> elem(1) |> Map.get(:lenie_id) == "L1"
    end

    test "wraps around toroidal boundary" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {255, 0})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "L1"}})

      result = World.action({:move, {255, 0}, :e, "L1"})
      assert {:ok, {:moved, {0, 0}}} = result
    end
  end

  describe "eat" do
    test "transfers min(eat_amount, cell.resource) and clears that much" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | resource: 30}})

      # default eat_amount = 20
      result = World.action({:eat, {5, 5}})
      assert result == {:ok, {:ate, 20}}
      assert :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5}) |> hd() |> elem(1) |> Map.get(:resource) == 10
    end

    test "returns {:ate, 0} if cell has no resource" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      result = World.action({:eat, {5, 5}})
      assert result == {:ok, {:ate, 0}}
    end
  end
end
