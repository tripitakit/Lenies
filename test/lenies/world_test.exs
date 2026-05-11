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
end
