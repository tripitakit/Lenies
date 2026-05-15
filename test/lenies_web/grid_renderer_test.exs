defmodule LeniesWeb.GridRendererTest do
  use ExUnit.Case, async: false

  alias LeniesWeb.GridRenderer
  alias Lenies.World.Tables

  setup do
    Tables.create_all()
    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  test "encode_layers/1 returns 4 binaries of grid_w * grid_h bytes" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    {lenies_bin, resource_bin, carcass_bin, carcass_hue_bin} =
      GridRenderer.encode_layers(grid)

    assert byte_size(lenies_bin) == 16
    assert byte_size(resource_bin) == 16
    assert byte_size(carcass_bin) == 16
    assert byte_size(carcass_hue_bin) == 16

    assert lenies_bin == <<0::128>>
    assert resource_bin == <<0::128>>
    assert carcass_bin == <<0::128>>
    assert carcass_hue_bin == <<0::128>>
  end

  test "encode_layers/1 writes the species hue byte into the lenies layer at occupied cells" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    :ets.insert(:cells, {{1, 2}, %Lenies.World.Cell{lenie_id: "L1"}})
    :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "hash-A"}})

    expected_byte = Lenies.SpeciesColor.hue_byte("hash-A")

    {lenies_bin, _, _, _} = GridRenderer.encode_layers(grid)

    # Row-major: byte index = y * w + x = 2 * 4 + 1 = 9
    assert :binary.at(lenies_bin, 9) == expected_byte

    for i <- 0..15, i != 9 do
      assert :binary.at(lenies_bin, i) == 0
    end
  end

  test "encode_layers/1 emits 0 for an occupied cell whose lenie has no snapshot yet" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    # Lenie occupies the cell but the `:lenies` snapshot row hasn't been written
    :ets.insert(:cells, {{0, 0}, %Lenies.World.Cell{lenie_id: "ORPHAN"}})

    {lenies_bin, _, _, _} = GridRenderer.encode_layers(grid)

    assert :binary.at(lenies_bin, 0) == 0
  end

  test "encode_layers/1 includes resource, carcass, and carcass_hue values" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    :ets.insert(:cells, {
      {0, 0},
      %Lenies.World.Cell{resource: 75, carcass: 30, carcass_hue: 137}
    })

    {_, resource_bin, carcass_bin, carcass_hue_bin} = GridRenderer.encode_layers(grid)
    assert :binary.at(resource_bin, 0) == 75
    assert :binary.at(carcass_bin, 0) == 30
    assert :binary.at(carcass_hue_bin, 0) == 137
  end

  test "encode_payload/1 returns 4 base64-encoded layers in a map" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    payload = GridRenderer.encode_payload(grid)

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
