defmodule Lenies.World.ChildSlotsTest do
  use ExUnit.Case, async: false

  alias Lenies.World.ChildSlots

  setup do
    tid =
      :ets.new(:child_slots, [:set, :public, read_concurrency: true, write_concurrency: true])

    on_exit(fn ->
      try do
        :ets.delete(tid)
      rescue
        ArgumentError -> :ok
      end
    end)

    {:ok, tid: tid}
  end

  test "create/4 returns slot_id and stores record in :child_slots", %{tid: tid} do
    {:ok, slot_id} = ChildSlots.create(tid, "parent1", {10, 10}, 50)
    assert is_binary(slot_id)

    {:ok, slot} = ChildSlots.get(tid, slot_id)
    assert slot.parent_id == "parent1"
    assert slot.target_cell == {10, 10}
    assert slot.size == 50
    # opcodes initialized to :nop_0 × size
    assert tuple_size(slot.opcodes) == 50
    assert elem(slot.opcodes, 0) == :nop_0
    assert elem(slot.opcodes, 49) == :nop_0
  end

  test "get/2 returns :not_found for unknown slot", %{tid: tid} do
    assert ChildSlots.get(tid, "never-created") == :not_found
  end

  test "set_opcode/4 updates a single position", %{tid: tid} do
    {:ok, slot_id} = ChildSlots.create(tid, "parent1", {10, 10}, 5)
    :ok = ChildSlots.set_opcode(tid, slot_id, 2, :move)

    {:ok, slot} = ChildSlots.get(tid, slot_id)
    assert elem(slot.opcodes, 2) == :move
    assert elem(slot.opcodes, 0) == :nop_0
  end

  test "set_opcode/4 wraps slot_addr modulo size (tolerance)", %{tid: tid} do
    {:ok, slot_id} = ChildSlots.create(tid, "parent1", {10, 10}, 5)
    :ok = ChildSlots.set_opcode(tid, slot_id, 7, :eat)

    {:ok, slot} = ChildSlots.get(tid, slot_id)
    # 7 mod 5 = 2
    assert elem(slot.opcodes, 2) == :eat
  end

  test "delete/2 removes the record", %{tid: tid} do
    {:ok, slot_id} = ChildSlots.create(tid, "parent1", {10, 10}, 5)
    :ok = ChildSlots.delete(tid, slot_id)
    assert ChildSlots.get(tid, slot_id) == :not_found
  end

  test "opcodes_to_list/1 returns the opcode list", %{tid: tid} do
    {:ok, slot_id} = ChildSlots.create(tid, "parent1", {10, 10}, 3)
    :ok = ChildSlots.set_opcode(tid, slot_id, 1, :move)
    {:ok, slot} = ChildSlots.get(tid, slot_id)
    assert ChildSlots.opcodes_to_list(slot) == [:nop_0, :move, :nop_0]
  end
end
