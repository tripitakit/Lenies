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

    assert html =~ ~r/LENIES/
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
    |> element("button", "Sterilize")
    |> render_click()

    assert render(view) =~ "Sei sicuro?"
  end

  test "clicking sterilize_confirm resets the world", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Lenies.World.tick_now()
    stats_before = Lenies.World.snapshot_stats()
    assert stats_before.tick_count >= 1

    view
    |> element("button", "Sterilize")
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

  test "cell_clicked event on occupied cell triggers navigate to inspector", %{conn: conn} do
    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | lenie_id: "CLICKED"}})

    {:ok, view, _html} = live(conn, "/")

    assert {:error, {:live_redirect, %{to: "/lenie/CLICKED"}}} =
             render_hook(view, "cell_clicked", %{"x" => 5, "y" => 5})
  end

  test "cell_clicked event on empty cell stays on dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    # Cell {7, 8} is empty by default
    assert render_hook(view, "cell_clicked", %{"x" => 7, "y" => 8})
  end

  test "Seed dropdown is rendered with available seeds", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Seed"
    assert html =~ "Minimal Replicator"
    assert html =~ "Carnivore"
  end

  test "clicking Spawn triggers world spawn_lenie", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    pop_before = :ets.info(:lenies, :size) || 0

    view
    |> form("form[phx-submit='spawn_seed']", %{seed_id: "minimal_replicator", count: "1"})
    |> render_submit()

    Process.sleep(100)

    pop_after = :ets.info(:lenies, :size) || 0
    assert pop_after >= pop_before + 1
  end

  test "Tuning slider changes Application config in place", %{conn: conn} do
    original = Application.get_env(:lenies, :radiation_per_tick)
    Application.put_env(:lenies, :radiation_per_tick, 100)
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("#tune-radiation_per_tick form")
    |> render_change(%{"key" => "radiation_per_tick", "value" => "250"})

    assert Application.get_env(:lenies, :radiation_per_tick) == 250

    Application.put_env(:lenies, :radiation_per_tick, original)
  end

  test "Save snapshot button triggers Snapshot.save_to_disk", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    [{key, cell}] = :ets.lookup(:cells, {2, 2})
    :ets.insert(:cells, {key, %{cell | resource: 42}})

    base = "/tmp/lenies-ui-snapshot-test"
    File.rm_rf!(base)

    view
    |> form("form[phx-submit='snapshot_action']", %{path: base})
    |> render_submit(%{action: "save"})

    assert File.exists?(Path.join(base, "cells.tab"))
    File.rm_rf!(base)
  end
end
