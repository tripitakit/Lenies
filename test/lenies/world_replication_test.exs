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

  describe "write_child" do
    setup do
      # Ensure parent has an allocated slot at this point
      {:ok, {:allocated, slot_id, _}} = World.action({:allocate, 20, {10, 10}, :e, "P1"})
      %{slot_id: slot_id}
    end

    test "writes opcode at addr without mutation when rates are 0", %{slot_id: slot_id} do
      saved_sub = Application.get_env(:lenies, :copy_substitution_rate)
      saved_ins = Application.get_env(:lenies, :copy_insert_rate)
      saved_del = Application.get_env(:lenies, :copy_delete_rate)
      Application.put_env(:lenies, :copy_substitution_rate, 0.0)
      Application.put_env(:lenies, :copy_insert_rate, 0.0)
      Application.put_env(:lenies, :copy_delete_rate, 0.0)

      try do
        move_int = Lenies.Codeome.Opcodes.encode(:move)
        result = World.action({:write_child, move_int, 3, "P1"})
        assert result == {:ok, :written}

        {:ok, slot} = Lenies.World.ChildSlots.get(slot_id)
        assert elem(slot.opcodes, 3) == :move
      after
        Application.put_env(:lenies, :copy_substitution_rate, saved_sub || 0.005)
        Application.put_env(:lenies, :copy_insert_rate, saved_ins || 0.0005)
        Application.put_env(:lenies, :copy_delete_rate, saved_del || 0.0005)
      end
    end

    test "fails when parent has no slot allocated" do
      # remove the child_slot_id by re-inserting the lenies record without it
      :ets.delete(:lenies, "P1")
      :ets.insert(:lenies, {"P1", %{id: "P1", pos: {10, 10}, dir: :e}})

      result = World.action({:write_child, 0, 0, "P1"})
      assert result == {:ok, :no_slot}
    end
  end

  describe "divide" do
    setup do
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
      {:ok, {:allocated, slot_id, _}} = World.action({:allocate, 5, {10, 10}, :e, "P1"})

      # Write valid opcodes into the slot directly via ChildSlots
      :ok = Lenies.World.ChildSlots.set_opcode(slot_id, 0, :nop_1)
      :ok = Lenies.World.ChildSlots.set_opcode(slot_id, 1, :sense_front)
      :ok = Lenies.World.ChildSlots.set_opcode(slot_id, 2, :drop)
      :ok = Lenies.World.ChildSlots.set_opcode(slot_id, 3, :eat)
      :ok = Lenies.World.ChildSlots.set_opcode(slot_id, 4, :nop_0)

      %{slot_id: slot_id}
    end

    test "successful :divide spawns child Lenie, transfers half energy, clears slot", %{
      slot_id: slot_id
    } do
      result = World.action({:divide, 100.0, {10, 10}, :e, "P1"})
      assert {:ok, {:divided, child_id, energy_given}} = result
      assert is_binary(child_id)
      # floor(100 / 2)
      assert energy_given == 50

      # child slot deleted from :child_slots
      assert Lenies.World.ChildSlots.get(slot_id) == :not_found

      # child registered as Lenie process
      child_pid = Lenies.Registry.whereis(child_id)
      assert is_pid(child_pid)
      assert Process.alive?(child_pid)

      # child cell occupied
      [{_, cell}] = :ets.lookup(:cells, {11, 10})
      assert cell.lenie_id == child_id

      # parent's child_slot_id cleared
      [{"P1", record}] = :ets.lookup(:lenies, "P1")
      assert Map.get(record, :child_slot_id) == nil

      Process.unlink(child_pid)
      GenServer.stop(child_pid)
    end

    test "fails if target cell now occupied", %{slot_id: _slot_id} do
      [{key, cell}] = :ets.lookup(:cells, {11, 10})
      :ets.insert(:cells, {key, %{cell | lenie_id: "BLOCKER"}})

      result = World.action({:divide, 100.0, {10, 10}, :e, "P1"})
      assert result == {:ok, :target_blocked}
    end

    test "fails if no slot allocated" do
      :ets.delete(:lenies, "P1")
      :ets.insert(:lenies, {"P1", %{id: "P1", pos: {10, 10}, dir: :e}})

      result = World.action({:divide, 100.0, {10, 10}, :e, "P1"})
      assert result == {:ok, :no_slot}
    end
  end

  describe "Lenie + :allocate end-to-end" do
    test "Lenie that executes :allocate gets success pushed on stack" do
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
          id: "P1",
          codeome: codeome,
          energy: 10_000.0,
          pos: {10, 10},
          dir: :e,
          lineage: {nil, 0}
        )

      Process.unlink(pid)
      Process.sleep(200)

      # After :allocate succeeded, a child slot for "P1" should exist in :child_slots
      slots = :ets.tab2list(:child_slots)
      assert Enum.any?(slots, fn {_id, slot} -> slot.parent_id == "P1" end)

      GenServer.stop(pid)
    end
  end
end
