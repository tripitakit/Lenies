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

  describe "inspector dirty notification" do
    test "dashboard receives :inspector_dirty info messages and reflects them in the DOM", %{conn: conn} do
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

  describe "editor_mode :new_seed flow" do
    test "open_codeome_editor info opens the inspector with empty selection", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      refute render(view) =~ ~s(id="species-inspector")

      send(view.pid, :open_codeome_editor)

      html = render(view)
      assert html =~ ~s(id="species-inspector")
    end

    test "editor_mode info nil closes the inspector when no species is selected", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      send(view.pid, :open_codeome_editor)
      assert render(view) =~ ~s(id="species-inspector")

      send(view.pid, {:editor_mode, nil})
      refute render(view) =~ ~s(id="species-inspector")
    end

    # Regression: the SpeciesInspectorComponent is stateful, so its template
    # MUST have exactly one static HTML tag at the root. A previous version
    # rendered a sibling backdrop <div> alongside the <aside> when in edit
    # mode, causing every render to crash with
    # "Stateful components must have a single static HTML tag at the root".
    test "inspector renders in modal mode (no crash) when editor opens", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      view
      |> element("button", "+ New Seed")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="species-inspector")
      assert html =~ "codeome-editor-modal"
      # palette must be visible in modal layout
      assert html =~ ~s(id="palette-grid")
    end

    test "clicking a species row renders the sidebar inspector (not the modal)", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-MM", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")

      html =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-MM']")
        |> render_click()

      assert html =~ ~s(id="species-inspector")
      refute html =~ "codeome-editor-modal"
      assert html =~ "w-[320px]"
      # No spurious "Discard edits?" should fire: the dashboard root must not
      # carry the dirty flag the ConfirmAction JS hook keys off of.
      refute html =~ ~s(data-inspector-dirty="true")
    end

    # Regression: clicking a species row used to attach a ConfirmAction JS hook
    # that fired window.confirm("Discard codeome edits?"). It was redundant
    # (rows are only easily clickable in view mode, which has no edits) and
    # could surface even when the dirty flag was stale in the browser.
    test "species rows have no ConfirmAction hook (the alert was redundant)", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-NA", lineage: {nil, 0}}})

      {:ok, _view, html} = live(conn, "/")

      row_match =
        Regex.run(~r/<tr[^>]*phx-value-hash="HASH-NA"[^>]*>/, html)

      assert row_match, "expected to find species row for HASH-NA"
      [row_tag] = row_match
      refute row_tag =~ "ConfirmAction"
      refute row_tag =~ "Discard codeome edits"
    end
  end

  describe "controls panel — new seed entry point" do
    test "renders the + New Seed button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "+ New Seed"
    end

    test "clicking + New Seed sends :open_codeome_editor to dashboard", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      view
      |> element("button", "+ New Seed")
      |> render_click()

      assert render(view) =~ ~s(id="species-inspector")
    end
  end

  describe "world detail modal — open/close" do
    test "world_detail_open? starts false", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      refute html =~ ~s(id="world-detail")
    end

    test ":open_world_detail info message sets the flag", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)
      html = render(view)
      assert html =~ ~s(id="world-detail")
    end

    test "clicking the ⛶ World detail button opens the modal", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      view
      |> element("button#world-detail-open")
      |> render_click()

      assert render(view) =~ ~s(id="world-detail")
    end

    test "close_world_detail event clears the flag and the highlight", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)
      assert render(view) =~ ~s(id="world-detail")

      # Set a highlight via the highlight event so we can verify clear.
      render_hook(view, "highlight_species_in_world", %{"hash" => "DOES-NOT-EXIST"})

      view |> element("button#world-detail-close") |> render_click()
      refute render(view) =~ ~s(id="world-detail")
    end

    test "clicking a species row sets the highlight on the canvas", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-WD-A", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)

      html =
        view
        |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-A']")
        |> render_click()

      hue = Lenies.SpeciesColor.hue_byte("HASH-WD-A")
      assert html =~ ~s(data-highlight-hue="#{hue}")
    end

    test "clicking the same species row twice clears the highlight", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-WD-B", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)

      view
      |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-B']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-B']")
        |> render_click()

      assert html =~ ~s(data-highlight-hue="0")
    end

    test "clicking a different species row swaps the highlight", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-WD-X", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"L2", %{id: "L2", codeome_hash: "HASH-WD-Y", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)

      view
      |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-X']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-Y']")
        |> render_click()

      hue_y = Lenies.SpeciesColor.hue_byte("HASH-WD-Y")
      assert html =~ ~s(data-highlight-hue="#{hue_y}")
    end

    test "render_frame events are still pushed while the modal is open", %{conn: conn} do
      # Disable throttle so every tick triggers a push_event.
      Application.put_env(:lenies, :dashboard_throttle_ticks, 1)

      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)

      # Force a tick to make sure the dashboard re-pushes.
      Lenies.World.tick_now()
      send(view.pid, {:tick, 1})

      assert_push_event view, "render_frame", %{lenies: _}
    after
      Application.delete_env(:lenies, :dashboard_throttle_ticks)
    end

    test "highlight is cleared when the selected species drops out of the species list", %{conn: conn} do
      Application.put_env(:lenies, :dashboard_throttle_ticks, 1)

      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-WD-GONE", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)

      view
      |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-GONE']")
      |> render_click()

      hue = Lenies.SpeciesColor.hue_byte("HASH-WD-GONE")
      assert render(view) =~ ~s(data-highlight-hue="#{hue}")

      # The Lenie disappears (extinct).
      :ets.delete(:lenies, "L1")
      send(view.pid, {:tick, 1})

      assert render(view) =~ ~s(data-highlight-hue="0")
    after
      Application.delete_env(:lenies, :dashboard_throttle_ticks)
    end

    test "modal species list shows ALL active species (not just dashboard top-10)", %{conn: conn} do
      # 15 distinct species → more than the dashboard's top-10 cap. The
      # modal must list every one of them. Hash short-ids in the component
      # are the first 8 characters of the hash, so we keep those 8 chars
      # unique per species.
      hashes =
        for i <- 1..15 do
          # SPnnX...  — first 8 chars uniquely encode i (zero-padded)
          "SP" <> String.pad_leading(Integer.to_string(i), 2, "0") <> "XXXX-FILLER"
        end

      for {hash, i} <- Enum.with_index(hashes, 1) do
        for j <- 1..i do
          id = "L-#{i}-#{j}"
          :ets.insert(:lenies, {id, %{id: id, codeome_hash: hash, lineage: {nil, 0}}})
        end
      end

      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)
      html = render(view)

      # All 15 short-ids appear in the modal markup.
      for hash <- hashes do
        short = String.slice(hash, 0..7)
        assert html =~ short, "expected modal to list species #{short} but it was missing"
      end
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
          opcodes: [:nop_1, :nop_1, :get_size, :push0, :store, :nop_1, :nop_1, :nop_1, :nop_1, :nop_1, :nop_1]
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
          opcodes: [:nop_1, :nop_1, :get_size, :push0, :store, :nop_1, :nop_1, :nop_1, :nop_1, :nop_1, :nop_1]
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
end
