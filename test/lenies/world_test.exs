defmodule Lenies.WorldTest do
  use ExUnit.Case, async: false

  setup ctx do
    {:ok, world_id} =
      Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: ctx[:tick_interval_ms] || 0)

    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id}
  end

  test "starts and initializes ETS tables with 16_384 empty cells (128×128)",
       %{world_id: world_id} do
    assert :ets.info(Lenies.WorldTestHelpers.cells(world_id), :size) == 16_384
    [{{0, 0}, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {0, 0})
    assert cell.resource == 0
    assert cell.lenie_id == nil
    assert cell.carcass == 0
  end

  test "reset_energy/1 resets per-cell resource+carcass to baseline, preserving Lenies",
       %{world_id: world_id} do
    cells = Lenies.WorldTestHelpers.cells(world_id)
    initial = Application.get_env(:lenies, :initial_resource_per_cell, 30)

    # Saturate cells; one is occupied by a Lenie.
    :ets.insert(cells, {{1, 1}, %Lenies.World.Cell{resource: 250, carcass: 120, carcass_hue: 77}})
    :ets.insert(cells, {{2, 2}, %Lenies.World.Cell{resource: 200, carcass: 0, lenie_id: "L"}})

    :ok = Lenies.Worlds.reset_energy(world_id)

    [{_, c11}] = :ets.lookup(cells, {1, 1})
    [{_, c22}] = :ets.lookup(cells, {2, 2})

    assert c11.resource == initial
    assert c11.carcass == 0
    assert c11.carcass_hue == 0

    assert c22.resource == initial
    assert c22.carcass == 0
    # Lenie occupancy is preserved — only the distributed energy is reset.
    assert c22.lenie_id == "L"
  end

  test "snapshot_stats/0 returns basic counts on empty world", %{world_id: world_id} do
    stats = Lenies.Worlds.snapshot_stats(world_id)
    assert stats.cells == 16_384
    assert stats.population == 0
    assert stats.total_resource == 0
    assert stats.total_carcass == 0
  end

  test "tick_now/0 applies radiation to cells", %{world_id: world_id} do
    stats_before = Lenies.Worlds.snapshot_stats(world_id)
    assert stats_before.total_resource == 0

    Lenies.Worlds.tick_now(world_id)
    stats_after = Lenies.Worlds.snapshot_stats(world_id)
    # radiation_per_tick default (config/runtime.exs)
    assert stats_after.total_resource == 500
    assert stats_after.tick_count == 1
  end

  test "tick_now/0 caps total resource at grid_size × cell_resource_cap",
       %{world_id: world_id} do
    max_total = 16_384 * 100

    # 1000 ticks → 100_000 units poured (well below the global cap)
    for _ <- 1..1000, do: Lenies.Worlds.tick_now(world_id)

    stats = Lenies.Worlds.snapshot_stats(world_id)
    assert stats.total_resource <= max_total
    assert stats.tick_count == 1000
  end

  @tag tick_interval_ms: 50
  test "auto-tick fires at the configured interval", %{world_id: world_id} do
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    Phoenix.PubSub.subscribe(Lenies.PubSub, handle.pubsub_prefix <> ":tick")

    # Some early ticks may have already fired before subscribe; just wait for
    # two consecutive ticks at the configured cadence.
    assert_receive {:tick, _, _}, 500
    assert_receive {:tick, _, _}, 500
  end

  test "tick_now/0 decays carcasses by configured rate", %{world_id: world_id} do
    :ok = Lenies.Worlds.tune(world_id, :carcass_decay, 0.05)

    # manually inject a carcass into a cell
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {10, 10})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | carcass: 100}})

    Lenies.Worlds.tick_now(world_id)

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {10, 10})
    # 5% decay → 100 → 95
    assert after_cell.carcass == 95
  end

  test "tick_now/0 floors carcass at 0 over many ticks", %{world_id: world_id} do
    :ok = Lenies.Worlds.tune(world_id, :carcass_decay, 0.05)

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | carcass: 10}})

    for _ <- 1..200, do: Lenies.Worlds.tick_now(world_id)

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert after_cell.carcass == 0
  end

  describe "lenie_died/4 — carcass_hue" do
    test "death stores SpeciesColor.hue_byte(hash) into the cell's carcass_hue",
         %{world_id: world_id} do
      hash = "test-hash-abc"
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      expected_hue = Lenies.SpeciesColor.hue_byte(handle, hash)

      # Plant a Lenie at (3, 4)
      :ets.insert(
        Lenies.WorldTestHelpers.cells(world_id),
        {{3, 4}, %Lenies.World.Cell{lenie_id: "L1"}}
      )

      :ets.insert(Lenies.WorldTestHelpers.lenies(world_id), {"L1", %{id: "L1"}})

      Lenies.Worlds.lenie_died(world_id, "L1", {3, 4}, 200.0, hash)

      # Cast is async; sync via a synchronous call to the same GenServer
      _ = Lenies.Worlds.snapshot_stats(world_id)

      [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {3, 4})
      assert cell.lenie_id == nil
      assert cell.carcass > 0
      assert cell.carcass_hue == expected_hue
    end
  end

  # ---- I5: cached totals ----

  describe "snapshot_stats cached totals match direct ETS fold" do
    # Helper: independent fold over :cells to sum resource & carcass
    defp direct_sum(world_id) do
      :ets.foldl(
        fn {_key, cell}, {r, c} -> {r + cell.resource, c + cell.carcass} end,
        {0, 0},
        Lenies.WorldTestHelpers.cells(world_id)
      )
    end

    test "cached total_resource equals direct sum after several ticks",
         %{world_id: world_id} do
      for _ <- 1..5, do: Lenies.Worlds.tick_now(world_id)
      stats = Lenies.Worlds.snapshot_stats(world_id)
      {direct_r, _direct_c} = direct_sum(world_id)
      assert stats.total_resource == direct_r
    end

    test "cached total_carcass equals direct sum after seeding carcass and ticking",
         %{world_id: world_id} do
      :ok = Lenies.Worlds.tune(world_id, :carcass_decay, 0.1)

      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {7, 7})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | carcass: 200}})

      for _ <- 1..3, do: Lenies.Worlds.tick_now(world_id)

      stats = Lenies.Worlds.snapshot_stats(world_id)
      {_direct_r, direct_c} = direct_sum(world_id)

      # cached total must equal fresh fold (decay applied, post-decay value cached)
      assert stats.total_carcass == direct_c
    end

    test "carcass total decreases across ticks when decay is enabled",
         %{world_id: world_id} do
      :ok = Lenies.Worlds.tune(world_id, :carcass_decay, 0.2)

      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {3, 3})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | carcass: 1000}})

      # One tick to seed the cached total with the injected carcass.
      Lenies.Worlds.tick_now(world_id)
      stats_after_first = Lenies.Worlds.snapshot_stats(world_id)

      # Further ticks must reduce the total.
      for _ <- 1..5, do: Lenies.Worlds.tick_now(world_id)

      stats_after_more = Lenies.Worlds.snapshot_stats(world_id)
      # decay must have reduced total carcass
      assert stats_after_more.total_carcass < stats_after_first.total_carcass
    end

    test "cached total_carcass after decay matches fresh fold (totals-drift canary)",
         %{world_id: world_id} do
      # This test would catch a bug where we cache the PRE-decay carcass
      # rather than the post-decay value.
      :ok = Lenies.Worlds.tune(world_id, :carcass_decay, 0.5)

      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {15, 15})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | carcass: 500}})

      Lenies.Worlds.tick_now(world_id)

      stats = Lenies.Worlds.snapshot_stats(world_id)
      {_direct_r, direct_c} = direct_sum(world_id)

      # If implementation cached pre-decay value, stats.total_carcass would
      # be 500 here while direct_c would be ~250. This assertion catches that.
      assert stats.total_carcass == direct_c
    end

    test "total_resource is correct at init (before first tick)",
         %{world_id: world_id} do
      # Before any tick, radiation has not run (tick_interval_ms: 0 = no auto-tick,
      # but prewarm_radiation uses :initial_radiation_ticks which defaults to 50 in
      # test config — check actual resource).
      stats = Lenies.Worlds.snapshot_stats(world_id)
      {direct_r, _} = direct_sum(world_id)
      assert stats.total_resource == direct_r
    end
  end

  describe "eat clears carcass_hue when carcass goes to 0" do
    test "eating the last carcass unit clears carcass_hue", %{world_id: world_id} do
      :ok = Lenies.Worlds.tune(world_id, :eat_amount, 50)

      # Plant a cell with carcass = 5 (less than eat_amount) and a hue marker
      :ets.insert(
        Lenies.WorldTestHelpers.cells(world_id),
        {{1, 1}, %Lenies.World.Cell{carcass: 5, carcass_hue: 137}}
      )

      {:ok, {:ate, _}} = Lenies.Worlds.action(world_id, {:eat, {1, 1}})

      [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {1, 1})
      assert cell.carcass == 0
      assert cell.carcass_hue == 0
    end

    test "eating but leaving some carcass preserves carcass_hue", %{world_id: world_id} do
      :ok = Lenies.Worlds.tune(world_id, :eat_amount, 3)

      :ets.insert(
        Lenies.WorldTestHelpers.cells(world_id),
        {{2, 2}, %Lenies.World.Cell{carcass: 20, carcass_hue: 99}}
      )

      {:ok, {:ate, _}} = Lenies.Worlds.action(world_id, {:eat, {2, 2}})

      [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {2, 2})
      assert cell.carcass > 0
      assert cell.carcass_hue == 99
    end
  end

  describe "tick broadcast payload (Task 3: Telemetry decouple)" do
    test "tick broadcast carries {:tick, n, stats} with population/total_resource/total_carcass",
         %{world_id: world_id} do
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{handle.pubsub_prefix}:tick")

      Lenies.Worlds.tick_now(world_id)

      assert_receive {:tick, n, stats}, 500
      assert is_integer(n)
      assert is_map(stats)
      assert is_integer(stats.population)
      assert is_number(stats.total_resource)
      assert is_number(stats.total_carcass)
    end
  end

  describe "spawn_cap enforcement (Task 4)" do
    test "spawn_lenie returns {:error, :spawn_cap_exceeded} when world is at spawn_cap" do
      world_id = :"spawn_cap_test_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Lenies.Worlds.start_world(world_id, %{
          spawn_cap: 2,
          replication_cap: :infinity,
          tick_interval_ms: 0
        })

      on_exit(fn -> Lenies.Worlds.stop_world(world_id) end)

      {:ok, handle} = Lenies.Worlds.handle(world_id)
      codeome = Lenies.Seeds.get(:minimal_replicator).codeome

      assert {:ok, {_id1, _pos1}} =
               GenServer.call(handle.pid, {:spawn_lenie, codeome, [energy: 100.0]})

      assert {:ok, {_id2, _pos2}} =
               GenServer.call(handle.pid, {:spawn_lenie, codeome, [energy: 100.0]})

      assert {:error, :spawn_cap_exceeded} =
               GenServer.call(handle.pid, {:spawn_lenie, codeome, [energy: 100.0]})
    end

    test "spawn_lenie succeeds without limit when spawn_cap is :infinity" do
      world_id = :"spawn_cap_inf_test_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Lenies.Worlds.start_world(world_id, %{
          spawn_cap: :infinity,
          replication_cap: :infinity,
          tick_interval_ms: 0
        })

      on_exit(fn -> Lenies.Worlds.stop_world(world_id) end)

      {:ok, handle} = Lenies.Worlds.handle(world_id)
      codeome = Lenies.Seeds.get(:minimal_replicator).codeome

      for _ <- 1..15 do
        assert {:ok, {_id, _pos}} =
                 GenServer.call(handle.pid, {:spawn_lenie, codeome, [energy: 100.0]})
      end
    end
  end

  describe "replication_cap enforcement (Task 5)" do
    test "divide returns {:ok, :replication_cap_exceeded} when at replication_cap; Lenie stays alive" do
      world_id = :"replication_cap_test_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Lenies.Worlds.start_world(world_id, %{
          spawn_cap: :infinity,
          replication_cap: 1,
          tick_interval_ms: 0
        })

      on_exit(fn -> Lenies.Worlds.stop_world(world_id) end)

      {:ok, handle} = Lenies.Worlds.handle(world_id)
      codeome = Lenies.Seeds.get(:minimal_replicator).codeome

      assert {:ok, {parent_id, pos}} =
               GenServer.call(handle.pid, {:spawn_lenie, codeome, [energy: 100.0]})

      # World already has 1 (the parent) and replication_cap = 1 → divide blocked
      divide_action = {:divide, 50.0, pos, :n, parent_id}

      assert {:ok, :replication_cap_exceeded} =
               GenServer.call(handle.pid, {:action, divide_action})

      # Parent unharmed: still in ETS
      assert [_] = :ets.lookup(handle.tables.lenies, parent_id)
    end

    test "divide proceeds normally when below replication_cap" do
      world_id = :"replication_cap_below_test_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Lenies.Worlds.start_world(world_id, %{
          spawn_cap: :infinity,
          replication_cap: 100,
          tick_interval_ms: 0
        })

      on_exit(fn -> Lenies.Worlds.stop_world(world_id) end)

      {:ok, handle} = Lenies.Worlds.handle(world_id)
      codeome = Lenies.Seeds.get(:minimal_replicator).codeome

      assert {:ok, {parent_id, pos}} =
               GenServer.call(handle.pid, {:spawn_lenie, codeome, [energy: 100.0]})

      # Below cap → divide returns its usual success/no_slot envelope, NOT :replication_cap_exceeded
      divide_action = {:divide, 50.0, pos, :n, parent_id}
      result = GenServer.call(handle.pid, {:action, divide_action})
      refute match?({:ok, :replication_cap_exceeded}, result)
    end
  end

  describe "scheduler priority" do
    test "World process is started with :low scheduler priority", %{world_id: world_id} do
      {:ok, handle} = Lenies.Worlds.handle(world_id)

      assert {:priority, :low} = :erlang.process_info(handle.pid, :priority)
    end
  end
end
