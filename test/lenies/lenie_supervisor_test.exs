defmodule Lenies.LenieSupervisorTest do
  use ExUnit.Case, async: false

  alias Lenies.WorldTestHelpers

  setup do
    {:ok, world_id} = WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    on_exit(fn -> WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id}
  end

  test "starts as DynamicSupervisor with zero children", %{world_id: world_id} do
    pid = WorldTestHelpers.lenie_sup_pid(world_id)
    assert is_pid(pid)
    assert Process.alive?(pid)

    counts = DynamicSupervisor.count_children(Lenies.LenieSupervisor.via(world_id))
    assert counts.specs == 0
    assert counts.active == 0
  end
end
