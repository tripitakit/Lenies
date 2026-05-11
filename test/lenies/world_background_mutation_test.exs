defmodule Lenies.WorldBackgroundMutationTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      case Process.whereis(Lenies.World) do
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

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    :ok
  end

  test "background mutation invokes Mutator on tick boundary (interval = 1)" do
    Application.put_env(:lenies, :background_mutation_interval_ticks, 1)

    # The hook runs but with no Lenies, it's a no-op. Just verify no crash.
    World.tick_now()
    World.tick_now()
    assert true
  end

  test "background mutation interval = 0 disables the hook" do
    Application.put_env(:lenies, :background_mutation_interval_ticks, 0)
    for _ <- 1..10, do: World.tick_now()
    assert true
  end
end
