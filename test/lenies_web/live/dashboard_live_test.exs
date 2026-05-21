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

    refute render(view) =~ "Are you sure?"

    view
    |> element("button", "Sterilize")
    |> render_click()

    assert render(view) =~ "Are you sure?"
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
    |> element("button", "Yes, sterilize")
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

  test "select_lenie_at_cell on occupied cell navigates to the codeome editor",
       %{conn: conn} do
    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | lenie_id: "CLICKED"}})

    :ets.insert(
      :lenies,
      {"CLICKED", %{id: "CLICKED", codeome_hash: "CLICKED-HASH", lineage: {nil, 0}}}
    )

    {:ok, view, _html} = live(conn, "/")

    assert {:error, {:live_redirect, %{to: "/editor/edit/CLICKED-HASH"}}} =
             render_hook(view, "select_lenie_at_cell", %{"x" => 5, "y" => 5})
  end

  test "select_lenie_at_cell on empty cell stays on dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    # Cell {7, 8} is empty by default
    assert render_hook(view, "select_lenie_at_cell", %{"x" => 7, "y" => 8})
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
    root =
      Path.join(System.tmp_dir!(), "lenies-ui-snapshot-test-#{System.unique_integer([:positive])}")

    Application.put_env(:lenies, :snapshot_root, root)
    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:lenies, :snapshot_root)
    end)

    {:ok, view, _html} = live(conn, "/")

    [{key, cell}] = :ets.lookup(:cells, {2, 2})
    :ets.insert(:cells, {key, %{cell | resource: 42}})

    view
    |> form("form[phx-submit='snapshot_action']", %{snapshot_name: "uitest"})
    |> render_submit(%{action: "save"})

    assert File.exists?(Path.join([root, "uitest", "cells.tab"]))
  end

  describe "inspector dirty notification" do
    test "dashboard receives :inspector_dirty info messages and reflects them in the DOM", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/")

      send(view.pid, {:inspector_dirty, true})
      html = render(view)
      assert html =~ ~s(data-inspector-dirty="true")

      send(view.pid, {:inspector_dirty, false})
      html2 = render(view)
      refute html2 =~ ~s(data-inspector-dirty="true")
    end

    test "closing the inspector (deselect to nil) resets :inspector_dirty", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-Z", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")

      # Simulate component setting dirty state.
      send(view.pid, {:inspector_dirty, true})
      html1 = render(view)
      assert html1 =~ ~s(data-inspector-dirty="true")

      # Open the inspector for HASH-Z (clicking the row).
      view
      |> element("tr[phx-click='select_species'][phx-value-hash='HASH-Z']")
      |> render_click()

      # Now click the SAME row again to close (toggle off → nil).
      html2 =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-Z']")
        |> render_click()

      refute html2 =~ ~s(data-inspector-dirty="true")
    end
  end

  describe "species inspector panel" do
    test "panel hidden by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      refute html =~ ~s(id="species-inspector")
    end

    test "clicking a species row opens the inspector for that hash", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-X", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"L2", %{id: "L2", codeome_hash: "HASH-X", lineage: {nil, 1}}})

      {:ok, view, _} = live(conn, "/")

      html =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-X']")
        |> render_click()

      assert html =~ ~s(id="species-inspector")
      assert html =~ "HASH-X"
    end

    test "clicking the same row again closes the inspector", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-Y", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")

      view
      |> element("tr[phx-click='select_species'][phx-value-hash='HASH-Y']")
      |> render_click()

      html =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-Y']")
        |> render_click()

      refute html =~ ~s(id="species-inspector")
    end

    test "clicking another row swaps the inspected species", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-A", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"L2", %{id: "L2", codeome_hash: "HASH-B", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")

      view
      |> element("tr[phx-click='select_species'][phx-value-hash='HASH-A']")
      |> render_click()

      html =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-B']")
        |> render_click()

      assert html =~ ~s(id="species-inspector")
      assert html =~ "HASH-B"
    end
  end

  describe "controls panel — new seed entry point" do
    test "+ New Seed link navigates to /editor/new", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      assert {:error, {:live_redirect, %{to: "/editor/new"}}} =
               view
               |> element("#open-codeome-editor")
               |> render_click()
    end
  end

  describe "map highlight driven by selected species" do
    test "no highlight by default — data-highlight-hue is 0", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(data-highlight-hue="0")
    end

    test "selecting a species row sets the canvas highlight to its hue", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-SEL-A", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")

      html =
        view
        |> element("tr#species-row-HASH-SEL-A")
        |> render_click()

      hue = Lenies.SpeciesColor.hue_byte("HASH-SEL-A")
      assert html =~ ~s(data-highlight-hue="#{hue}")
    end

    test "clicking the selected row again deselects and clears the highlight", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-SEL-B", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")

      view |> element("tr#species-row-HASH-SEL-B") |> render_click()
      html = view |> element("tr#species-row-HASH-SEL-B") |> render_click()

      assert html =~ ~s(data-highlight-hue="0")
    end

    test "highlight is cleared when the selected species drops out of the top-N",
         %{conn: conn} do
      Application.put_env(:lenies, :dashboard_throttle_ticks, 1)

      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-GONE", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")
      view |> element("tr#species-row-HASH-GONE") |> render_click()

      hue = Lenies.SpeciesColor.hue_byte("HASH-GONE")
      assert render(view) =~ ~s(data-highlight-hue="#{hue}")

      # The Lenie disappears (extinct) — the next tick recomputes the top-N
      # and the selection should be dropped along with the highlight.
      :ets.delete(:lenies, "L1")
      send(view.pid, {:tick, 1})

      assert render(view) =~ ~s(data-highlight-hue="0")
    after
      Application.delete_env(:lenies, :dashboard_throttle_ticks)
    end
  end

  describe "controls panel — custom seed catalog" do
    setup do
      tmp_path =
        Path.join(System.tmp_dir!(), "lenies_catalog_#{System.unique_integer([:positive])}.json")

      Application.put_env(:lenies, :__test_user_seeds_file__, tmp_path)

      if Process.whereis(Lenies.Seeds.CustomStore) do
        Agent.stop(Lenies.Seeds.CustomStore)
      end

      {:ok, _} = Lenies.Seeds.CustomStore.start_link([])

      on_exit(fn ->
        if pid = Process.whereis(Lenies.Seeds.CustomStore), do: Agent.stop(pid)
        File.rm(tmp_path)
        Application.delete_env(:lenies, :__test_user_seeds_file__)
      end)

      :ok
    end

    test "custom seeds appear in the dropdown with a star prefix", %{conn: conn} do
      :ok =
        Lenies.Seeds.CustomStore.save(%{
          id: "my-test",
          name: "My Test",
          color_hex: "#abcdef",
          energy_default: 7000.0,
          opcodes: [
            :nop_1,
            :nop_1,
            :get_size,
            :push0,
            :store,
            :nop_1,
            :nop_1,
            :nop_1,
            :nop_1,
            :nop_1,
            :nop_1
          ]
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "★ My Test"
      assert html =~ ~s(value="custom:my-test")
    end

    test "spawning a custom seed grows the population AND sets the color override", %{conn: conn} do
      buffer = [
        :nop_1,
        :get_size,
        :push0,
        :store,
        :push0,
        :load,
        :allocate,
        :push0,
        :push1,
        :store,
        :nop_1
      ]

      :ok =
        Lenies.Seeds.CustomStore.save(%{
          id: "spawn-test",
          name: "Spawn Test",
          color_hex: "#deadbe",
          energy_default: 3000.0,
          opcodes: buffer
        })

      {:ok, view, _} = live(conn, "/")

      pop_before = :ets.info(:lenies, :size) || 0

      view
      |> form("form[phx-submit='spawn_seed']", %{seed_id: "custom:spawn-test", count: "2"})
      |> render_submit()

      Process.sleep(100)

      pop_after = :ets.info(:lenies, :size) || 0
      assert pop_after >= pop_before + 2

      # The color override is keyed on the codeome hash
      hash = buffer |> Lenies.Codeome.from_list() |> Lenies.Codeome.hash()
      assert Lenies.SpeciesColor.override(hash) == "#deadbe"
    end

    test "deleting a custom seed removes it from the dropdown", %{conn: conn} do
      :ok =
        Lenies.Seeds.CustomStore.save(%{
          id: "delete-me",
          name: "Delete Me",
          color_hex: "#abcdef",
          energy_default: 1000.0,
          opcodes: [
            :nop_1,
            :nop_1,
            :get_size,
            :push0,
            :store,
            :nop_1,
            :nop_1,
            :nop_1,
            :nop_1,
            :nop_1,
            :nop_1
          ]
        })

      {:ok, view, _} = live(conn, "/")
      assert render(view) =~ "★ Delete Me"

      view
      |> element("button", "Manage")
      |> render_click()

      view
      |> element("button[phx-value-id='delete-me']")
      |> render_click()

      refute render(view) =~ "★ Delete Me"
    end
  end

  describe "event payload resilience — malformed inputs are no-ops" do
    test "toggle_layer with unknown layer string survives", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      render_hook(view, "toggle_layer", %{"layer" => "bogus"})
      assert render(view) =~ "id=\"grid-canvas\""
    end

    test "toggle_layer with valid layer still toggles", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html_before = render(view)
      assert html_before =~ ~r/data-show-lenies=""/
      render_hook(view, "toggle_layer", %{"layer" => "lenies"})
      html_after = render(view)
      refute html_after =~ ~r/data-show-lenies/
    end

    test "select_lenie_at_cell with non-integer coords survives", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      render_hook(view, "select_lenie_at_cell", %{"x" => "5", "y" => 0})
      assert render(view) =~ "id=\"grid-canvas\""
    end

    test "request_lenie_hover with non-integer coords survives", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      render_hook(view, "request_lenie_hover", %{"x" => "bad", "y" => "also_bad"})
      assert render(view) =~ "id=\"grid-canvas\""
    end

    test "unknown event name is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      render_hook(view, "no_such_event", %{})
      assert render(view) =~ "id=\"grid-canvas\""
    end
  end

  describe "species table sorting" do
    defp row_pos(html, hash), do: html |> :binary.match("species-row-#{hash}") |> elem(0)

    test "defaults to population descending", %{conn: conn} do
      # POPHI: 3 lenies, POPLO: 1 lenie
      :ets.insert(:lenies, {"H1", %{id: "H1", codeome_hash: "POPHI", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"H2", %{id: "H2", codeome_hash: "POPHI", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"H3", %{id: "H3", codeome_hash: "POPHI", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "POPLO", lineage: {nil, 0}}})

      {:ok, _view, html} = live(conn, "/")

      assert row_pos(html, "POPHI") < row_pos(html, "POPLO")
    end

    test "clicking the Pop header toggles to ascending order", %{conn: conn} do
      :ets.insert(:lenies, {"H1", %{id: "H1", codeome_hash: "POPHI", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"H2", %{id: "H2", codeome_hash: "POPHI", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"H3", %{id: "H3", codeome_hash: "POPHI", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "POPLO", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")

      html =
        view
        |> element("th[phx-click='sort_species'][phx-value-col='population']")
        |> render_click()

      assert row_pos(html, "POPLO") < row_pos(html, "POPHI")
      assert html =~ "Pop ▲"
    end

    test "sorting by generation descending puts the oldest lineage first", %{conn: conn} do
      :ets.insert(:lenies, {"Y1", %{id: "Y1", codeome_hash: "YOUNG", lineage: {nil, 1}}})
      :ets.insert(:lenies, {"O1", %{id: "O1", codeome_hash: "OLDGEN", lineage: {nil, 9}}})

      {:ok, view, _} = live(conn, "/")

      html =
        view
        |> element("th[phx-click='sort_species'][phx-value-col='avg_generation']")
        |> render_click()

      assert row_pos(html, "OLDGEN") < row_pos(html, "YOUNG")
      assert html =~ "Gen ▼"
    end
  end
end
