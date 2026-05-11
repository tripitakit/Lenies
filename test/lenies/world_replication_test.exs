defmodule Lenies.WorldReplicationTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.{ChildSlots, Tables}

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

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    # mark parent's cell
    [{key, cell}] = :ets.lookup(:cells, {10, 10})
    :ets.insert(:cells, {key, %{cell | lenie_id: "P1"}})
    :ets.insert(:lenies, {"P1", %{id: "P1", pid: self(), pos: {10, 10}, dir: :e}})
    :ok
  end

  describe "allocate" do
    test "succeeds when front cell is free; creates child slot" do
      result = World.action({:allocate, 20, {10, 10}, :e, "P1"})
      assert {:ok, {:allocated, slot_id, target_cell}} = result
      assert target_cell == {11, 10}
      assert is_binary(slot_id)

      # slot exists in :child_slots
      {:ok, slot} = ChildSlots.get(slot_id)
      assert slot.parent_id == "P1"
      assert slot.target_cell == {11, 10}
      assert slot.size == 20

      # parent's :lenies record has child_slot_id
      [{"P1", lenie_record}] = :ets.lookup(:lenies, "P1")
      assert lenie_record.child_slot_id == slot_id
    end

    test "fails when front cell is occupied by another Lenie" do
      [{key, cell}] = :ets.lookup(:cells, {11, 10})
      :ets.insert(:cells, {key, %{cell | lenie_id: "OTHER"}})

      result = World.action({:allocate, 20, {10, 10}, :e, "P1"})
      assert result == {:ok, :blocked}
    end

    test "fails when parent already has a slot allocated" do
      {:ok, _} = World.action({:allocate, 20, {10, 10}, :e, "P1"})
      result = World.action({:allocate, 30, {10, 10}, :e, "P1"})
      assert result == {:ok, :already_allocated}
    end

    test "fails when requested size out of bounds" do
      # codeome_length_bounds default {5, 500}
      result = World.action({:allocate, 2, {10, 10}, :e, "P1"})
      assert result == {:ok, :invalid_size}

      result = World.action({:allocate, 1000, {10, 10}, :e, "P1"})
      assert result == {:ok, :invalid_size}
    end
  end
end
