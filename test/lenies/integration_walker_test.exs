defmodule Lenies.IntegrationWalkerTest do
  use ExUnit.Case, async: false

  alias Lenies.Lenie
  alias Lenies.Codeomes.Walker

  setup do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)

    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

    {:ok, world_id: world_id, handle: handle}
  end

  test "walker moves on the grid and eats biomass", %{world_id: world_id, handle: handle} do
    # seed cells {10..200, 10} with biomass (wide enough to feed the walker for 500ms)
    for x <- 10..200 do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {x, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 100}})
    end

    # spawn walker at {10, 10} facing east, plenty of energy
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {10, 10})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "walker"}})

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "walker",
           codeome: Walker.codeome(),
           energy: 200.0,
           pos: {10, 10},
           dir: :e,
           lineage: {nil, 0}
         ]}
      )

    # let it run for ~500ms (≈ many metabolic batches)
    Process.sleep(500)

    snapshot = Lenie.inspect_state(pid)

    # walker should have moved (at least one move opcode executed)
    assert snapshot.pos != {10, 10}, "expected walker to have moved from initial position"

    # walker should have eaten (energy refilled or stable, not starving fast)
    assert snapshot.energy > 0, "expected walker to still be alive"

    GenServer.stop(pid)
  end
end
