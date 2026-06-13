defmodule Lenies.World.QueryTest do
  use ExUnit.Case, async: false

  alias Lenies.Codeome
  alias Lenies.World.Query
  alias Lenies.WorldTestHelpers

  setup do
    {:ok, world_id} = WorldTestHelpers.start_test_world()

    on_exit(fn ->
      case WorldTestHelpers.lenie_sup_pid(world_id) do
        sup_pid when is_pid(sup_pid) ->
          DynamicSupervisor.which_children(sup_pid)
          |> Enum.each(fn {_, child_pid, _, _} ->
            if is_pid(child_pid), do: DynamicSupervisor.terminate_child(sup_pid, child_pid)
          end)

        _ ->
          :ok
      end

      WorldTestHelpers.stop_test_world(world_id)
    end)

    {:ok, handle} = Lenies.Worlds.handle(world_id)
    codeome = Codeome.from_list([:nop_0, :nop_0, :nop_0])
    {:ok, {lenie_id, {x, y}}} = Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0)

    {:ok, world_id: world_id, handle: handle, lenie_id: lenie_id, x: x, y: y}
  end

  describe "lenie_snap_at/3" do
    test "returns the snapshot at an occupied cell", %{handle: handle, x: x, y: y} do
      assert {:ok, snap} = Query.lenie_snap_at(handle, x, y)
      assert is_map(snap)
      assert is_binary(snap.codeome_hash)
    end

    test "returns :error on an empty cell", %{handle: handle, x: x, y: y} do
      {ex, ey} = some_other_cell(x, y)
      assert :error = Query.lenie_snap_at(handle, ex, ey)
    end

    test "returns :error for a nil handle", _ctx do
      assert :error = Query.lenie_snap_at(nil, 0, 0)
    end
  end

  describe "codeome_hash_at/3" do
    test "returns the species hash at an occupied cell", %{handle: handle, x: x, y: y} do
      assert {:ok, hash} = Query.codeome_hash_at(handle, x, y)
      assert is_binary(hash)
    end

    test "returns :error on an empty cell", %{handle: handle, x: x, y: y} do
      {ex, ey} = some_other_cell(x, y)
      assert :error = Query.codeome_hash_at(handle, ex, ey)
    end
  end

  describe "lenie_snap/2" do
    test "returns the snapshot by id", %{handle: handle, lenie_id: id} do
      assert {:ok, snap} = Query.lenie_snap(handle, id)
      assert is_binary(snap.codeome_hash)
    end

    test "returns :error for an unknown id", %{handle: handle} do
      assert :error = Query.lenie_snap(handle, "does-not-exist")
    end

    test "returns :error for a nil handle", _ctx do
      assert :error = Query.lenie_snap(nil, "x")
    end
  end

  describe "population/1" do
    test "counts live Lenie records", %{handle: handle} do
      assert Query.population(handle) == 1
    end

    test "returns 0 for a nil handle", _ctx do
      assert Query.population(nil) == 0
    end
  end

  describe "lenie_pid/2" do
    test "returns the live pid for a running Lenie", %{world_id: world_id, lenie_id: id} do
      assert is_pid(Query.lenie_pid(world_id, id))
    end

    test "returns nil for an unknown id", %{world_id: world_id} do
      assert Query.lenie_pid(world_id, "does-not-exist") == nil
    end
  end

  # Pick any cell other than the occupied one (the grid is 128x128).
  defp some_other_cell(x, y) do
    nx = rem(x + 1, 128)
    if {nx, y} == {x, y}, do: {rem(x + 2, 128), y}, else: {nx, y}
  end
end
