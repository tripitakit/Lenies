defmodule Lenies.WorldTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      case Process.whereis(Lenies.World) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: GenServer.stop(pid)
      end

      Tables.delete_all()
    end)

    :ok
  end

  test "starts and initializes ETS tables with 65_536 empty cells" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)
    assert :ets.info(:cells, :size) == 65_536
    [{{0, 0}, cell}] = :ets.lookup(:cells, {0, 0})
    assert cell.resource == 0
    assert cell.lenie_id == nil
    assert cell.carcass == 0
  end

  test "snapshot_stats/0 returns basic counts on empty world" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)
    stats = World.snapshot_stats()
    assert stats.cells == 65_536
    assert stats.population == 0
    assert stats.total_resource == 0
    assert stats.total_carcass == 0
  end

  test "tick_now/0 applies radiation to cells" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)
    stats_before = World.snapshot_stats()
    assert stats_before.total_resource == 0

    World.tick_now()
    stats_after = World.snapshot_stats()
    # radiation_per_tick default (config/runtime.exs)
    assert stats_after.total_resource == 1000
    assert stats_after.tick_count == 1
  end

  test "tick_now/0 caps total resource at grid_size × cell_resource_cap" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)
    max_total = 65_536 * 100

    # 1000 tick → 100_000 unità versate (ben sotto il cap globale)
    for _ <- 1..1000, do: World.tick_now()

    stats = World.snapshot_stats()
    assert stats.total_resource <= max_total
    assert stats.tick_count == 1000
  end

  test "auto-tick fires at the configured interval" do
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
    {:ok, _pid} = World.start_link(tick_interval_ms: 50)

    assert_receive {:tick, 1}, 500
    assert_receive {:tick, 2}, 500
  end

  test "tick_now/0 decays carcasses by configured rate" do
    Application.put_env(:lenies, :carcass_decay, 0.05)

    on_exit(fn -> Application.put_env(:lenies, :carcass_decay, 0) end)

    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    # iniettiamo una carcassa manualmente in una cella
    [{key, cell}] = :ets.lookup(:cells, {10, 10})
    :ets.insert(:cells, {key, %{cell | carcass: 100}})

    World.tick_now()

    [{_, after_cell}] = :ets.lookup(:cells, {10, 10})
    # 5% decay → 100 → 95
    assert after_cell.carcass == 95
  end

  test "tick_now/0 floors carcass at 0 over many ticks" do
    Application.put_env(:lenies, :carcass_decay, 0.05)

    on_exit(fn -> Application.put_env(:lenies, :carcass_decay, 0) end)

    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | carcass: 10}})

    for _ <- 1..200, do: World.tick_now()

    [{_, after_cell}] = :ets.lookup(:cells, {5, 5})
    assert after_cell.carcass == 0
  end
end
