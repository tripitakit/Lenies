defmodule Lenies.SandboxesTest do
  use ExUnit.Case, async: false

  describe "world_id_for/1" do
    test "wraps a user id as a {:sandbox, id} tuple" do
      assert Lenies.Sandboxes.world_id_for(42) == {:sandbox, 42}
      assert Lenies.Sandboxes.world_id_for(1) == {:sandbox, 1}
    end
  end

  describe "attach/1 — first attach" do
    test "starts the user's sandbox world and registers the caller" do
      user_id = unique_user_id()
      assert :ok = Lenies.Sandboxes.attach(user_id)
      assert Lenies.Worlds.alive?({:sandbox, user_id})
      # cleanup
      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end

    test "second attach shares the same world, registers both pids" do
      user_id = unique_user_id()
      assert :ok = Lenies.Sandboxes.attach(user_id)

      task = Task.async(fn ->
        :ok = Lenies.Sandboxes.attach(user_id)
        receive do {:exit, parent} -> send(parent, :done) end
      end)

      # Give the task time to register.
      Process.sleep(50)

      state = :sys.get_state(Lenies.Sandboxes)
      entry = state[user_id]
      assert MapSet.size(entry.connections) == 2

      # cleanup the task
      send(task.pid, {:exit, self()})
      assert_receive :done, 1_000
      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end
  end

  describe "detach via :DOWN" do
    test "last pid disconnect schedules a grace timer; world still running" do
      user_id = unique_user_id()
      task =
        Task.async(fn ->
          :ok = Lenies.Sandboxes.attach(user_id)
          receive do :exit -> :ok end
        end)
      Process.sleep(50)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(100)

      state = :sys.get_state(Lenies.Sandboxes)
      entry = state[user_id]
      assert MapSet.size(entry.connections) == 0
      refute is_nil(entry.pending_stop), "expected a pending_stop timer ref"
      assert Lenies.Worlds.alive?({:sandbox, user_id}), "world must still be running during grace"

      # cleanup
      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end

    test "one pid disconnect of two does NOT schedule a grace timer" do
      user_id = unique_user_id()
      :ok = Lenies.Sandboxes.attach(user_id)

      task =
        Task.async(fn ->
          :ok = Lenies.Sandboxes.attach(user_id)
          receive do :exit -> :ok end
        end)
      Process.sleep(50)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(100)

      state = :sys.get_state(Lenies.Sandboxes)
      entry = state[user_id]
      assert MapSet.size(entry.connections) == 1
      assert is_nil(entry.pending_stop)

      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end
  end

  describe ":maybe_stop" do
    setup do
      # Speed up grace period for tests so we don't wait 30 s.
      Application.put_env(:lenies, :sandbox_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :sandbox_grace_ms) end)
      :ok
    end

    test "grace expires with no re-attach: world stops, entry removed" do
      user_id = unique_user_id()
      task =
        Task.async(fn ->
          :ok = Lenies.Sandboxes.attach(user_id)
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      # Wait grace (50 ms) plus a safety margin.
      Process.sleep(200)

      refute Lenies.Worlds.alive?({:sandbox, user_id}),
             "expected world to stop after grace expiry"
      state = :sys.get_state(Lenies.Sandboxes)
      refute Map.has_key?(state, user_id),
             "expected sandbox entry to be removed"
    end

    test "re-attach during grace cancels the timer and keeps the world" do
      user_id = unique_user_id()
      task1 =
        Task.async(fn ->
          :ok = Lenies.Sandboxes.attach(user_id)
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task1.pid, :exit)
      Task.await(task1)
      Process.sleep(10)  # 10 ms into the 50 ms grace

      # Re-attach
      :ok = Lenies.Sandboxes.attach(user_id)
      Process.sleep(200)  # Past the original grace window

      assert Lenies.Worlds.alive?({:sandbox, user_id}),
             "expected world to survive after re-attach"
      # cleanup
      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end
  end

  describe "auto-restore" do
    setup do
      Application.put_env(:lenies, :sandbox_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :sandbox_grace_ms) end)
      :ok
    end

    @tag :tmp_dir
    test "first attach restores from an existing auto snapshot", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      user_id = unique_user_id()
      world_id = {:sandbox, user_id}

      # 1) Attach, plant a marker, detach explicitly, wait past grace.
      :ok = Lenies.Sandboxes.attach(user_id)
      {:ok, handle1} = Lenies.Worlds.handle(world_id)
      Lenies.SpeciesColor.set_override(handle1, "auto-marker", "#abcdef")

      :ok = Lenies.Sandboxes.detach(user_id)
      # Grace is 50ms, but the :maybe_stop handler runs auto_save synchronously
      # (writing 5 ETS tables to disk) before stop_world. Allow generous time.
      Process.sleep(1_000)
      refute Lenies.Worlds.alive?(world_id)

      # 2) Re-attach in a separate context; the marker should be restored.
      :ok = Lenies.Sandboxes.attach(user_id)
      {:ok, handle2} = Lenies.Worlds.handle(world_id)
      assert Lenies.SpeciesColor.override(handle2, "auto-marker") == "#abcdef"

      :ok = Lenies.Worlds.stop_world(world_id)
    end

    @tag :tmp_dir
    test "first attach with NO auto snapshot starts an empty world", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      user_id = unique_user_id()
      world_id = {:sandbox, user_id}

      :ok = Lenies.Sandboxes.attach(user_id)
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      assert :ets.tab2list(handle.tables.lenies) == []
      :ok = Lenies.Worlds.stop_world(world_id)
    end

    @tag :tmp_dir
    test "corrupt auto snapshot is quarantined, world starts empty", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      user_id = unique_user_id()
      world_id = {:sandbox, user_id}

      # Create a fake auto/ directory with garbage to make validate/2 fail.
      auto_dir = Path.join([tmp, Lenies.Worlds.id_to_path(world_id), "auto"])
      File.mkdir_p!(auto_dir)
      File.write!(Path.join(auto_dir, "cells.tab"), "not a real ets dump")

      :ok = Lenies.Sandboxes.attach(user_id)
      # World started (empty), and the auto/ has been renamed away.
      refute File.dir?(auto_dir)
      # An auto.broken.<ts>/ should exist alongside.
      broken_dirs =
        Path.join([tmp, Lenies.Worlds.id_to_path(world_id)])
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "auto.broken."))
      assert length(broken_dirs) == 1

      :ok = Lenies.Worlds.stop_world(world_id)
    end
  end

  describe "crash recovery / adopt" do
    test "on init, adopts running {:sandbox, _} worlds and broadcasts sandboxes:manager_up" do
      # The Application-supervised Sandboxes is already running. Start a sandbox
      # under it, then kill the manager and verify the new instance adopts the
      # running world and broadcasts.
      user_id = unique_user_id()
      :ok = Lenies.Sandboxes.attach(user_id)
      assert Lenies.Worlds.alive?({:sandbox, user_id})

      Phoenix.PubSub.subscribe(Lenies.PubSub, "sandboxes:manager_up")
      pid = Process.whereis(Lenies.Sandboxes)
      Process.exit(pid, :kill)

      assert_receive :sandboxes_manager_up, 1_000

      # Adopted: the state has an entry for user_id with empty connections and
      # a pending stop timer.
      Process.sleep(50)
      state = :sys.get_state(Lenies.Sandboxes)
      assert Map.has_key?(state, user_id)
      assert MapSet.size(state[user_id].connections) == 0
      refute is_nil(state[user_id].pending_stop)

      # cleanup
      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end
  end

  describe "auto-restore round-trip (integration)" do
    @moduletag :integration

    @tag :tmp_dir
    test "spawn lenies, detach, wait grace, re-attach: lenies restored", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      Application.put_env(:lenies, :sandbox_grace_ms, 50)
      on_exit(fn ->
        Application.delete_env(:lenies, :snapshot_root)
        Application.delete_env(:lenies, :sandbox_grace_ms)
      end)

      user_id = unique_user_id()
      world_id = {:sandbox, user_id}

      :ok = Lenies.Sandboxes.attach(user_id)
      {:ok, handle1} = Lenies.Worlds.handle(world_id)

      # Spawn 3 lenies of the minimal_replicator seed.
      %{codeome: codeome, default_options: opts} = Lenies.Seeds.get(:minimal_replicator)
      energy = Map.get(opts, :energy, 500.0)
      for _ <- 1..3, do: Lenies.Worlds.spawn_lenie(world_id, codeome, energy: energy)
      Process.sleep(50)

      lenies_before = :ets.tab2list(handle1.tables.lenies)
      assert length(lenies_before) >= 3

      # Detach + wait past grace (with safety margin for auto_save IO).
      :ok = Lenies.Sandboxes.detach(user_id)
      Process.sleep(1_000)
      refute Lenies.Worlds.alive?(world_id)

      # Re-attach — auto-restore brings the lenies back.
      :ok = Lenies.Sandboxes.attach(user_id)
      {:ok, handle2} = Lenies.Worlds.handle(world_id)
      lenies_after = :ets.tab2list(handle2.tables.lenies)
      assert length(lenies_after) == length(lenies_before)

      :ok = Lenies.Worlds.stop_world(world_id)
    end
  end

  describe "concurrent users (smoke)" do
    @moduletag :integration

    test "5 users get 5 distinct worlds; all stop cleanly" do
      Application.put_env(:lenies, :sandbox_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :sandbox_grace_ms) end)

      user_ids = for _ <- 1..5, do: unique_user_id()

      for user_id <- user_ids do
        :ok = Lenies.Sandboxes.attach(user_id)
      end

      for user_id <- user_ids do
        assert Lenies.Worlds.alive?({:sandbox, user_id})
      end

      # Detach all + wait past grace (with safety margin)
      for user_id <- user_ids, do: Lenies.Sandboxes.detach(user_id)
      Process.sleep(1_000)

      for user_id <- user_ids do
        refute Lenies.Worlds.alive?({:sandbox, user_id})
      end
    end
  end

  defp unique_user_id, do: :erlang.unique_integer([:positive])
end
