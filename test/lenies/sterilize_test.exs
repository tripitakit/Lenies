defmodule Lenies.SterilizeTest do
  use ExUnit.Case, async: false

  test "sterilize/0 clears all ETS data, resets tick_count, broadcasts event" do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

    for _ <- 1..10, do: Lenies.Worlds.tick_now(world_id)
    before_stats = Lenies.Worlds.snapshot_stats(world_id)
    assert before_stats.tick_count == 10
    assert before_stats.total_resource > 0

    Phoenix.PubSub.subscribe(Lenies.PubSub, handle.pubsub_prefix <> ":control")
    :ok = Lenies.Worlds.sterilize(world_id)

    assert_receive {:sterilized, _ts}, 500

    after_stats = Lenies.Worlds.snapshot_stats(world_id)
    assert after_stats.tick_count == 0
    assert after_stats.total_resource == 0
    assert after_stats.cells == 16_384
  end

  test "sterilize/0 is idempotent" do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

    assert :ok = Lenies.Worlds.sterilize(world_id)
    assert :ok = Lenies.Worlds.sterilize(world_id)
    assert Lenies.Worlds.snapshot_stats(world_id).tick_count == 0
  end
end
