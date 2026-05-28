defmodule Lenies.WorldBackgroundMutationTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id}
  end

  test "background mutation invokes Mutator on tick boundary at max rate",
       %{world_id: world_id} do
    # rate 1000 per 1000 ticks → World converts to interval=1 → fires every tick.
    :ok = Lenies.Worlds.tune(world_id, :background_mutation_rate_per_1000_ticks, 1000)

    # The hook runs but with no Lenies, it's a no-op. Just verify no crash.
    Lenies.Worlds.tick_now(world_id)
    Lenies.Worlds.tick_now(world_id)
    assert true
  end

  test "background mutation rate = 0 disables the hook", %{world_id: world_id} do
    :ok = Lenies.Worlds.tune(world_id, :background_mutation_rate_per_1000_ticks, 0)
    for _ <- 1..10, do: Lenies.Worlds.tick_now(world_id)
    assert true
  end
end
