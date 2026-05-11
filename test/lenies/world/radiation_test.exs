defmodule Lenies.World.RadiationTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Radiation

  @grid {256, 256}

  test "uniform_deposit/3 sums approximately to amount across all cells" do
    deposit = Radiation.uniform_deposit(@grid, 65_536)
    total = Map.values(deposit) |> Enum.sum()
    assert total == 65_536
    # ogni cella riceve almeno 1 (con amount = cells totali)
    assert Enum.all?(Map.values(deposit), &(&1 >= 1))
  end

  test "uniform_deposit/3 with small amount picks random cells" do
    deposit = Radiation.uniform_deposit(@grid, 100)
    total = Map.values(deposit) |> Enum.sum()
    assert total == 100
    # ~100 celle scelte (con duplicati possibili → ≤ 100)
    assert map_size(deposit) <= 100
  end

  test "hotspot_deposit/3 concentrates around hotspot centers" do
    hotspots = [{128, 128}, {0, 0}]
    deposit = Radiation.hotspot_deposit(@grid, 1000, hotspots, radius: 5)
    total = Map.values(deposit) |> Enum.sum()
    assert total == 1000
    # tutte le posizioni depositate sono entro `radius` da un hotspot (toroide)
    for {{x, y}, _} <- deposit do
      assert Enum.any?(hotspots, fn {hx, hy} ->
               toroidal_dist({x, y}, {hx, hy}, @grid) <= 5
             end)
    end
  end

  test "combined/3 distributes amount per uniform_ratio" do
    hotspots = [{128, 128}]
    deposit = Radiation.combined(@grid, 100, hotspots, uniform_ratio: 0.7, hotspot_radius: 5)
    total = Map.values(deposit) |> Enum.sum()
    assert total == 100
  end

  # toroidal Manhattan distance helper
  defp toroidal_dist({x1, y1}, {x2, y2}, {w, h}) do
    dx = min(abs(x1 - x2), w - abs(x1 - x2))
    dy = min(abs(y1 - y2), h - abs(y1 - y2))
    dx + dy
  end
end
