defmodule Lenies.WorldIndexConsistencyTest do
  @moduledoc """
  The World maintains occupancy, the carcass set, and the resource/carcass
  totals INCREMENTALLY (via the `put_cell/4` choke point) instead of folding
  all 16 384 cells every tick. These tests pin the invariant that those cached
  indices stay equal to a fresh authoritative scan of `:cells`.

  Lenies move asynchronously, so the occupancy snapshot is a point-in-time
  capture that a later `:cells` read won't match while they're running. We
  therefore PAUSE the world and let in-flight actions drain before comparing —
  once quiescent, the incrementally-maintained indices must equal a full scan.
  """
  use ExUnit.Case, async: false

  defp occupancy_snapshot(handle) do
    case :ets.lookup(handle.tables.occupancy, :snapshot) do
      [{:snapshot, m}] -> m
      _ -> nil
    end
  end

  defp authoritative_occupancy(handle) do
    :ets.tab2list(handle.tables.cells)
    |> Enum.filter(fn {_k, c} -> is_binary(c.lenie_id) end)
    |> Map.new(fn {k, c} -> {k, c.lenie_id} end)
  end

  defp authoritative_totals(handle) do
    :ets.foldl(
      fn {_k, c}, {r, ca} -> {r + c.resource, ca + c.carcass} end,
      {0, 0},
      handle.tables.cells
    )
  end

  # Freeze the world (stop Lenie motion), drain in-flight actions, refresh the
  # snapshot with a tick, then assert the cached indices equal a full scan.
  defp assert_indices_consistent_when_quiescent(world_id, handle) do
    :ok = Lenies.Worlds.pause(world_id)
    Process.sleep(60)
    :ok = Lenies.Worlds.tick_now(world_id)

    assert occupancy_snapshot(handle) == authoritative_occupancy(handle)

    stats = Lenies.Worlds.snapshot_stats(world_id)
    {real_r, real_c} = authoritative_totals(handle)
    assert stats.total_resource == real_r, "total_resource drifted from the authoritative sum"
    assert stats.total_carcass == real_c, "total_carcass drifted from the authoritative sum"

    :ok = Lenies.Worlds.resume(world_id)
  end

  setup do
    {:ok, world_id} =
      Lenies.WorldTestHelpers.start_test_world(
        spawn_cap: :infinity,
        replication_cap: :infinity,
        carcass_decay: 0.1
      )

    {:ok, handle} = Lenies.Worlds.handle(world_id)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id, handle: handle}
  end

  test "indices stay consistent across spawn + movement + ticks", %{
    world_id: world_id,
    handle: handle
  } do
    for _ <- 1..6 do
      {:ok, _} =
        Lenies.Worlds.spawn_lenie(world_id, Lenies.Codeomes.Walker.codeome(), energy: 5000.0)
    end

    # Let them move/eat for a while, then check, repeatedly.
    for _ <- 1..4 do
      Process.sleep(80)
      assert_indices_consistent_when_quiescent(world_id, handle)
    end
  end

  test "indices stay consistent through death + carcass decay", %{
    world_id: world_id,
    handle: handle
  } do
    {:ok, _} =
      Lenies.Worlds.spawn_lenie(world_id, Lenies.Codeomes.Walker.codeome(), energy: 5000.0)

    # Short-lived Lenie that starves quickly → death cast clears its cell.
    {:ok, {dying_id, _}} =
      Lenies.Worlds.spawn_lenie(world_id, Lenies.Codeomes.Walker.codeome(), energy: 1.0)

    Process.sleep(150)
    assert Registry.lookup(Lenies.Registry, {:lenie, world_id, dying_id}) == []

    # Run ticks (carcass decays over the carcass index); indices must stay exact.
    for _ <- 1..3 do
      Process.sleep(60)
      assert_indices_consistent_when_quiescent(world_id, handle)
    end
  end

  test "reconcile self-heals the indices back to the authoritative scan", %{
    world_id: world_id,
    handle: handle
  } do
    {:ok, _} =
      Lenies.Worlds.spawn_lenie(world_id, Lenies.Codeomes.Forager.codeome(), energy: 5000.0)

    :ok = Lenies.Worlds.pause(world_id)
    Process.sleep(60)
    :ok = Lenies.Worlds.tick_now(world_id)

    # Corrupt the occupancy snapshot directly, then prove reconcile rebuilds it
    # from the authoritative cells (the safety net for any missed put_cell site).
    :ets.insert(handle.tables.occupancy, {:snapshot, %{{99, 99} => "GHOST"}})
    _ = Lenies.Worlds.reconcile(world_id)

    assert occupancy_snapshot(handle) == authoritative_occupancy(handle)
    refute Map.has_key?(occupancy_snapshot(handle), {99, 99})
  end
end
