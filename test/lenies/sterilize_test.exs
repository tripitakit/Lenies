defmodule Lenies.SterilizeTest do
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

    :ok
  end

  test "sterilize/0 clears all ETS data, resets tick_count, broadcasts event" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    for _ <- 1..10, do: World.tick_now()
    before_stats = World.snapshot_stats()
    assert before_stats.tick_count == 10
    assert before_stats.total_resource > 0

    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
    :ok = World.sterilize()

    assert_receive {:sterilized, _ts}, 500

    after_stats = World.snapshot_stats()
    assert after_stats.tick_count == 0
    assert after_stats.total_resource == 0
    assert after_stats.cells == 65_536
  end

  test "sterilize/0 is idempotent" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)
    assert :ok = World.sterilize()
    assert :ok = World.sterilize()
    assert World.snapshot_stats().tick_count == 0
  end
end
