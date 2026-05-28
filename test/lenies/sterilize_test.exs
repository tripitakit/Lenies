defmodule Lenies.SterilizeTest do
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

  test "sterilize/0 clears all ETS data, resets tick_count, broadcasts event" do
    {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 0)

    for _ <- 1..10, do: Lenies.Worlds.tick_now(:primary)
    before_stats = Lenies.Worlds.snapshot_stats(:primary)
    assert before_stats.tick_count == 10
    assert before_stats.total_resource > 0

    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:primary:control")
    :ok = Lenies.Worlds.sterilize(:primary)

    assert_receive {:sterilized, _ts}, 500

    after_stats = Lenies.Worlds.snapshot_stats(:primary)
    assert after_stats.tick_count == 0
    assert after_stats.total_resource == 0
    assert after_stats.cells == 65_536
  end

  test "sterilize/0 is idempotent" do
    {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 0)
    assert :ok = Lenies.Worlds.sterilize(:primary)
    assert :ok = Lenies.Worlds.sterilize(:primary)
    assert Lenies.Worlds.snapshot_stats(:primary).tick_count == 0
  end
end
