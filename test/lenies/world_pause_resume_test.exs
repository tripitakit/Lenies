defmodule Lenies.WorldPauseResumeTest do
  use ExUnit.Case, async: false

  test "pause/0 stops tick_count from advancing" do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

    Lenies.Worlds.tick_now(world_id)
    Lenies.Worlds.tick_now(world_id)
    stats_before = Lenies.Worlds.snapshot_stats(world_id)
    assert stats_before.tick_count == 2

    :ok = Lenies.Worlds.pause(world_id)
    assert Lenies.Worlds.paused?(world_id) == true

    :ok = Lenies.Worlds.resume(world_id)
    assert Lenies.Worlds.paused?(world_id) == false
  end

  test "resume/0 restarts auto-tick" do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 50)
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

    Phoenix.PubSub.subscribe(Lenies.PubSub, handle.pubsub_prefix <> ":tick")

    assert_receive {:tick, _, _}, 500

    :ok = Lenies.Worlds.pause(world_id)

    receive do
      {:tick, _, _} -> :ok
    after
      0 -> :ok
    end

    refute_receive {:tick, _, _}, 200

    :ok = Lenies.Worlds.resume(world_id)
    assert_receive {:tick, _, _}, 500
  end
end
