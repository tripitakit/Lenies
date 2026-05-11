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
end
