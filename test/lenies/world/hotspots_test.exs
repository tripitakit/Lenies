defmodule Lenies.World.HotspotsTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Hotspots

  @grid {256, 256}

  test "initial/2 returns n hotspots on grid" do
    hs = Hotspots.initial(@grid, 8)
    assert length(hs) == 8

    for {x, y} <- hs do
      assert x in 0..255
      assert y in 0..255
    end
  end

  test "drift/2 keeps hotspots within grid (toroidal wrap)" do
    hs = [{0, 0}, {255, 255}]
    hs2 = Hotspots.drift(hs, @grid)
    assert length(hs2) == 2

    for {x, y} <- hs2 do
      assert x in 0..255
      assert y in 0..255
    end
  end

  test "drift/2 moves each hotspot by at most ±1 in each axis" do
    hs = [{100, 100}]
    [{x, y}] = Hotspots.drift(hs, @grid)
    dx = min(abs(x - 100), 256 - abs(x - 100))
    dy = min(abs(y - 100), 256 - abs(y - 100))
    assert dx <= 1
    assert dy <= 1
  end
end
