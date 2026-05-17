defmodule LeniesWeb.EditorLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    case Process.whereis(Lenies.World) do
      nil -> {:ok, _} = Lenies.World.start_link(tick_interval_ms: 0)
      _ -> :ok
    end

    case Process.whereis(Lenies.Manual) do
      nil -> {:ok, _} = Lenies.Manual.start_link([])
      _ -> :ok
    end

    on_exit(fn ->
      case Process.whereis(Lenies.World) do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      Lenies.World.Tables.delete_all()
    end)

    :ok
  end

  test "mounts on /editor/new with empty buffer", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/editor/new")
    assert html =~ "New Seed"
    assert html =~ ~s(id="manual-pane")
  end

  test "mounts on /editor/edit/:hash with empty buffer when hash unknown", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/editor/edit/NONEXISTENT")
    assert html =~ "Edit: NONEXISTENT"
    assert html =~ "0 ops"
  end

  test "toggling the manual pane updates the grid class", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    refute render(view) =~ "manual-collapsed"

    render_hook(view, "toggle_manual", %{})

    assert render(view) =~ "manual-collapsed"
  end

  test "selecting a chapter updates the current chapter", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "select_chapter", %{"chapter" => "04-loops-and-templates.md"})

    html = render(view)
    assert html =~ ~r/Loops|Templates/
  end
end
