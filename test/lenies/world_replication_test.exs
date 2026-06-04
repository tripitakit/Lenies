defmodule Lenies.WorldReplicationTest do
  use ExUnit.Case, async: false

  alias Lenies.World.ChildSlots

  setup do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)

    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

    # mark parent's cell
    [{key, cell}] = :ets.lookup(handle.tables.cells, {10, 10})
    :ets.insert(handle.tables.cells, {key, %{cell | lenie_id: "P1"}})
    :ets.insert(handle.tables.lenies, {"P1", %{id: "P1", pid: self(), pos: {10, 10}, dir: :e}})

    {:ok, world_id: world_id, handle: handle}
  end

  describe "allocate" do
    test "succeeds when front cell is free; creates child slot",
         %{world_id: world_id, handle: h} do
      result = Lenies.Worlds.action(world_id, {:allocate, 20, {10, 10}, :e, "P1"})
      assert {:ok, {:allocated, slot_id, target_cell}} = result
      assert target_cell == {11, 10}
      assert is_binary(slot_id)

      # slot exists in :child_slots
      {:ok, slot} = ChildSlots.get(h.tables.child_slots, slot_id)
      assert slot.parent_id == "P1"
      assert slot.target_cell == {11, 10}
      assert slot.size == 20

      # parent's :lenies record has child_slot_id
      [{"P1", lenie_record}] = :ets.lookup(h.tables.lenies, "P1")
      assert lenie_record.child_slot_id == slot_id
    end

    test "fails when front cell is occupied by another Lenie",
         %{world_id: world_id, handle: h} do
      [{key, cell}] = :ets.lookup(h.tables.cells, {11, 10})
      :ets.insert(h.tables.cells, {key, %{cell | lenie_id: "OTHER"}})

      result = Lenies.Worlds.action(world_id, {:allocate, 20, {10, 10}, :e, "P1"})
      assert result == {:ok, :blocked}
    end

    test "fails when parent already has a slot allocated", %{world_id: world_id} do
      {:ok, _} = Lenies.Worlds.action(world_id, {:allocate, 20, {10, 10}, :e, "P1"})
      result = Lenies.Worlds.action(world_id, {:allocate, 30, {10, 10}, :e, "P1"})
      assert result == {:ok, :already_allocated}
    end

    test "fails when requested size out of bounds", %{world_id: world_id} do
      # codeome_length_bounds default {5, 1024}
      result = Lenies.Worlds.action(world_id, {:allocate, 2, {10, 10}, :e, "P1"})
      assert result == {:ok, :invalid_size}

      result = Lenies.Worlds.action(world_id, {:allocate, 1025, {10, 10}, :e, "P1"})
      assert result == {:ok, :invalid_size}
    end
  end

  describe "write_child" do
    setup %{world_id: world_id, handle: h} do
      # Ensure parent has an allocated slot at this point
      {:ok, {:allocated, slot_id, _}} =
        Lenies.Worlds.action(world_id, {:allocate, 20, {10, 10}, :e, "P1"})

      %{slot_id: slot_id, handle: h}
    end

    test "writes opcode at addr without mutation when rates are 0", %{
      world_id: world_id,
      slot_id: slot_id,
      handle: h
    } do
      saved_sub = Application.get_env(:lenies, :copy_substitution_rate)
      saved_ins = Application.get_env(:lenies, :copy_insert_rate)
      saved_del = Application.get_env(:lenies, :copy_delete_rate)
      Application.put_env(:lenies, :copy_substitution_rate, 0.0)
      Application.put_env(:lenies, :copy_insert_rate, 0.0)
      Application.put_env(:lenies, :copy_delete_rate, 0.0)

      try do
        move_int = Lenies.Codeome.Opcodes.encode(:move)
        result = Lenies.Worlds.action(world_id, {:write_child, move_int, 3, "P1"})
        assert result == {:ok, :written}

        {:ok, slot} = ChildSlots.get(h.tables.child_slots, slot_id)
        assert elem(slot.opcodes, 3) == :move
      after
        Application.put_env(:lenies, :copy_substitution_rate, saved_sub || 0.005)
        Application.put_env(:lenies, :copy_insert_rate, saved_ins || 0.0005)
        Application.put_env(:lenies, :copy_delete_rate, saved_del || 0.0005)
      end
    end

    test "fails when parent has no slot allocated", %{world_id: world_id, handle: h} do
      # remove the child_slot_id by re-inserting the lenies record without it
      :ets.delete(h.tables.lenies, "P1")
      :ets.insert(h.tables.lenies, {"P1", %{id: "P1", pos: {10, 10}, dir: :e}})

      result = Lenies.Worlds.action(world_id, {:write_child, 0, 0, "P1"})
      assert result == {:ok, :no_slot}
    end
  end

  describe "divide" do
    setup %{world_id: world_id, handle: h} do
      # Ensure copy errors are off
      original_min_viable = Application.get_env(:lenies, :min_viable_codeome_opcodes)

      Application.put_env(:lenies, :copy_substitution_rate, 0.0)
      Application.put_env(:lenies, :copy_insert_rate, 0.0)
      Application.put_env(:lenies, :copy_delete_rate, 0.0)
      Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)

      on_exit(fn ->
        if original_min_viable do
          Application.put_env(:lenies, :min_viable_codeome_opcodes, original_min_viable)
        else
          Application.delete_env(:lenies, :min_viable_codeome_opcodes)
        end
      end)

      # Parent already has an allocated slot — populate it with a real Codeome
      {:ok, {:allocated, slot_id, _}} =
        Lenies.Worlds.action(world_id, {:allocate, 5, {10, 10}, :e, "P1"})

      cs = h.tables.child_slots
      :ok = ChildSlots.set_opcode(cs, slot_id, 0, :nop_1)
      :ok = ChildSlots.set_opcode(cs, slot_id, 1, :sense_front)
      :ok = ChildSlots.set_opcode(cs, slot_id, 2, :drop)
      :ok = ChildSlots.set_opcode(cs, slot_id, 3, :eat)
      :ok = ChildSlots.set_opcode(cs, slot_id, 4, :nop_0)

      %{slot_id: slot_id, handle: h}
    end

    test "successful :divide spawns child Lenie, transfers half energy, clears slot", %{
      world_id: world_id,
      slot_id: slot_id,
      handle: h
    } do
      result = Lenies.Worlds.action(world_id, {:divide, 100.0, {10, 10}, :e, "P1"})
      assert {:ok, {:divided, child_id, energy_given}} = result
      assert is_binary(child_id)
      # floor(100 / 2)
      assert energy_given == 50

      # child slot deleted from :child_slots
      assert ChildSlots.get(h.tables.child_slots, slot_id) == :not_found

      # child registered as Lenie process under tuple key
      [{child_pid, _}] = Registry.lookup(Lenies.Registry, {:lenie, world_id, child_id})
      assert is_pid(child_pid)
      assert Process.alive?(child_pid)

      # child cell occupied
      [{_, cell}] = :ets.lookup(h.tables.cells, {11, 10})
      assert cell.lenie_id == child_id

      # parent's child_slot_id cleared
      [{"P1", record}] = :ets.lookup(h.tables.lenies, "P1")
      assert Map.get(record, :child_slot_id) == nil

      Process.unlink(child_pid)
      GenServer.stop(child_pid)
    end

    test "fails if target cell now occupied",
         %{world_id: world_id, slot_id: _slot_id, handle: h} do
      [{key, cell}] = :ets.lookup(h.tables.cells, {11, 10})
      :ets.insert(h.tables.cells, {key, %{cell | lenie_id: "BLOCKER"}})

      result = Lenies.Worlds.action(world_id, {:divide, 100.0, {10, 10}, :e, "P1"})
      assert result == {:ok, :target_blocked}
    end

    test "fails if no slot allocated", %{world_id: world_id, handle: h} do
      :ets.delete(h.tables.lenies, "P1")
      :ets.insert(h.tables.lenies, {"P1", %{id: "P1", pos: {10, 10}, dir: :e}})

      result = Lenies.Worlds.action(world_id, {:divide, 100.0, {10, 10}, :e, "P1"})
      assert result == {:ok, :no_slot}
    end
  end

  describe "Lenie + :allocate end-to-end" do
    test "Lenie that executes :allocate gets success pushed on stack",
         %{handle: handle} do
      # Codeome: build size 5 on stack via :push1 + :add, then :allocate
      # Push 1 five times then add four times → 5 on stack
      codeome =
        Lenies.Codeome.from_list([
          :push1,
          :push1,
          :add,
          :push1,
          :add,
          :push1,
          :add,
          :push1,
          :add,
          :allocate,
          :nop_0
        ])

      {:ok, pid} =
        Lenies.Lenie.start_link(
          {handle,
           [
             id: "P1",
             codeome: codeome,
             energy: 10_000.0,
             pos: {10, 10},
             dir: :e,
             lineage: {nil, 0}
           ]}
        )

      Process.unlink(pid)
      Process.sleep(200)

      # After :allocate succeeded, a child slot for "P1" should exist in :child_slots
      slots = :ets.tab2list(handle.tables.child_slots)
      assert Enum.any?(slots, fn {_id, slot} -> slot.parent_id == "P1" end)

      GenServer.stop(pid)
    end
  end
end
