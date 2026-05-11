defmodule LeniesWeb.GridRendererTest do
  use ExUnit.Case, async: false

  alias LeniesWeb.GridRenderer
  alias Lenies.World.Tables

  setup do
    Tables.create_all()
    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  test "encode_layers/1 returns 3 binaries of grid_w * grid_h bytes" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    {lenies_bin, resource_bin, carcass_bin} = GridRenderer.encode_layers(grid)

    assert byte_size(lenies_bin) == 16
    assert byte_size(resource_bin) == 16
    assert byte_size(carcass_bin) == 16

    assert lenies_bin == <<0::128>>
    assert resource_bin == <<0::128>>
    assert carcass_bin == <<0::128>>
  end

  test "encode_layers/1 marks lenie_id cells as 1 in lenies layer" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    :ets.insert(:cells, {{1, 2}, %Lenies.World.Cell{lenie_id: "L1"}})

    {lenies_bin, _, _} = GridRenderer.encode_layers(grid)

    # Row-major: byte index = y * w + x = 2 * 4 + 1 = 9
    assert :binary.at(lenies_bin, 9) == 1

    for i <- 0..15, i != 9 do
      assert :binary.at(lenies_bin, i) == 0
    end
  end

  test "encode_layers/1 includes resource and carcass values" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    :ets.insert(:cells, {{0, 0}, %Lenies.World.Cell{resource: 75, carcass: 30}})

    {_, resource_bin, carcass_bin} = GridRenderer.encode_layers(grid)
    assert :binary.at(resource_bin, 0) == 75
    assert :binary.at(carcass_bin, 0) == 30
  end

  test "encode_payload/1 returns base64-encoded layers in a map" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    payload = GridRenderer.encode_payload(grid)

    assert %{
             lenies: lenies_b64,
             resource: resource_b64,
             carcass: carcass_b64,
             width: 4,
             height: 4
           } = payload

    assert is_binary(lenies_b64)
    assert String.length(lenies_b64) >= 20

    {:ok, decoded} = Base.decode64(lenies_b64)
    assert byte_size(decoded) == 16
  end
end
