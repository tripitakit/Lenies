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
  end
end
