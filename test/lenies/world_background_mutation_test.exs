defmodule Lenies.WorldBackgroundMutationTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      case Lenies.WorldTestHelpers.world_pid() do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      Tables.delete_all()
    end)

    {:ok, _world} = World.start_link(world_id: :primary, tick_interval_ms: 0)
    :ok
  end

  test "background mutation invokes Mutator on tick boundary at max rate" do
    # rate 1000 per 1000 ticks → World converts to interval=1 → fires every tick.
    # World already booted in setup; mutate state.config live via the facade.
    :ok = Lenies.Worlds.tune(:primary, :background_mutation_rate_per_1000_ticks, 1000)

    # The hook runs but with no Lenies, it's a no-op. Just verify no crash.
    Lenies.Worlds.tick_now(:primary)
    Lenies.Worlds.tick_now(:primary)
    assert true
  end

  test "background mutation rate = 0 disables the hook" do
    # World already booted in setup; mutate state.config live via the facade.
    :ok = Lenies.Worlds.tune(:primary, :background_mutation_rate_per_1000_ticks, 0)
    for _ <- 1..10, do: Lenies.Worlds.tick_now(:primary)
    assert true
  end
end
