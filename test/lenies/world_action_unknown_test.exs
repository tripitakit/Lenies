defmodule Lenies.WorldActionUnknownTest do
  use ExUnit.Case, async: false

  test "unknown action descriptor returns {:error, :unknown_action} without crashing World" do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

    pid = Lenies.WorldTestHelpers.world_pid(world_id)
    result = Lenies.Worlds.action(world_id, {:made_up_action, "foo", 42})
    assert result == {:ok, {:error, :unknown_action}}
    assert Process.alive?(pid)
  end
end
