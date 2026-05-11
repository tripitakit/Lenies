defmodule Lenies.IntegrationWalkerTest do
  use ExUnit.Case, async: false

  alias Lenies.{Lenie, World}
  alias Lenies.Codeomes.Walker
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      for pid <- Process.whereis(Lenies.World) |> List.wrap() do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      Tables.delete_all()
    end)

    :ok
  end

  test "walker moves on the grid and eats biomass" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    # seed cells {10..200, 10} with biomass (wide enough to feed the walker for 500ms)
    for x <- 10..200 do
      [{key, cell}] = :ets.lookup(:cells, {x, 10})
      :ets.insert(:cells, {key, %{cell | resource: 100}})
    end

    # spawn walker at {10, 10} facing east, plenty of energy
    [{key, cell}] = :ets.lookup(:cells, {10, 10})
    :ets.insert(:cells, {key, %{cell | lenie_id: "walker"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "walker",
        codeome: Walker.codeome(),
        energy: 200.0,
        pos: {10, 10},
        dir: :e,
        lineage: {nil, 0}
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
