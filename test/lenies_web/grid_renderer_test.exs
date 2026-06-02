defmodule LeniesWeb.GridRendererTest do
  use ExUnit.Case, async: false

  alias LeniesWeb.GridRenderer

  setup do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)

    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

    {:ok, handle: handle}
  end

  # Replace World's default 256×256 cells with a fresh grid_w × grid_h grid
  # — the tests inspect specific cells and need the canvas at exactly that
  # size for byte-index arithmetic.
  defp reset_cells(handle, {w, h}) do
    :ets.delete_all_objects(handle.tables.cells)

    for x <- 0..(w - 1), y <- 0..(h - 1) do
      :ets.insert(handle.tables.cells, {{x, y}, %Lenies.World.Cell{}})
    end
  end

  test "encode_layers/1 returns 4 binaries of grid_w * grid_h bytes", %{handle: handle} do
    grid = {4, 4}
    reset_cells(handle, grid)

    {lenies_bin, resource_bin, carcass_bin, carcass_hue_bin} =
      GridRenderer.encode_layers(handle, grid)

    assert byte_size(lenies_bin) == 16
    assert byte_size(resource_bin) == 16
    assert byte_size(carcass_bin) == 16
    assert byte_size(carcass_hue_bin) == 16

    assert lenies_bin == <<0::128>>
    assert resource_bin == <<0::128>>
    assert carcass_bin == <<0::128>>
    assert carcass_hue_bin == <<0::128>>
  end

  test "encode_layers/1 writes the species hue byte into the lenies layer at occupied cells",
       %{handle: handle} do
    grid = {4, 4}
    reset_cells(handle, grid)

    :ets.insert(handle.tables.cells, {{1, 2}, %Lenies.World.Cell{lenie_id: "L1"}})
    :ets.insert(handle.tables.lenies, {"L1", %{id: "L1", codeome_hash: "hash-A"}})

    expected_byte = Lenies.SpeciesColor.hue_byte(handle, "hash-A")

    {lenies_bin, _, _, _} = GridRenderer.encode_layers(handle, grid)

    # Row-major: byte index = y * w + x = 2 * 4 + 1 = 9
    assert :binary.at(lenies_bin, 9) == expected_byte

    for i <- 0..15, i != 9 do
      assert :binary.at(lenies_bin, i) == 0
    end
  end

  test "lenie layer follows the consistent occupancy snapshot, not racy cells.lenie_id",
       %{handle: handle} do
    grid = {4, 4}
    reset_cells(handle, grid)

    # The World's atomic occupancy snapshot says the lenie is at (1, 2).
    :ets.insert(handle.tables.occupancy, {:snapshot, %{{1, 2} => "L1"}})

    # But a non-isolated `:ets.tab2list` of `:cells` shows it at a STALE cell
    # (3, 3) — exactly the mid-move artifact the snapshot exists to mask.
    :ets.insert(handle.tables.cells, {{3, 3}, %Lenies.World.Cell{lenie_id: "L1"}})
    :ets.insert(handle.tables.lenies, {"L1", %{id: "L1", codeome_hash: "hash-A"}})

    expected = Lenies.SpeciesColor.hue_byte(handle, "hash-A")
    {lenies_bin, _, _, _} = GridRenderer.encode_layers(handle, grid)

    # Rendered at the SNAPSHOT cell (1, 2) = index 2*4+1 = 9 …
    assert :binary.at(lenies_bin, 9) == expected
    # … and NOT at the stale cells cell (3, 3) = index 3*4+3 = 15.
    assert :binary.at(lenies_bin, 15) == 0
  end

  test "encode_layers/1 emits 0 for an occupied cell whose lenie has no snapshot yet",
       %{handle: handle} do
    grid = {4, 4}
    reset_cells(handle, grid)

    # Lenie occupies the cell but the `:lenies` snapshot row hasn't been written
    :ets.insert(handle.tables.cells, {{0, 0}, %Lenies.World.Cell{lenie_id: "ORPHAN"}})

    {lenies_bin, _, _, _} = GridRenderer.encode_layers(handle, grid)

    assert :binary.at(lenies_bin, 0) == 0
  end

  test "encode_layers/1 includes resource, carcass, and carcass_hue values", %{handle: handle} do
    grid = {4, 4}
    reset_cells(handle, grid)

    :ets.insert(handle.tables.cells, {
      {0, 0},
      %Lenies.World.Cell{resource: 75, carcass: 30, carcass_hue: 137}
    })

    {_, resource_bin, carcass_bin, carcass_hue_bin} = GridRenderer.encode_layers(handle, grid)
    assert :binary.at(resource_bin, 0) == 75
    assert :binary.at(carcass_bin, 0) == 30
    assert :binary.at(carcass_hue_bin, 0) == 137
  end

  test "encode_payload/2 returns 4 base64-encoded layers in a map", %{handle: handle} do
    grid = {4, 4}
    reset_cells(handle, grid)

    payload = GridRenderer.encode_payload(handle, grid)

    assert %{
             lenies: lenies_b64,
             resource: resource_b64,
             carcass: carcass_b64,
             carcass_hue: carcass_hue_b64,
             width: 4,
             height: 4
           } = payload

    for b64 <- [lenies_b64, resource_b64, carcass_b64, carcass_hue_b64] do
      assert is_binary(b64)
      {:ok, decoded} = Base.decode64(b64)
      assert byte_size(decoded) == 16
    end
  end
end
