defmodule Lenies.SandboxesTest do
  use ExUnit.Case, async: false

  describe "world_id_for/1" do
    test "wraps a user id as a {:sandbox, id} tuple" do
      assert Lenies.Sandboxes.world_id_for(42) == {:sandbox, 42}
      assert Lenies.Sandboxes.world_id_for(1) == {:sandbox, 1}
    end
  end

  describe "attach/1 — first attach" do
    setup do
      # Start a fresh Sandboxes manager isolated to this test. Until Task 7
      # adds it to the Application supervision tree, start_supervised! works.
      start_supervised!({Lenies.Sandboxes, []})
      :ok
    end

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

  defp unique_user_id, do: :erlang.unique_integer([:positive])
end
