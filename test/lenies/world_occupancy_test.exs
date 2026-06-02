defmodule Lenies.WorldOccupancyTest do
  @moduledoc """
  The World maintains a CONSISTENT lenie-occupancy snapshot in the `:occupancy`
  table so the canvas renderer never captures a lenie mid-move via a
  non-isolated `:ets.tab2list` of `:cells` (the "lenie drawn one cell off" bug).
  """
  use ExUnit.Case, async: false

  defp snapshot(handle) do
    case :ets.lookup(handle.tables.occupancy, :snapshot) do
      [{:snapshot, m}] -> m
      _ -> nil
    end
  end

  setup do
    {:ok, world_id} =
      Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0, spawn_cap: :infinity)

    {:ok, handle} = Lenies.Worlds.handle(world_id)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id, handle: handle}
  end

  test "init seeds an empty occupancy snapshot", %{handle: handle} do
    assert snapshot(handle) == %{}
  end

  test "spawn records the lenie at its cell in the snapshot", %{
    world_id: world_id,
    handle: handle
  } do
    codeome = Lenies.Codeomes.Forager.codeome()
    {:ok, {id, pos}} = Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0)
    assert snapshot(handle) == %{pos => id}
  end

  test "a tick refreshes the snapshot to agree with the authoritative cells", %{
    world_id: world_id,
    handle: handle
  } do
    codeome = Lenies.Codeomes.Forager.codeome()
    {:ok, {id, _pos}} = Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0)
    :ok = Lenies.Worlds.tick_now(world_id)

    snap = snapshot(handle)

    cells_occupancy =
      :ets.tab2list(handle.tables.cells)
      |> Enum.filter(fn {_k, c} -> is_binary(c.lenie_id) end)
      |> Map.new(fn {k, c} -> {k, c.lenie_id} end)

    assert snap == cells_occupancy
    assert snap == %{Map.fetch!(invert(cells_occupancy), id) => id}
  end

  test "sterilize empties the occupancy snapshot", %{world_id: world_id, handle: handle} do
    codeome = Lenies.Codeomes.Forager.codeome()
    {:ok, _} = Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0)
    assert map_size(snapshot(handle)) == 1

    :ok = Lenies.Worlds.sterilize(world_id)
    assert snapshot(handle) == %{}
  end

  defp invert(map), do: Map.new(map, fn {k, v} -> {v, k} end)
end
