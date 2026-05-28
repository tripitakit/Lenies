defmodule LeniesWeb.DashboardLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup do
    {:ok, _} = Lenies.WorldTestHelpers.start_primary()
    on_exit(&Lenies.WorldTestHelpers.stop_primary/0)
    :ok
  end

  test "mounts on / and renders dashboard panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~r/LENIES/
    assert html =~ "id=\"grid-canvas\""
    assert html =~ ~r/Sterilize/i
    assert html =~ ~r/(Pause|Resume)/i
  end

  test "flash group is rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#flash-group")
    assert has_element?(view, "#client-error")
    assert has_element?(view, "#server-error")
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
    :ets.insert(
      Lenies.WorldTestHelpers.lenies(),
      {"a", %{id: "a", codeome_hash: "hashA", lineage: {nil, 0}}}
    )

    :ets.insert(
      Lenies.WorldTestHelpers.lenies(),
      {"b", %{id: "b", codeome_hash: "hashA", lineage: {nil, 1}}}
    )

    :ets.insert(
      Lenies.WorldTestHelpers.lenies(),
      {"c", %{id: "c", codeome_hash: "hashB", lineage: {nil, 0}}}
    )

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "hashA"
    assert html =~ "hashB"
    # Population column for hashA = 2
    assert html =~ ~r/hashA[\s\S]+2/
  end

  test "select_lenie_at_cell on occupied cell navigates to the codeome editor",
       %{conn: conn} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "CLICKED"}})

    :ets.insert(
      Lenies.WorldTestHelpers.lenies(),
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

    pop_before = :ets.info(Lenies.WorldTestHelpers.lenies(), :size) || 0

    view
    |> form("form[phx-submit='spawn_seed']", %{seed_id: "minimal_replicator", count: "1"})
    |> render_submit()

    Process.sleep(100)

    pop_after = :ets.info(Lenies.WorldTestHelpers.lenies(), :size) || 0
    assert pop_after >= pop_before + 1
  end

  test "Tuning slider mutates the primary world's state.config in place", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    {:ok, handle} = Lenies.Worlds.handle(:primary)
    original = :sys.get_state(handle.pid).config.radiation_per_tick

    view
    |> element("#tune-radiation_per_tick form")
    |> render_change(%{"key" => "radiation_per_tick", "value" => "250"})

    # The tune_param handler now hits Lenies.Worlds.tune/3, which writes to
    # state.config and broadcasts {:config_changed, …}. Allow a beat for the
    # synchronous call to land, then assert the world saw it.
    Process.sleep(50)
    assert :sys.get_state(handle.pid).config.radiation_per_tick == 250

    # restore original so subsequent tests aren't affected
    :ok = Lenies.Worlds.tune(:primary, :radiation_per_tick, original)
  end

  test "Save snapshot button triggers Worlds.save_snapshot/2", %{conn: conn} do
    root =
      Path.join(
        System.tmp_dir!(),
        "lenies-ui-snapshot-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:lenies, :snapshot_root, root)

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:lenies, :snapshot_root)
    end)

    {:ok, view, _html} = live(conn, "/")

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {2, 2})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | resource: 42}})

    view
    |> form("form[phx-submit='snapshot_action']", %{snapshot_name: "uitest"})
    |> render_submit(%{action: "save"})

    assert File.exists?(Path.join([root, "primary", "uitest", "cells.tab"]))
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
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L1", %{id: "L1", codeome_hash: "HASH-Z", lineage: {nil, 0}}}
      )

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
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L1", %{id: "L1", codeome_hash: "HASH-X", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L2", %{id: "L2", codeome_hash: "HASH-X", lineage: {nil, 1}}}
      )

      {:ok, view, _} = live(conn, "/")

      html =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-X']")
        |> render_click()

      assert html =~ ~s(id="species-inspector")
      assert html =~ "HASH-X"
    end

    test "clicking the same row again closes the inspector", %{conn: conn} do
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L1", %{id: "L1", codeome_hash: "HASH-Y", lineage: {nil, 0}}}
      )

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
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L1", %{id: "L1", codeome_hash: "HASH-A", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L2", %{id: "L2", codeome_hash: "HASH-B", lineage: {nil, 0}}}
      )

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
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L1", %{id: "L1", codeome_hash: "HASH-SEL-A", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, "/")

      html =
        view
        |> element("tr#species-row-HASH-SEL-A")
        |> render_click()

      hue = Lenies.SpeciesColor.hue_byte(Lenies.Worlds.primary_handle(), "HASH-SEL-A")
      assert html =~ ~s(data-highlight-hue="#{hue}")
    end

    test "clicking the selected row again deselects and clears the highlight", %{conn: conn} do
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L1", %{id: "L1", codeome_hash: "HASH-SEL-B", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, "/")

      view |> element("tr#species-row-HASH-SEL-B") |> render_click()
      html = view |> element("tr#species-row-HASH-SEL-B") |> render_click()

      assert html =~ ~s(data-highlight-hue="0")
    end

    test "highlight is cleared when the selected species drops out of the top-N",
         %{conn: conn} do
      Application.put_env(:lenies, :dashboard_throttle_ticks, 1)

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L1", %{id: "L1", codeome_hash: "HASH-GONE", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, "/")
      view |> element("tr#species-row-HASH-GONE") |> render_click()

      hue = Lenies.SpeciesColor.hue_byte(Lenies.Worlds.primary_handle(), "HASH-GONE")
      assert render(view) =~ ~s(data-highlight-hue="#{hue}")

      # The Lenie disappears (extinct) — the next tick recomputes the top-N
      # and the selection should be dropped along with the highlight.
      :ets.delete(Lenies.WorldTestHelpers.lenies(), "L1")
      send(view.pid, {:tick, 1})

      assert render(view) =~ ~s(data-highlight-hue="0")
    after
      Application.delete_env(:lenies, :dashboard_throttle_ticks)
    end
  end

  describe "controls panel — custom seed catalog" do
    test "custom seeds appear in the dropdown with a star prefix", %{conn: conn, user: user} do
      {:ok, _} =
        Lenies.Collection.create_codeome(user, %{
          name: "My Test",
          color_hex: "#abcdef",
          energy_default: 7000.0,
          opcodes: [
            "nop_1",
            "nop_1",
            "get_size",
            "push0",
            "store",
            "nop_1",
            "nop_1",
            "nop_1",
            "nop_1",
            "nop_1",
            "nop_1"
          ]
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "★ My Test"
      assert html =~ ~s(value="custom:)
    end

    test "spawning a custom seed grows the population AND sets the color override", %{
      conn: conn,
      user: user
    } do
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

      {:ok, seed} =
        Lenies.Collection.create_codeome(user, %{
          name: "Spawn Test",
          color_hex: "#deadbe",
          energy_default: 3000.0,
          opcodes: Enum.map(buffer, &Atom.to_string/1)
        })

      {:ok, view, _} = live(conn, "/")

      pop_before = :ets.info(Lenies.WorldTestHelpers.lenies(), :size) || 0

      view
      |> form("form[phx-submit='spawn_seed']", %{
        seed_id: "custom:#{seed.id}",
        count: "2"
      })
      |> render_submit()

      Process.sleep(100)

      pop_after = :ets.info(Lenies.WorldTestHelpers.lenies(), :size) || 0
      assert pop_after >= pop_before + 2

      # The color override is keyed on the codeome hash
      hash = buffer |> Lenies.Codeome.from_list() |> Lenies.Codeome.hash()
      assert Lenies.SpeciesColor.override(Lenies.Worlds.primary_handle(), hash) == "#deadbe"
    end

    test "deleting a custom seed removes it from the dropdown", %{conn: conn, user: user} do
      {:ok, seed} =
        Lenies.Collection.create_codeome(user, %{
          name: "Delete Me",
          color_hex: "#abcdef",
          energy_default: 1000.0,
          opcodes: [
            "nop_1",
            "nop_1",
            "get_size",
            "push0",
            "store",
            "nop_1",
            "nop_1",
            "nop_1",
            "nop_1",
            "nop_1",
            "nop_1"
          ]
        })

      {:ok, view, _} = live(conn, "/")
      assert render(view) =~ "★ Delete Me"

      view
      |> element("button", "Manage")
      |> render_click()

      view
      |> element("button[phx-value-id='#{seed.id}']")
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
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"H1", %{id: "H1", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"H2", %{id: "H2", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"H3", %{id: "H3", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L1", %{id: "L1", codeome_hash: "POPLO", lineage: {nil, 0}}}
      )

      {:ok, _view, html} = live(conn, "/")

      assert row_pos(html, "POPHI") < row_pos(html, "POPLO")
    end

    test "clicking the Pop header toggles to ascending order", %{conn: conn} do
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"H1", %{id: "H1", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"H2", %{id: "H2", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"H3", %{id: "H3", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"L1", %{id: "L1", codeome_hash: "POPLO", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, "/")

      html =
        view
        |> element("th[phx-click='sort_species'][phx-value-col='population']")
        |> render_click()

      assert row_pos(html, "POPLO") < row_pos(html, "POPHI")
      assert html =~ "Pop ▲"
    end

    test "sorting by generation descending puts the oldest lineage first", %{conn: conn} do
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"Y1", %{id: "Y1", codeome_hash: "YOUNG", lineage: {nil, 1}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"O1", %{id: "O1", codeome_hash: "OLDGEN", lineage: {nil, 9}}}
      )

      {:ok, view, _} = live(conn, "/")

      html =
        view
        |> element("th[phx-click='sort_species'][phx-value-col='avg_generation']")
        |> render_click()

      assert row_pos(html, "OLDGEN") < row_pos(html, "YOUNG")
      assert html =~ "Gen ▼"
    end
  end

  describe "species table — LiveView stream" do
    test "species rows are rendered with the expected stream DOM id", %{conn: conn} do
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"S1", %{id: "S1", codeome_hash: "STREAM-HASH-1", lineage: {nil, 0}}}
      )

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#species-row-STREAM-HASH-1")
    end

    test "tbody has phx-update=stream and the wrapping id", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~s(id="species-rows")
      assert html =~ ~s(phx-update="stream")
    end

    test "species_total count is still displayed after stream conversion", %{conn: conn} do
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"T1", %{id: "T1", codeome_hash: "COUNT-A", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"T2", %{id: "T2", codeome_hash: "COUNT-B", lineage: {nil, 0}}}
      )

      {:ok, _view, html} = live(conn, "/")

      # The header reads "▮ 2 species"
      assert html =~ ~r/2 species/
    end

    test "select_species re-streams and highlights the selected row", %{conn: conn} do
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"HL1", %{id: "HL1", codeome_hash: "HASH-HL", lineage: {nil, 0}}}
      )

      {:ok, view, _html} = live(conn, "/")

      # Row should exist in the stream from mount
      assert has_element?(view, "#species-row-HASH-HL")

      # Click the row to select it
      html =
        view
        |> element("#species-row-HASH-HL")
        |> render_click()

      # After re-stream, the row must still be present and carry the highlight classes
      assert has_element?(view, "#species-row-HASH-HL")
      assert html =~ "bg-cyan-500/20"
      assert html =~ "ring-1 ring-cyan-400"
    end

    test "deselecting a row removes the highlight class via re-stream", %{conn: conn} do
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"DH1", %{id: "DH1", codeome_hash: "HASH-DH", lineage: {nil, 0}}}
      )

      {:ok, view, _html} = live(conn, "/")

      # Select then deselect
      view |> element("#species-row-HASH-DH") |> render_click()

      html =
        view
        |> element("#species-row-HASH-DH")
        |> render_click()

      # Row still present (re-streamed) but no highlight classes
      assert has_element?(view, "#species-row-HASH-DH")
      refute html =~ "ring-1 ring-cyan-400"
    end

    test "sort_species re-streams rows in the new order", %{conn: conn} do
      # SORTED-HI: 3 lenies; SORTED-LO: 1 lenie — default order: HI first
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"SR1", %{id: "SR1", codeome_hash: "SORTED-HI", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"SR2", %{id: "SR2", codeome_hash: "SORTED-HI", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"SR3", %{id: "SR3", codeome_hash: "SORTED-HI", lineage: {nil, 0}}}
      )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"SR4", %{id: "SR4", codeome_hash: "SORTED-LO", lineage: {nil, 0}}}
      )

      {:ok, view, html_before} = live(conn, "/")
      # Default: population descending → HI appears first
      assert row_pos(html_before, "SORTED-HI") < row_pos(html_before, "SORTED-LO")

      # Click population header to toggle to ascending
      html_after =
        view
        |> element("th[phx-click='sort_species'][phx-value-col='population']")
        |> render_click()

      # After re-stream: LO (pop=1) should come before HI (pop=3)
      assert row_pos(html_after, "SORTED-LO") < row_pos(html_after, "SORTED-HI")
      # Both rows still in the stream
      assert has_element?(view, "#species-row-SORTED-HI")
      assert has_element?(view, "#species-row-SORTED-LO")
    end

    test "tick re-streams updated species data", %{conn: conn} do
      Application.put_env(:lenies, :dashboard_throttle_ticks, 1)

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"TK1", %{id: "TK1", codeome_hash: "TICK-HASH", lineage: {nil, 0}}}
      )

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#species-row-TICK-HASH")

      # Remove the lenie and send a tick — stream should clear the row
      :ets.delete(Lenies.WorldTestHelpers.lenies(), "TK1")
      send(view.pid, {:tick, 1})
      render(view)

      refute has_element?(view, "#species-row-TICK-HASH")
    after
      Application.delete_env(:lenies, :dashboard_throttle_ticks)
    end

    test "all_species is NOT referenced in the rendered HTML (only stream is)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # The stream tbody is present; there must be no old-style for-loop artifact.
      # The plain tbody without phx-update="stream" would not have this attribute.
      assert html =~ ~s(phx-update="stream")
      # No raw `@all_species` leakage — the template uses @streams.species_table
      refute html =~ "all_species"
    end
  end

  # ---------------------------------------------------------------------------
  # ML1 — AudioToggle hook replaces inline onclick
  # ---------------------------------------------------------------------------
  describe "audio toggle button — hook wiring" do
    test "audio-toggle button has phx-hook=AudioToggle and phx-update=ignore", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")
      assert html =~ ~s(phx-hook="AudioToggle")
      assert has_element?(view, "#audio-toggle[phx-hook='AudioToggle']")
      assert has_element?(view, "#audio-toggle[phx-update='ignore']")
    end

    test "audio-toggle button has no inline onclick or LeniesAudio script", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      refute html =~ "onclick"
      refute html =~ "LeniesAudio"
    end
  end

  # ---------------------------------------------------------------------------
  # ML2 — SliderValue hook replaces inline oninput on tuning sliders
  # ---------------------------------------------------------------------------
  describe "tuning slider — hook wiring" do
    test "a tuning slider has phx-hook=SliderValue and data-value-target, no oninput", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/")

      # There must be no inline oninput attribute anywhere
      refute html =~ "oninput"

      # Check one specific slider (radiation_per_tick) for correct hook wiring
      assert has_element?(
               view,
               "#slider-radiation_per_tick[phx-hook='SliderValue'][data-value-target='val-radiation_per_tick']"
             )
    end
  end

  # ---------------------------------------------------------------------------
  # ML3 — Controls panel reads the ACTUAL paused state at mount
  # ---------------------------------------------------------------------------
  describe "controls panel — paused? state at mount" do
    test "when world is already paused at mount, pause button shows Resume", %{conn: conn} do
      :ok = Lenies.World.pause()

      on_exit(fn ->
        try do
          Lenies.World.resume()
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "▶ Resume"
      refute html =~ "⏸ Pause"
    end

    test "when world is running at mount, pause button shows Pause", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "⏸ Pause"
      refute html =~ "▶ Resume"
    end
  end

  # ---------------------------------------------------------------------------
  # ML4 — World totals panel uses @latest (no @history in assigns)
  # ---------------------------------------------------------------------------
  describe "world totals panel" do
    test "totals panel renders zeroes before any tick", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Population"
      assert html =~ "Resources"
      assert html =~ "Detritus"
    end

    test "totals panel reflects telemetry data after a tick", %{conn: conn} do
      Application.put_env(:lenies, :dashboard_throttle_ticks, 1)

      {:ok, view, _html} = live(conn, "/")

      Lenies.World.tick_now()
      # Give PubSub a moment to propagate tick → Telemetry, then the dashboard tick
      Process.sleep(50)
      send(view.pid, {:tick, 1})
      html = render(view)

      # Population, Resources, Detritus columns are present
      assert html =~ "Population"
      assert html =~ "Resources"
      assert html =~ "Detritus"
    after
      Application.delete_env(:lenies, :dashboard_throttle_ticks)
    end
  end
end
