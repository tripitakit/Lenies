defmodule Lenies.World.ChildSlotsTest do
  use ExUnit.Case, async: false

  alias Lenies.World.ChildSlots
  alias Lenies.World.Tables

  setup do
    Tables.create_all()
    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  test "create/3 returns slot_id and stores record in :child_slots" do
    {:ok, slot_id} = ChildSlots.create("parent1", {10, 10}, 50)
    assert is_binary(slot_id)

    {:ok, slot} = ChildSlots.get(slot_id)
    assert slot.parent_id == "parent1"
    assert slot.target_cell == {10, 10}
    assert slot.size == 50
    # opcodes initialized to :nop_0 × size
    assert tuple_size(slot.opcodes) == 50
    assert elem(slot.opcodes, 0) == :nop_0
    assert elem(slot.opcodes, 49) == :nop_0
  end

  test "get/1 returns :not_found for unknown slot" do
    assert ChildSlots.get("never-created") == :not_found
  end

  test "set_opcode/3 updates a single position" do
    {:ok, slot_id} = ChildSlots.create("parent1", {10, 10}, 5)
    :ok = ChildSlots.set_opcode(slot_id, 2, :move)

    {:ok, slot} = ChildSlots.get(slot_id)
    assert elem(slot.opcodes, 2) == :move
    assert elem(slot.opcodes, 0) == :nop_0
  end

  test "set_opcode/3 wraps slot_addr modulo size (tolerance)" do
    {:ok, slot_id} = ChildSlots.create("parent1", {10, 10}, 5)
    :ok = ChildSlots.set_opcode(slot_id, 7, :eat)

    {:ok, slot} = ChildSlots.get(slot_id)
    # 7 mod 5 = 2
    assert elem(slot.opcodes, 2) == :eat
  end

  test "delete/1 removes the record" do
    {:ok, slot_id} = ChildSlots.create("parent1", {10, 10}, 5)
    :ok = ChildSlots.delete(slot_id)
    assert ChildSlots.get(slot_id) == :not_found
  end

  test "opcodes_to_list/1 returns the opcode list" do
    {:ok, slot_id} = ChildSlots.create("parent1", {10, 10}, 3)
    :ok = ChildSlots.set_opcode(slot_id, 1, :move)
    {:ok, slot} = ChildSlots.get(slot_id)
    assert ChildSlots.opcodes_to_list(slot) == [:nop_0, :move, :nop_0]
  end
end
