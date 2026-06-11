defmodule Lenies.LenieTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Interpreter, Lenie, Plasmid}
  alias Lenies.Interpreter.State

  setup do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id, handle: handle}
  end

  test "start_link/1 registers the Lenie under its id",
       %{world_id: world_id, handle: handle} do
    # mark cell {5,5} as occupied (the Lenie expects to find itself there)
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L1"}})

    codeome = Codeome.from_list([:nop_0, :nop_1])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L1",
           codeome: codeome,
           energy: 50.0,
           pos: {5, 5},
           dir: :e,
           lineage: {nil, 0}
         ]}
      )

    assert Process.alive?(pid)
    assert [{^pid, _}] = Registry.lookup(Lenies.Registry, {:lenie, world_id, "L1"})

    GenServer.stop(pid)
  end

  test "inspect_state/1 returns current snapshot",
       %{world_id: world_id, handle: handle} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L2"}})

    codeome = Codeome.from_list([:nop_0])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L2",
           codeome: codeome,
           energy: 10.0,
           pos: {5, 5},
           dir: :n,
           lineage: {nil, 0}
         ]}
      )

    snapshot = Lenie.inspect_state(pid)
    assert snapshot.id == "L2"
    assert snapshot.energy <= 10.0
    assert snapshot.pos == {5, 5}
    assert snapshot.dir == :n

    GenServer.stop(pid)
  end

  test "dies of starvation when energy depletes",
       %{world_id: world_id, handle: handle} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L3"}})

    # only 0.3 energy — will be consumed by a few nops + age increments
    codeome = Codeome.from_list([:nop_0, :nop_1, :add, :sub])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L3",
           codeome: codeome,
           energy: 0.3,
           pos: {5, 5},
           dir: :n,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(pid)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :starvation}, 1_000

    # cell freed
    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert after_cell.lenie_id == nil
  end

  describe "seeder_user_id propagation (sub-project #4 lineage)" do
    setup do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
      %{world_id: world_id, handle: handle}
    end

    test "Lenie stores seeder_user_id from opts and writes it to its ETS snapshot",
         %{world_id: world_id, handle: handle} do
      codeome = Lenies.Codeomes.MinimalReplicator.codeome()

      {:ok, {id, _pos}} =
        Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0, seeder_user_id: 42)

      # let the Lenie process write its initial snapshot
      Process.sleep(50)

      assert [{^id, snap}] = :ets.lookup(handle.tables.lenies, id)
      assert snap.seeder_user_id == 42
    end

    test "Lenie defaults seeder_user_id to nil when opt is absent",
         %{world_id: world_id, handle: handle} do
      codeome = Lenies.Codeomes.MinimalReplicator.codeome()
      {:ok, {id, _pos}} = Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0)
      Process.sleep(50)

      assert [{^id, snap}] = :ets.lookup(handle.tables.lenies, id)
      assert snap.seeder_user_id == nil
    end
  end

  describe "exec_codeome wiring" do
    test "inspect_state exposes chromosome vs exec sizes, hash, plasmid count",
         %{world_id: world_id, handle: handle} do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "EX1"}})

      codeome = Codeome.from_list([:nop_0, :nop_1, :nop_1])

      {:ok, pid} =
        Lenie.start_link(
          {handle,
           [
             id: "EX1",
             codeome: codeome,
             energy: 50.0,
             pos: {5, 5},
             dir: :e,
             lineage: {nil, 0},
             plasmids: [Lenies.Plasmid.new([:turn_left, :turn_left])],
             paused?: true
           ]}
        )

      snap = GenServer.call(pid, :inspect_state)
      assert snap.codeome_size == 3
      assert snap.exec_codeome_size == 5
      assert snap.plasmid_count == 1
      assert is_binary(snap.codeome_hash)

      GenServer.stop(pid)
    end
  end

  describe "build_exec_codeome/2" do
    test "with no plasmids returns the chromosome unchanged in size" do
      codeome = Codeome.from_list([:nop_0, :nop_1, :nop_1])
      exec = Lenie.build_exec_codeome(codeome, [])
      assert Codeome.size(exec) == 3
    end

    test "appends plasmid opcodes after the chromosome" do
      codeome = Codeome.from_list([:nop_0])
      plasmids = [Plasmid.new([:turn_left, :turn_left])]
      exec = Lenie.build_exec_codeome(codeome, plasmids)
      assert Codeome.size(exec) == 3
      assert Codeome.to_list(exec) == [:nop_0, :turn_left, :turn_left]
    end

    test "plasmid code runs via fall-through (ring) execution" do
      codeome = Codeome.from_list([:nop_0])
      plasmids = [Plasmid.new([:turn_left])]
      exec = Lenie.build_exec_codeome(codeome, plasmids)
      st = State.new(energy: 100.0, dir: :e)
      {:cont, st2} = Interpreter.run_k_instructions(st, exec, 2)
      # ip 0 = :nop_0, ip 1 = :turn_left → from :e a turn_left yields :n
      assert st2.dir == :n
    end
  end

  describe "receive_plasmid (extra-chromosomal)" do
    setup %{world_id: world_id, handle: handle} do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {6, 6})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "RC1"}})

      {:ok, pid} =
        Lenie.start_link(
          {handle,
           [
             id: "RC1",
             codeome: Codeome.from_list([:nop_0, :nop_1, :nop_1]),
             energy: 50.0,
             pos: {6, 6},
             dir: :e,
             lineage: {nil, 0},
             paused?: true
           ]}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, pid: pid}
    end

    test "acquiring a plasmid does not change chromosome hash/size", %{pid: pid} do
      before = GenServer.call(pid, :inspect_state)
      assert :ok = Lenie.receive_plasmid(pid, [:turn_left, :turn_left])
      after_ = GenServer.call(pid, :inspect_state)

      assert after_.codeome_size == before.codeome_size
      assert after_.codeome_hash == before.codeome_hash
      assert after_.exec_codeome_size == before.exec_codeome_size + 2
      assert after_.plasmid_count == 1
    end

    test "acquiring the same plasmid twice is a no-op", %{pid: pid} do
      assert :ok = Lenie.receive_plasmid(pid, [:turn_left])
      assert :already_present = Lenie.receive_plasmid(pid, [:turn_left])
      assert GenServer.call(pid, :inspect_state).plasmid_count == 1
    end

    test "rejects a plasmid that would push exec over the length cap", %{pid: pid} do
      huge = List.duplicate(:nop_0, 2000)
      assert {:error, :too_large} = Lenie.receive_plasmid(pid, huge)
      assert GenServer.call(pid, :inspect_state).plasmid_count == 0
    end
  end

  describe "exec rebuild on self-made plasmid" do
    test "make_plasmid grows the exec stream after the batch",
         %{world_id: world_id, handle: handle} do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {7, 7})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "MP1"}})

      # push0 → start_addr 0; push1; push1; add → length 2; make_plasmid carves
      # opcodes [0,1] into a 2-op plasmid. Chromosome size stays 6; exec grows to 8.
      codeome = Codeome.from_list([:push0, :push1, :push1, :add, :make_plasmid, :nop_0])

      {:ok, pid} =
        Lenie.start_link(
          {handle,
           [
             id: "MP1",
             codeome: codeome,
             energy: 10_000.0,
             pos: {7, 7},
             dir: :e,
             lineage: {nil, 0}
           ]}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      deadline = System.monotonic_time(:millisecond) + 5_000
      grew = wait_for_plasmid(pid, deadline)

      assert grew, "expected make_plasmid to add a plasmid and grow exec within 5s"
      snap = GenServer.call(pid, :inspect_state)
      assert snap.codeome_size == 6
      assert snap.exec_codeome_size > 6
    end
  end

  defp wait_for_plasmid(pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      case GenServer.call(pid, :inspect_state) do
        %{plasmid_count: n} when n > 0 -> true
        _ -> Process.sleep(50); wait_for_plasmid(pid, deadline)
      end
    end
  end
end
