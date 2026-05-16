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
end
