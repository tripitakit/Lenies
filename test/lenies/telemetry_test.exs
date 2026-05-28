defmodule Lenies.TelemetryTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables
  alias Lenies.WorldTestHelpers

  setup do
    on_exit(fn ->
      for pid <- [WorldTestHelpers.telemetry_pid(), WorldTestHelpers.world_pid()] do
        if is_pid(pid) and Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end

      Tables.delete_all()
    end)

    :ok
  end

  # Synchronously drain Telemetry's mailbox so any pending {:tick, _} or
  # {:sterilized, _} message has been processed before we read history.
  defp drain_telemetry do
    :sys.get_state(WorldTestHelpers.telemetry_pid())
  end

  test "records a history entry on each world tick" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    {:ok, _tel} = Lenies.Telemetry.start_link(world_id: :primary)

    World.tick_now()
    World.tick_now()
    World.tick_now()

    # tempo di propagazione del PubSub; :sys.get_state/1 drena la mailbox prima
    # di leggere la storia
    Process.sleep(50)
    drain_telemetry()

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
    {:ok, _tel} = Lenies.Telemetry.start_link(world_id: :primary, max_entries: 5)

    for _ <- 1..20, do: World.tick_now()
    Process.sleep(100)

    entries = Lenies.Telemetry.history(:all)
    assert length(entries) == 5

    # gli ultimi 5 tick: 16, 17, 18, 19, 20
    ticks = Enum.map(entries, & &1.tick) |> Enum.sort()
    assert ticks == [16, 17, 18, 19, 20]
  end

  # ---- I6: O(1) ring-buffer eviction ----

  describe "ring buffer O(1) eviction — correct oldest-entry removal" do
    setup do
      {:ok, _world} = World.start_link(tick_interval_ms: 0)
      {:ok, _tel} = Lenies.Telemetry.start_link(world_id: :primary, max_entries: 3)
      :ok
    end

    # Drive ticks by sending {:tick, n} directly to Telemetry so there is no
    # PubSub timing uncertainty. We bypass World.tick_now to avoid PubSub races.
    defp send_tick(_n) do
      # World.snapshot_stats() is called inside handle_info({:tick, n},...),
      # so World must be running. We drive via World.tick_now to keep stats real,
      # then drain the PubSub message that world.ex broadcasts (telemetry would
      # receive it too — but since we want synchronous control, we drive ticks
      # purely via World.tick_now() which broadcasts {:tick, n} on "world:tick".
      # :sys.get_state/1 after each group forces the mailbox to drain.
      World.tick_now()
    end

    test "buffer size is capped at max_entries after overflow" do
      for _ <- 1..7, do: send_tick(nil)
      # Drain Telemetry mailbox synchronously
      drain_telemetry()
      assert :ets.info(Lenies.WorldTestHelpers.history(), :size) == 3
    end

    test "retained entries are the most recent ones (oldest evicted)" do
      for _ <- 1..6, do: send_tick(nil)
      drain_telemetry()

      entries = Lenies.Telemetry.history(:all)
      assert length(entries) == 3

      # Ticks 4, 5, 6 must be present; ticks 1, 2, 3 evicted
      ticks = Enum.map(entries, & &1.tick) |> Enum.sort()
      assert ticks == [4, 5, 6]
    end

    test "eviction still correct after sterilize resets counter" do
      # Sterilize resets counter to 0 in Telemetry; subsequent ticks should
      # still evict oldest correctly.
      for _ <- 1..4, do: send_tick(nil)
      drain_telemetry()

      World.sterilize()
      # sterilize broadcasts {:sterilized, ts} which resets Telemetry counter
      drain_telemetry()

      for _ <- 1..5, do: send_tick(nil)
      drain_telemetry()

      assert :ets.info(Lenies.WorldTestHelpers.history(), :size) == 3
      entries = Lenies.Telemetry.history(:all)
      ticks = Enum.map(entries, & &1.tick) |> Enum.sort()
      assert ticks == [3, 4, 5]
    end
  end
end
