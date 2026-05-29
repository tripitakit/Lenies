defmodule Lenies.ArenaTest do
  use ExUnit.Case, async: false

  describe "seeder_user_id propagation through replication" do
    setup do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
      %{world_id: world_id, handle: handle}
    end

    test "child Lenie inherits parent's seeder_user_id when replication occurs",
         %{world_id: world_id, handle: handle} do
      # Spawn a replicator tagged with seeder_user_id=7. Drive a few ticks
      # so it replicates at least once.
      codeome = Lenies.Seeds.get(:minimal_replicator).codeome

      {:ok, {parent_id, _pos}} =
        Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 10_000.0, seeder_user_id: 7)

      # Drive enough ticks to allow at least one allocate→gestation→spawn cycle.
      # Children eventually starve and disappear from ETS, so we poll and stop as
      # soon as we observe parent + ≥ 1 child simultaneously. This captures the
      # in-flight snapshot for the assertion below.
      for _ <- 1..50 do
        :ok = Lenies.Worlds.tick_now(world_id)
      end

      lenies =
        Enum.reduce_while(1..200, [], fn _i, _acc ->
          rows = :ets.tab2list(handle.tables.lenies)

          if length(rows) >= 2 do
            {:halt, rows}
          else
            Process.sleep(20)
            {:cont, rows}
          end
        end)

      assert length(lenies) >= 2, "expected at least parent + one child; got #{length(lenies)}"

      # Every Lenie in this world (including children) must carry seeder_user_id=7.
      for {_id, snap} <- lenies do
        assert snap.seeder_user_id == 7,
               "child Lenie missing seeder_user_id; got #{inspect(snap.seeder_user_id)}"
      end

      refute parent_id in [], "sanity: parent was spawned"
    end
  end

  describe "Lenies.Arena lifecycle" do
    setup do
      start_supervised!({Lenies.Arena, []})
      :ok
    end

    test "first attach_viewer starts the :arena world" do
      :ok = Lenies.Arena.attach_viewer(self())
      assert Lenies.Worlds.alive?(:arena)
      :ok = Lenies.Worlds.stop_world(:arena)
    end

    test "last viewer disconnect schedules grace timer; world still alive" do
      task =
        Task.async(fn ->
          :ok = Lenies.Arena.attach_viewer()
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(100)

      state = :sys.get_state(Lenies.Arena)
      assert MapSet.size(state.viewers) == 0
      refute is_nil(state.pending_stop)
      assert Lenies.Worlds.alive?(:arena)
      :ok = Lenies.Worlds.stop_world(:arena)
    end

    test "second viewer disconnect leaves first viewer attached, no grace timer" do
      :ok = Lenies.Arena.attach_viewer(self())
      task =
        Task.async(fn ->
          :ok = Lenies.Arena.attach_viewer()
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(100)

      state = :sys.get_state(Lenies.Arena)
      assert MapSet.size(state.viewers) == 1
      assert is_nil(state.pending_stop)
      :ok = Lenies.Worlds.stop_world(:arena)
    end

    test "explicit detach_viewer also schedules grace timer when last viewer leaves" do
      :ok = Lenies.Arena.attach_viewer(self())
      :ok = Lenies.Arena.detach_viewer(self())
      Process.sleep(50)

      state = :sys.get_state(Lenies.Arena)
      assert MapSet.size(state.viewers) == 0
      refute is_nil(state.pending_stop)
      :ok = Lenies.Worlds.stop_world(:arena)
    end

    test "grace expires with no re-attach: world stops, state resets" do
      Application.put_env(:lenies, :arena_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :arena_grace_ms) end)

      task =
        Task.async(fn ->
          :ok = Lenies.Arena.attach_viewer()
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(200)

      refute Lenies.Worlds.alive?(:arena)
      state = :sys.get_state(Lenies.Arena)
      assert state.started? == false
      assert MapSet.size(state.viewers) == 0
    end

    test "re-attach during grace cancels the timer and keeps the world alive" do
      Application.put_env(:lenies, :arena_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :arena_grace_ms) end)

      task =
        Task.async(fn ->
          :ok = Lenies.Arena.attach_viewer()
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(10)  # 10 ms into the 50 ms grace

      :ok = Lenies.Arena.attach_viewer(self())
      Process.sleep(200)  # past the original grace window

      assert Lenies.Worlds.alive?(:arena)
      :ok = Lenies.Worlds.stop_world(:arena)
    end
  end

  describe "auto-restore" do
    setup do
      start_supervised!({Lenies.Arena, []})
      Application.put_env(:lenies, :arena_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :arena_grace_ms) end)
      :ok
    end

    @tag :tmp_dir
    test "first attach restores from an existing auto snapshot", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      :ok = Lenies.Arena.attach_viewer(self())
      {:ok, handle1} = Lenies.Worlds.handle(:arena)
      Lenies.SpeciesColor.set_override(handle1, "arena-marker", "#123456")

      :ok = Lenies.Arena.detach_viewer(self())
      Process.sleep(1_000)  # grace + auto_save
      refute Lenies.Worlds.alive?(:arena)

      :ok = Lenies.Arena.attach_viewer(self())
      {:ok, handle2} = Lenies.Worlds.handle(:arena)
      assert Lenies.SpeciesColor.override(handle2, "arena-marker") == "#123456"

      :ok = Lenies.Worlds.stop_world(:arena)
    end

    @tag :tmp_dir
    test "corrupt auto snapshot is quarantined, world starts empty", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      auto_dir = Path.join([tmp, Lenies.Worlds.id_to_path(:arena), "auto"])
      File.mkdir_p!(auto_dir)
      File.write!(Path.join(auto_dir, "cells.tab"), "garbage, not a valid ets dump")

      :ok = Lenies.Arena.attach_viewer(self())
      refute File.dir?(auto_dir)
      broken =
        Path.join([tmp, Lenies.Worlds.id_to_path(:arena)])
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "auto.broken."))
      assert length(broken) == 1

      :ok = Lenies.Worlds.stop_world(:arena)
    end
  end

  describe "lineage_count/1 and seed/2" do
    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(Lenies.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Lenies.Repo, {:shared, self()})
      start_supervised!({Lenies.Arena, []})
      :ok = Lenies.Arena.attach_viewer(self())
      on_exit(fn -> Lenies.Worlds.stop_world(:arena) end)
      :ok
    end

    test "lineage_count returns 0 when no Lenie carries this user's tag" do
      assert Lenies.Arena.lineage_count(123) == 0
    end

    test "seed/2 with lineage=0 spawns and bumps lineage_count to 1" do
      user = Lenies.AccountsFixtures.user_fixture()

      {:ok, codeome} =
        Lenies.Collection.create_codeome(user, %{
          name: "ArenaSeed",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      assert {:ok, :seeded} = Lenies.Arena.seed(user, codeome.id)
      Process.sleep(50)
      assert Lenies.Arena.lineage_count(user.id) == 1
    end

    test "seed/2 with lineage>0 returns {:error, :lineage_alive, N}" do
      user = Lenies.AccountsFixtures.user_fixture()

      {:ok, codeome} =
        Lenies.Collection.create_codeome(user, %{
          name: "ArenaSeed",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      {:ok, :seeded} = Lenies.Arena.seed(user, codeome.id)
      Process.sleep(50)

      assert {:error, :lineage_alive, 1} = Lenies.Arena.seed(user, codeome.id)
    end

    test "seed/2 returns {:error, :not_found} when codeome_id doesn't belong to user" do
      user = Lenies.AccountsFixtures.user_fixture()
      assert {:error, :not_found} = Lenies.Arena.seed(user, 999_999)
    end
  end
end
