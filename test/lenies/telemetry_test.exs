defmodule Lenies.TelemetryTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      for name <- [Lenies.Telemetry, Lenies.World] do
        case Process.whereis(name) do
          pid when is_pid(pid) ->
            if Process.alive?(pid), do: GenServer.stop(pid)

          _ ->
            :ok
        end
      end

      Tables.delete_all()
    end)

    :ok
  end

  test "records a history entry on each world tick" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    {:ok, _tel} = Lenies.Telemetry.start_link([])

    World.tick_now()
    World.tick_now()
    World.tick_now()

    # tempo di propagazione del PubSub; :sys.get_state/1 drena la mailbox prima
    # di leggere la storia
    Process.sleep(50)
    :sys.get_state(Lenies.Telemetry)

    entries = Lenies.Telemetry.history(:last_n, 10)
    assert length(entries) == 3

    for e <- entries do
      assert is_integer(e.tick)
      assert is_integer(e.population)
      assert is_number(e.total_resource)
      assert is_integer(e.timestamp_ms)
    end
  end

  test "ring buffer keeps at most max_entries" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    {:ok, _tel} = Lenies.Telemetry.start_link(max_entries: 5)

    for _ <- 1..20, do: World.tick_now()
    Process.sleep(100)

    entries = Lenies.Telemetry.history(:all)
    assert length(entries) == 5

    # gli ultimi 5 tick: 16, 17, 18, 19, 20
    ticks = Enum.map(entries, & &1.tick) |> Enum.sort()
    assert ticks == [16, 17, 18, 19, 20]
  end
end
