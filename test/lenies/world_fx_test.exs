defmodule Lenies.WorldFxTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, WorldTestHelpers}
  alias Lenies.World.ChildSlots

  setup do
    {:ok, world_id} = WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    on_exit(fn -> WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{handle.pubsub_prefix}:fx")
    {:ok, world_id: world_id, handle: handle}
  end

  test "natural death broadcasts :death", %{world_id: world_id} do
    cod = Codeome.from_list([:nop_0, :nop_0, :nop_0])
    {:ok, {id, _pos}} = Lenies.Worlds.spawn_lenie(world_id, cod, energy: 50.0)
    [{pid, _}] = Registry.lookup(Lenies.Registry, {:lenie, world_id, id})
    Process.unlink(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:death, %{x: _, y: _, hue: _}}, 1000
  end

  test "sterilize does NOT broadcast :death", %{world_id: world_id} do
    cod = Codeome.from_list([:nop_0, :nop_0, :nop_0])
    {:ok, _} = Lenies.Worlds.spawn_lenie(world_id, cod, energy: 500.0)
    :ok = Lenies.Worlds.sterilize(world_id)
    refute_receive {:death, _}, 300
  end

  test "division broadcasts :division", %{world_id: world_id, handle: handle} do
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)

    on_exit(fn ->
      Application.delete_env(:lenies, :min_viable_codeome_opcodes)
    end)

    # Set up a fake parent lenie at (10, 10) facing east
    [{key, cell}] = :ets.lookup(handle.tables.cells, {10, 10})
    :ets.insert(handle.tables.cells, {key, %{cell | lenie_id: "P1"}})

    :ets.insert(
      handle.tables.lenies,
      {"P1", %{id: "P1", pid: self(), pos: {10, 10}, dir: :e, codeome_hash: nil}}
    )

    # Allocate slot for child at (11, 10)
    {:ok, {:allocated, slot_id, _}} =
      Lenies.Worlds.action(world_id, {:allocate, 5, {10, 10}, :e, "P1"})

    # Write a viable child codeome (non-nop opcodes)
    cs = handle.tables.child_slots
    :ok = ChildSlots.set_opcode(cs, slot_id, 0, :nop_1)
    :ok = ChildSlots.set_opcode(cs, slot_id, 1, :sense_front)
    :ok = ChildSlots.set_opcode(cs, slot_id, 2, :drop)
    :ok = ChildSlots.set_opcode(cs, slot_id, 3, :eat)
    :ok = ChildSlots.set_opcode(cs, slot_id, 4, :nop_0)

    # Trigger divide
    result = Lenies.Worlds.action(world_id, {:divide, 100.0, {10, 10}, :e, "P1"})
    assert {:ok, {:divided, child_id, _energy}} = result

    assert_receive {:division, %{x: _, y: _, hue: _}}, 1000

    # Cleanup the child
    case Registry.lookup(Lenies.Registry, {:lenie, world_id, child_id}) do
      [{child_pid, _}] ->
        Process.unlink(child_pid)
        GenServer.stop(child_pid)

      _ ->
        :ok
    end
  end

  test "attack broadcasts :predation", %{world_id: world_id, handle: handle} do
    # Spawn a real target Lenie
    codeome = Codeome.from_list([:nop_0, :nop_0, :nop_0])

    # Set up attacker record at (10, 10)
    [{key, cell}] = :ets.lookup(handle.tables.cells, {10, 10})
    :ets.insert(handle.tables.cells, {key, %{cell | lenie_id: "P1"}})

    :ets.insert(
      handle.tables.lenies,
      {"P1", %{id: "P1", pid: self(), pos: {10, 10}, dir: :e}}
    )

    # Mark target cell occupied
    [{tkey, tcell}] = :ets.lookup(handle.tables.cells, {11, 10})
    :ets.insert(handle.tables.cells, {tkey, %{tcell | lenie_id: "T1"}})

    {:ok, target_pid} =
      Lenies.Lenie.start_link(
        {handle,
         [
           id: "T1",
           codeome: codeome,
           energy: 1000.0,
           pos: {11, 10},
           dir: :w,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(target_pid)
    # Give the Lenie time to write its initial snapshot
    Process.sleep(50)

    # Issue attack from P1 at (10, 10) facing east → hits T1 at (11, 10)
    result = Lenies.Worlds.action(world_id, {:attack, {10, 10}, :e, "P1"})
    assert {:ok, {:attacked, _damage}} = result

    assert_receive {:predation, %{x: _, y: _}}, 1000

    if Process.alive?(target_pid), do: GenServer.stop(target_pid)
  end
end
