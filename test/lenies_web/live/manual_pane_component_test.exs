defmodule LeniesWeb.ManualPaneComponentTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LeniesWeb.ManualPaneComponent

  setup do
    case Process.whereis(Lenies.Manual) do
      nil -> {:ok, _} = Lenies.Manual.start_link([])
      _ -> :ok
    end
    :ok
  end

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        id: "manual-pane",
        chapter: "02-opcode-reference.md",
        collapsed?: false
      },
      overrides
    )
  end

  test "renders the chapter selector with all loaded chapters" do
    html = render_component(ManualPaneComponent, base_assigns())
    assert html =~ ~s(id="manual-chapter-select")
    assert html =~ "02-opcode-reference.md"
    assert html =~ "00-introduction.md"
    assert html =~ "10-cookbook.md"
  end

  test "renders the selected chapter's HTML in the content area" do
    html = render_component(ManualPaneComponent, base_assigns())
    assert html =~ "Opcode"
  end

  test "collapsed mode renders only the ribbon, not the dropdown" do
    html = render_component(ManualPaneComponent, base_assigns(%{collapsed?: true}))
    assert html =~ "manual-ribbon"
    refute html =~ ~s(id="manual-chapter-select")
  end

  test "expanded mode does not render the ribbon" do
    html = render_component(ManualPaneComponent, base_assigns(%{collapsed?: false}))
    refute html =~ "manual-ribbon"
  end
end
