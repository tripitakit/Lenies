defmodule LeniesWeb.WorldDetailComponentTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LeniesWeb.WorldDetailComponent

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        id: "world-detail",
        species: [],
        highlight_hash: nil,
        grid: {256, 256}
      },
      overrides
    )
  end

  test "renders the modal aside with the close button" do
    html = render_component(WorldDetailComponent, base_assigns())
    assert html =~ ~s(id="world-detail")
    assert html =~ ~s(id="world-detail-close")
    assert html =~ "World detail"
  end

  test "renders the world canvas with grid width/height from assigns" do
    html = render_component(WorldDetailComponent, base_assigns(%{grid: {256, 256}}))
    assert html =~ ~s(id="world-detail-canvas")
    assert html =~ ~s(data-grid-width="256")
    assert html =~ ~s(data-grid-height="256")
    assert html =~ ~s(phx-hook="WorldDetailCanvas")
  end

  test "data-highlight-hue is 0 when no species is selected" do
    html = render_component(WorldDetailComponent, base_assigns(%{highlight_hash: nil}))
    assert html =~ ~s(data-highlight-hue="0")
  end

  test "data-highlight-hue is the hue byte of the selected species" do
    hash = "HASH-WD-HL"
    expected_hue = Lenies.SpeciesColor.hue_byte(hash)
    html = render_component(WorldDetailComponent, base_assigns(%{highlight_hash: hash}))
    assert html =~ ~s(data-highlight-hue="#{expected_hue}")
  end

  test "species list rows are sorted by population descending" do
    species = [
      %{hash: "AAAA1111", population: 5, avg_generation: 1.0},
      %{hash: "BBBB2222", population: 17, avg_generation: 1.0},
      %{hash: "CCCC3333", population: 11, avg_generation: 1.0}
    ]

    html = render_component(WorldDetailComponent, base_assigns(%{species: species}))

    # Pull every hash short-id in order of appearance and assert it matches
    # the population-desc order: BBBB(17), CCCC(11), AAAA(5).
    hashes =
      Regex.scan(~r/world-detail-species-hash">([A-F0-9]{8})</, html)
      |> Enum.map(fn [_, h] -> h end)

    assert hashes == ["BBBB2222", "CCCC3333", "AAAA1111"]
  end

  test "empty species list shows the no-active-species notice" do
    html = render_component(WorldDetailComponent, base_assigns(%{species: []}))
    assert html =~ "No active species"
  end

  test "selected species row carries the .selected class" do
    species = [
      %{hash: "BBBB2222", population: 5, avg_generation: 1.0},
      %{hash: "AAAA1111", population: 3, avg_generation: 1.0}
    ]

    html =
      render_component(
        WorldDetailComponent,
        base_assigns(%{species: species, highlight_hash: "BBBB2222"})
      )

    assert html =~ ~s(world-detail-species-row selected)
  end

  test "the aside has a phx-window-keydown handler for Escape" do
    html = render_component(WorldDetailComponent, base_assigns())
    assert html =~ ~s(phx-window-keydown="close_world_detail")
    assert html =~ ~s(phx-key="Escape")
  end
end
