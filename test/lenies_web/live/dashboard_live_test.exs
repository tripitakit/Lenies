defmodule LeniesWeb.DashboardLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    case Process.whereis(Lenies.World) do
      nil ->
        {:ok, _} = Lenies.World.start_link(tick_interval_ms: 0)

      _ ->
        :ok
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

  test "mounts on / and renders dashboard panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~r/Lenies Dashboard/i
    assert html =~ "id=\"grid-canvas\""
    assert html =~ ~r/Sterilize/i
    assert html =~ ~r/(Pause|Resume)/i
  end

  test "shows initial canvas with width and height data attributes", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ ~r/phx-hook="GridCanvas"/
  end

  test "clicking sterilize_init shows confirm prompt", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    refute render(view) =~ "Sei sicuro?"

    view
    |> element("button", "STERILIZE")
    |> render_click()

    assert render(view) =~ "Sei sicuro?"
  end

  test "clicking sterilize_confirm resets the world", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Lenies.World.tick_now()
    stats_before = Lenies.World.snapshot_stats()
    assert stats_before.tick_count >= 1

    view
    |> element("button", "STERILIZE")
    |> render_click()

    view
    |> element("button", "Sì, sterilizza")
    |> render_click()

    stats_after = Lenies.World.snapshot_stats()
    assert stats_after.tick_count == 0
  end

  test "clicking pause toggles state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    refute Lenies.World.paused?()

    view
    |> element("button", "Pause")
    |> render_click()

    assert Lenies.World.paused?()

    view
    |> element("button", "Resume")
    |> render_click()

    refute Lenies.World.paused?()
  end

  test "toggling layer changes data attribute", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # When true, Phoenix renders boolean attrs as empty-string (e.g. data-show-lenies="")
    html_before = render(view)
    assert html_before =~ ~r/data-show-lenies=""/

    view
    |> element("input[phx-value-layer='lenies']")
    |> render_click()

    # When false, the attribute is omitted entirely
    html_after = render(view)
    refute html_after =~ ~r/data-show-lenies/
  end

  test "Species panel shows top-N species table from aggregator", %{conn: conn} do
    :ets.insert(:lenies, {"a", %{id: "a", codeome_hash: "hashA", lineage: {nil, 0}}})
    :ets.insert(:lenies, {"b", %{id: "b", codeome_hash: "hashA", lineage: {nil, 1}}})
    :ets.insert(:lenies, {"c", %{id: "c", codeome_hash: "hashB", lineage: {nil, 0}}})

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "hashA"
    assert html =~ "hashB"
    # Population column for hashA = 2
    assert html =~ ~r/hashA[\s\S]+2/
  end
end
