defmodule Lenies.TelemetryTest do
  use ExUnit.Case, async: false

  alias Lenies.WorldTestHelpers

  setup do
    {:ok, world_id} = WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    on_exit(fn -> WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id}
  end

  # Synchronously drain Telemetry's mailbox so any pending {:tick, _, _} or
  # {:sterilized, _} message has been processed before we read history.
  defp drain_telemetry(world_id) do
    :sys.get_state(WorldTestHelpers.telemetry_pid(world_id))
  end

  # Replace the auto-started (supervised) Telemetry with a standalone one that
  # accepts custom opts like `:max_entries`. The original Telemetry is killed
  # via terminate_child so the supervisor does not auto-restart it; the new
  # process registers under the same via-tuple `{:telemetry, world_id}`.
  defp replace_telemetry(world_id, opts) do
    [{sup_pid, _}] = Registry.lookup(Lenies.Registry, {:world_sup, world_id})
    # The supervised Telemetry's id (its child_spec id) is `Lenies.Telemetry`.
    :ok = Supervisor.terminate_child(sup_pid, Lenies.Telemetry)

    {:ok, pid} = Lenies.Telemetry.start_link([world_id: world_id] ++ opts)
    pid
  end

  test "records a history entry on each world tick", %{world_id: world_id} do
    Lenies.Worlds.tick_now(world_id)
    Lenies.Worlds.tick_now(world_id)
    Lenies.Worlds.tick_now(world_id)

    # tempo di propagazione del PubSub; :sys.get_state/1 drena la mailbox prima
    # di leggere la storia
    Process.sleep(50)
    drain_telemetry(world_id)

    entries = Lenies.Telemetry.history(world_id, :last_n, 10)
    assert length(entries) == 3

    for e <- entries do
      assert is_integer(e.tick)
      assert is_integer(e.population)
      assert is_number(e.total_resource)
      assert is_integer(e.timestamp_ms)
    end
  end

  test "ring buffer keeps at most max_entries", %{world_id: world_id} do
    _tel = replace_telemetry(world_id, max_entries: 5)

    for _ <- 1..20, do: Lenies.Worlds.tick_now(world_id)
    Process.sleep(100)

    entries = Lenies.Telemetry.history(world_id, :all)
    assert length(entries) == 5

    # gli ultimi 5 tick: 16, 17, 18, 19, 20
    ticks = Enum.map(entries, & &1.tick) |> Enum.sort()
    assert ticks == [16, 17, 18, 19, 20]
  end

  # ---- I6: O(1) ring-buffer eviction ----

  describe "ring buffer O(1) eviction — correct oldest-entry removal" do
    setup %{world_id: world_id} do
      _tel = replace_telemetry(world_id, max_entries: 3)
      :ok
    end

    # Drive ticks by calling Lenies.Worlds.tick_now/1.
    defp send_tick(world_id) do
      Lenies.Worlds.tick_now(world_id)
    end

    test "buffer size is capped at max_entries after overflow", %{world_id: world_id} do
      for _ <- 1..7, do: send_tick(world_id)
      # Drain Telemetry mailbox synchronously
      drain_telemetry(world_id)
      assert :ets.info(Lenies.WorldTestHelpers.history(world_id), :size) == 3
    end

    test "retained entries are the most recent ones (oldest evicted)",
         %{world_id: world_id} do
      for _ <- 1..6, do: send_tick(world_id)
      drain_telemetry(world_id)

      entries = Lenies.Telemetry.history(world_id, :all)
      assert length(entries) == 3

      # Ticks 4, 5, 6 must be present; ticks 1, 2, 3 evicted
      ticks = Enum.map(entries, & &1.tick) |> Enum.sort()
      assert ticks == [4, 5, 6]
    end

    test "eviction still correct after sterilize resets counter",
         %{world_id: world_id} do
      # Sterilize resets counter to 0 in Telemetry; subsequent ticks should
      # still evict oldest correctly.
      for _ <- 1..4, do: send_tick(world_id)
      drain_telemetry(world_id)

      Lenies.Worlds.sterilize(world_id)
      # sterilize broadcasts {:sterilized, ts} which resets Telemetry counter
      drain_telemetry(world_id)

      for _ <- 1..5, do: send_tick(world_id)
      drain_telemetry(world_id)

      assert :ets.info(Lenies.WorldTestHelpers.history(world_id), :size) == 3
      entries = Lenies.Telemetry.history(world_id, :all)
      ticks = Enum.map(entries, & &1.tick) |> Enum.sort()
      assert ticks == [3, 4, 5]
    end
  end

  describe "decoupling from World GenServer (Task 3)" do
    test "Telemetry records tick stats without calling World GenServer",
         %{world_id: world_id} do
      {:ok, handle} = Lenies.Worlds.handle(world_id)

      # Trace World's mailbox: any GenServer.call to World should NOT happen
      # from Telemetry on a tick.
      :erlang.trace(handle.pid, true, [:receive])

      Lenies.Worlds.tick_now(world_id)
      Process.sleep(100)

      # Drain all traces and assert none are `:snapshot_stats` calls
      trace_msgs =
        receive_all_trace_msgs([])
        |> Enum.filter(fn
          {:trace, _pid, :receive, {:"$gen_call", _, :snapshot_stats}} -> true
          _ -> false
        end)

      :erlang.trace(handle.pid, false, [:receive])

      assert trace_msgs == [], "Telemetry should not call :snapshot_stats on World"
    end
  end

  defp receive_all_trace_msgs(acc) do
    receive do
      msg -> receive_all_trace_msgs([msg | acc])
    after
      50 -> acc
    end
  end
end
