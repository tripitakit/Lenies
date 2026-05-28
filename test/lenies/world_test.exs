defmodule Lenies.WorldTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      case Lenies.WorldTestHelpers.world_pid() do
        nil -> :ok
        pid -> if Process.alive?(pid), do: GenServer.stop(pid)
      end

      Tables.delete_all()
    end)

    :ok
  end

  test "starts and initializes ETS tables with 65_536 empty cells" do
    {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 0)
    assert :ets.info(Lenies.WorldTestHelpers.cells(), :size) == 65_536
    [{{0, 0}, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {0, 0})
    assert cell.resource == 0
    assert cell.lenie_id == nil
    assert cell.carcass == 0
  end

  test "snapshot_stats/0 returns basic counts on empty world" do
    {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 0)
    stats = Lenies.Worlds.snapshot_stats(:primary)
    assert stats.cells == 65_536
    assert stats.population == 0
    assert stats.total_resource == 0
    assert stats.total_carcass == 0
  end

  test "tick_now/0 applies radiation to cells" do
    {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 0)
    stats_before = Lenies.Worlds.snapshot_stats(:primary)
    assert stats_before.total_resource == 0

    Lenies.Worlds.tick_now(:primary)
    stats_after = Lenies.Worlds.snapshot_stats(:primary)
    # radiation_per_tick default (config/runtime.exs)
    assert stats_after.total_resource == 1000
    assert stats_after.tick_count == 1
  end

  test "tick_now/0 caps total resource at grid_size × cell_resource_cap" do
    {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 0)
    max_total = 65_536 * 100

    # 1000 ticks → 100_000 units poured (well below the global cap)
    for _ <- 1..1000, do: Lenies.Worlds.tick_now(:primary)

    stats = Lenies.Worlds.snapshot_stats(:primary)
    assert stats.total_resource <= max_total
    assert stats.tick_count == 1000
  end

  test "auto-tick fires at the configured interval" do
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:primary:tick")
    {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 50)

    assert_receive {:tick, 1}, 500
    assert_receive {:tick, 2}, 500
  end

  test "tick_now/0 decays carcasses by configured rate" do
    Application.put_env(:lenies, :carcass_decay, 0.05)

    on_exit(fn -> Application.put_env(:lenies, :carcass_decay, 0) end)

    {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 0)

    # manually inject a carcass into a cell
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {10, 10})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | carcass: 100}})

    Lenies.Worlds.tick_now(:primary)

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {10, 10})
    # 5% decay → 100 → 95
    assert after_cell.carcass == 95
  end

  test "tick_now/0 floors carcass at 0 over many ticks" do
    Application.put_env(:lenies, :carcass_decay, 0.05)

    on_exit(fn -> Application.put_env(:lenies, :carcass_decay, 0) end)

    {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | carcass: 10}})

    for _ <- 1..200, do: Lenies.Worlds.tick_now(:primary)

    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    assert after_cell.carcass == 0
  end

  describe "lenie_died/4 — carcass_hue" do
    setup do
      {:ok, _} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})
      on_exit(fn -> Lenies.WorldTestHelpers.stop_primary() end)
      :ok
    end

    test "death stores SpeciesColor.hue_byte(hash) into the cell's carcass_hue" do
      hash = "test-hash-abc"
      {:ok, primary_handle} = Lenies.Worlds.handle(:primary)
      expected_hue = Lenies.SpeciesColor.hue_byte(primary_handle, hash)

      # Plant a Lenie at (3, 4)
      :ets.insert(Lenies.WorldTestHelpers.cells(), {{3, 4}, %Lenies.World.Cell{lenie_id: "L1"}})
      :ets.insert(Lenies.WorldTestHelpers.lenies(), {"L1", %{id: "L1"}})

      Lenies.Worlds.lenie_died(:primary, "L1", {3, 4}, 200.0, hash)

      # Cast is async; sync via a synchronous call to the same GenServer
      _ = Lenies.Worlds.snapshot_stats(:primary)

      [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {3, 4})
      assert cell.lenie_id == nil
      assert cell.carcass > 0
      assert cell.carcass_hue == expected_hue
    end
  end

  # ---- I5: cached totals ----

  describe "snapshot_stats cached totals match direct ETS fold" do
    setup do
      {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 0)
      :ok
    end

    # Helper: independent fold over :cells to sum resource & carcass
    defp direct_sum do
      :ets.foldl(
        fn {_key, cell}, {r, c} -> {r + cell.resource, c + cell.carcass} end,
        {0, 0},
        Lenies.WorldTestHelpers.cells()
      )
    end

    test "cached total_resource equals direct sum after several ticks" do
      for _ <- 1..5, do: Lenies.Worlds.tick_now(:primary)
      stats = Lenies.Worlds.snapshot_stats(:primary)
      {direct_r, _direct_c} = direct_sum()
      assert stats.total_resource == direct_r
    end

    test "cached total_carcass equals direct sum after seeding carcass and ticking" do
      # World already booted in setup; mutate state.config live via the facade.
      :ok = Lenies.Worlds.tune(:primary, :carcass_decay, 0.1)
      on_exit(fn -> Application.put_env(:lenies, :carcass_decay, 0) end)

      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {7, 7})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | carcass: 200}})

      for _ <- 1..3, do: Lenies.Worlds.tick_now(:primary)

      stats = Lenies.Worlds.snapshot_stats(:primary)
      {_direct_r, direct_c} = direct_sum()

      # cached total must equal fresh fold (decay applied, post-decay value cached)
      assert stats.total_carcass == direct_c
    end

    test "carcass total decreases across ticks when decay is enabled" do
      # World already booted in setup; mutate state.config live via the facade.
      :ok = Lenies.Worlds.tune(:primary, :carcass_decay, 0.2)
      on_exit(fn -> Application.put_env(:lenies, :carcass_decay, 0) end)

      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {3, 3})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | carcass: 1000}})

      # One tick to seed the cached total with the injected carcass.
      Lenies.Worlds.tick_now(:primary)
      stats_after_first = Lenies.Worlds.snapshot_stats(:primary)

      # Further ticks must reduce the total.
      for _ <- 1..5, do: Lenies.Worlds.tick_now(:primary)

      stats_after_more = Lenies.Worlds.snapshot_stats(:primary)
      # decay must have reduced total carcass
      assert stats_after_more.total_carcass < stats_after_first.total_carcass
    end

    test "cached total_carcass after decay matches fresh fold (totals-drift canary)" do
      # This test would catch a bug where we cache the PRE-decay carcass
      # rather than the post-decay value.
      # World already booted in setup; mutate state.config live via the facade.
      :ok = Lenies.Worlds.tune(:primary, :carcass_decay, 0.5)
      on_exit(fn -> Application.put_env(:lenies, :carcass_decay, 0) end)

      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {15, 15})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | carcass: 500}})

      Lenies.Worlds.tick_now(:primary)

      stats = Lenies.Worlds.snapshot_stats(:primary)
      {_direct_r, direct_c} = direct_sum()

      # If implementation cached pre-decay value, stats.total_carcass would
      # be 500 here while direct_c would be ~250. This assertion catches that.
      assert stats.total_carcass == direct_c
    end

    test "total_resource is correct at init (before first tick)" do
      # Before any tick, radiation has not run (tick_interval_ms: 0 = no auto-tick,
      # but prewarm_radiation uses :initial_radiation_ticks which defaults to 50 in
      # test config — check actual resource).
      stats = Lenies.Worlds.snapshot_stats(:primary)
      {direct_r, _} = direct_sum()
      assert stats.total_resource == direct_r
    end
  end

  describe "eat clears carcass_hue when carcass goes to 0" do
    setup do
      {:ok, _pid} = World.start_link(world_id: :primary, tick_interval_ms: 0)
      :ok
    end

    test "eating the last carcass unit clears carcass_hue" do
      # World already booted in setup; mutate state.config live via the facade.
      :ok = Lenies.Worlds.tune(:primary, :eat_amount, 50)

      # Plant a cell with carcass = 5 (less than eat_amount) and a hue marker
      :ets.insert(
        Lenies.WorldTestHelpers.cells(),
        {{1, 1}, %Lenies.World.Cell{carcass: 5, carcass_hue: 137}}
      )

      {:ok, {:ate, _}} = Lenies.Worlds.action(:primary, {:eat, {1, 1}})

      [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {1, 1})
      assert cell.carcass == 0
      assert cell.carcass_hue == 0
    end

    test "eating but leaving some carcass preserves carcass_hue" do
      # World already booted in setup; mutate state.config live via the facade.
      :ok = Lenies.Worlds.tune(:primary, :eat_amount, 3)

      :ets.insert(
        Lenies.WorldTestHelpers.cells(),
        {{2, 2}, %Lenies.World.Cell{carcass: 20, carcass_hue: 99}}
      )

      {:ok, {:ate, _}} = Lenies.Worlds.action(:primary, {:eat, {2, 2}})

      [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {2, 2})
      assert cell.carcass > 0
      assert cell.carcass_hue == 99
    end
  end
end
