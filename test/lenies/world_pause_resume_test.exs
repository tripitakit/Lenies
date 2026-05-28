defmodule Lenies.WorldPauseResumeTest do
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

    :ok
  end

  test "pause/0 stops tick_count from advancing" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    World.tick_now()
    World.tick_now()
    stats_before = World.snapshot_stats()
    assert stats_before.tick_count == 2

    :ok = World.pause()
    assert World.paused?() == true

    :ok = World.resume()
    assert World.paused?() == false
  end

  test "resume/0 restarts auto-tick" do
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
    {:ok, _world} = World.start_link(tick_interval_ms: 50)

    assert_receive {:tick, 1}, 500

    :ok = World.pause()

    receive do
      {:tick, _} -> :ok
    after
      0 -> :ok
    end

    refute_receive {:tick, _}, 200

    :ok = World.resume()
    assert_receive {:tick, _}, 500
  end
end
