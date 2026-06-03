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

          receive do
            :exit -> :ok
          end
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

          receive do
            :exit -> :ok
          end
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

          receive do
            :exit -> :ok
          end
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

          receive do
            :exit -> :ok
          end
        end)

      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      # 10 ms into the 50 ms grace
      Process.sleep(10)

      :ok = Lenies.Arena.attach_viewer(self())
      # past the original grace window
      Process.sleep(200)

      assert Lenies.Worlds.alive?(:arena)
      :ok = Lenies.Worlds.stop_world(:arena)
    end

    test "arena world starts with :infinity caps so Arena's own lineage rule is the only enforcement" do
      # Arena.start_link is already running under the application supervisor.
      # attach_viewer/1 is the trigger that brings up the :arena world the
      # first time (see arena.ex handle_call({:attach_viewer, _}, _, %{started?: false} = state)).
      Lenies.Worlds.stop_world(:arena)
      :ok = Lenies.Arena.attach_viewer(self())
      # The world start is synchronous within attach_viewer's call path; wait
      # briefly just for ETS publication if needed.
      Process.sleep(50)

      {:ok, handle} = Lenies.Worlds.handle(:arena)
      state = :sys.get_state(handle.pid)

      assert state.config.spawn_cap == :infinity
      assert state.config.replication_cap == :infinity

      :ok = Lenies.Worlds.stop_world(:arena)
    end
  end

  describe "auto-restore" do
    setup do
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
      # grace + auto_save
      Process.sleep(1_000)
      refute Lenies.Worlds.alive?(:arena)

      :ok = Lenies.Arena.attach_viewer(self())
      {:ok, handle2} = Lenies.Worlds.handle(:arena)
      assert Lenies.SpeciesColor.override(handle2, "arena-marker") == "#123456"

      :ok = Lenies.Worlds.stop_world(:arena)
    end

    @tag :tmp_dir
    test "on dormancy the distributed energy is reset to baseline before snapshot",
         %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      :ok = Lenies.Arena.attach_viewer(self())
      {:ok, handle1} = Lenies.Worlds.handle(:arena)

      # Saturate a cell with radiation, as accumulates over a long session.
      :ets.insert(
        handle1.tables.cells,
        {{3, 3}, %Lenies.World.Cell{resource: 255, carcass: 99, carcass_hue: 40}}
      )

      :ok = Lenies.Arena.detach_viewer(self())
      # grace (50 ms) → reset_energy → auto_save → stop
      Process.sleep(1_000)
      refute Lenies.Worlds.alive?(:arena)

      # Re-attach restores; the saturated cell must come back de-saturated.
      :ok = Lenies.Arena.attach_viewer(self())
      {:ok, handle2} = Lenies.Worlds.handle(:arena)
      [{_, cell}] = :ets.lookup(handle2.tables.cells, {3, 3})

      # Carcass is reset (radiation never re-adds it); resource is no longer
      # saturated (it was 255). A couple of ticks may add a little radiation
      # between reset and snapshot, so we assert de-saturation, not exact 0.
      assert cell.carcass == 0
      assert cell.resource < 100

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

  describe "apoptosis/1" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lenies.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Lenies.Repo, {:shared, self()})
      :ok = Lenies.Arena.attach_viewer(self())
      on_exit(fn -> Lenies.Worlds.stop_world(:arena) end)
      :ok
    end

    test "apoptosis on user with lineage=0 returns {:ok, 0}" do
      user = Lenies.AccountsFixtures.user_fixture()
      assert {:ok, 0} = Lenies.Arena.apoptosis(user)
    end

    test "apoptosis on user with lineage>0 kills all their Lenies; seed allowed again" do
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
      assert Lenies.Arena.lineage_count(user.id) == 1

      assert {:ok, 1} = Lenies.Arena.apoptosis(user)
      # allow terminate/2 to run
      Process.sleep(100)
      assert Lenies.Arena.lineage_count(user.id) == 0

      # Now seed again succeeds.
      assert {:ok, :seeded} = Lenies.Arena.seed(user, codeome.id)
    end

    test "apoptosis only affects the calling user's Lenies; other users untouched" do
      user_a = Lenies.AccountsFixtures.user_fixture()
      user_b = Lenies.AccountsFixtures.user_fixture()

      {:ok, codeome_a} =
        Lenies.Collection.create_codeome(user_a, %{
          name: "A",
          color_hex: "#aa0000",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      {:ok, codeome_b} =
        Lenies.Collection.create_codeome(user_b, %{
          name: "B",
          color_hex: "#00aa00",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      {:ok, :seeded} = Lenies.Arena.seed(user_a, codeome_a.id)
      {:ok, :seeded} = Lenies.Arena.seed(user_b, codeome_b.id)
      Process.sleep(50)

      assert {:ok, 1} = Lenies.Arena.apoptosis(user_a)
      Process.sleep(100)
      assert Lenies.Arena.lineage_count(user_a.id) == 0
      assert Lenies.Arena.lineage_count(user_b.id) == 1
    end

    test "natural death of a Lenie broadcasts arena:lineage_changed via PubSub" do
      user = Lenies.AccountsFixtures.user_fixture()

      {:ok, codeome} =
        Lenies.Collection.create_codeome(user, %{
          name: "ArenaSeed",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      Phoenix.PubSub.subscribe(Lenies.PubSub, "arena:user:#{user.id}")

      {:ok, :seeded} = Lenies.Arena.seed(user, codeome.id)
      # The seed itself broadcasts; consume the first message.
      assert_receive {:arena_lineage_changed, user_id}, 1_000
      assert user_id == user.id

      # Now trigger apoptosis (kills user's Lenies) — should also broadcast.
      {:ok, _} = Lenies.Arena.apoptosis(user)
      assert_receive {:arena_lineage_changed, ^user_id}, 1_000
    end
  end

  describe "crash recovery / adopt" do
    test "on init, adopts a running :arena world and broadcasts arena:manager_up" do
      :ok = Lenies.Arena.attach_viewer(self())
      assert Lenies.Worlds.alive?(:arena)

      Phoenix.PubSub.subscribe(Lenies.PubSub, "arena:manager_up")
      pid = Process.whereis(Lenies.Arena)
      Process.exit(pid, :kill)

      assert_receive :arena_manager_up, 1_000

      Process.sleep(50)
      state = :sys.get_state(Lenies.Arena)
      assert state.started? == true
      assert MapSet.size(state.viewers) == 0
      refute is_nil(state.pending_stop)

      :ok = Lenies.Worlds.stop_world(:arena)
    end
  end
end
