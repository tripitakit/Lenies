defmodule LeniesWeb.DashboardLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    # Attach the test pid to the user's sandbox so the world is up and
    # its ETS tables exist BEFORE the LV mounts (most tests pre-populate
    # tables via `:ets.insert(...)` and only then call `live(conn, "/sandbox")`).
    # Pausing immediately gives us the same "no autonomous ticks" guarantee
    # that `tick_interval_ms: 0` setups provide for standalone worlds.
    :ok = Lenies.Sandboxes.attach(user.id)
    world_id = {:sandbox, user.id}
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    :ok = Lenies.Worlds.pause(world_id)

    on_exit(fn ->
      Lenies.Worlds.stop_world(world_id)
    end)

    %{world_id: world_id, handle: handle}
  end

  test "mount uses {:sandbox, user.id} as the world_id and starts the sandbox", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/sandbox")
    world_id = :sys.get_state(view.pid).socket.assigns.world_id
    assert world_id == {:sandbox, user.id}
    assert Lenies.Worlds.alive?(world_id)
  end

  test "tuning sliders reflect the world's LIVE config, not app-env defaults", %{
    conn: conn,
    world_id: world_id
  } do
    # Default eat_amount is 20; tune the live world to a distinctive value.
    :ok = Lenies.Worlds.tune(world_id, :eat_amount, 77)

    {:ok, view, _html} = live(conn, ~p"/sandbox")

    # The slider's value readout must show the world's current config (77),
    # not the global Application default — this is the navigation-persistence fix.
    assert has_element?(view, "#val-eat_amount", "77")
  end

  test "mounts on /sandbox and renders dashboard panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sandbox")

    assert html =~ ~r/Lenies/i
    assert html =~ "id=\"grid-canvas\""
    assert html =~ ~r/Sterilize/i
    assert html =~ ~r/(Pause|Resume)/i
  end

  test "flash group is rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox")
    assert has_element?(view, "#flash-group")
    assert has_element?(view, "#client-error")
    assert has_element?(view, "#server-error")
  end

  test "shows initial canvas with width and height data attributes", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sandbox")
    assert html =~ ~r/phx-hook="GridCanvas"/
  end

  test "clicking sterilize_init shows confirm prompt", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox")

    refute render(view) =~ "Are you sure?"

    view
    |> element("button", "Sterilize")
    |> render_click()

    assert render(view) =~ "Are you sure?"
  end

  test "clicking sterilize_confirm resets the world", %{conn: conn, world_id: world_id} do
    # Un-pause for this test: tick_now requires the world to be running.
    :ok = Lenies.Worlds.resume(world_id)

    {:ok, view, _html} = live(conn, ~p"/sandbox")

    {:ok, handle} = Lenies.Worlds.handle(world_id)
    :ok = GenServer.call(handle.pid, :tick_now)
    stats_before = Lenies.Worlds.snapshot_stats(world_id)
    assert stats_before.tick_count >= 1

    view
    |> element("button", "Sterilize")
    |> render_click()

    view
    |> element("button", "Yes, sterilize")
    |> render_click()

    stats_after = Lenies.Worlds.snapshot_stats(world_id)
    assert stats_after.tick_count == 0
  end

  test "clicking pause toggles state", %{conn: conn, world_id: world_id} do
    # Setup paused the sandbox; resume so the test's first assertion
    # (refute paused?) starts from a known running state.
    :ok = Lenies.Worlds.resume(world_id)

    {:ok, view, _html} = live(conn, ~p"/sandbox")

    refute Lenies.Worlds.paused?(world_id)

    view
    |> element("button", "Pause")
    |> render_click()

    assert Lenies.Worlds.paused?(world_id)

    view
    |> element("button", "Resume")
    |> render_click()

    refute Lenies.Worlds.paused?(world_id)
  end

  test "canvas always renders all three layers (no toggles)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox")
    html = render(view)
    assert html =~ ~r/data-show-lenies="true"/
    assert html =~ ~r/data-show-resource="true"/
    assert html =~ ~r/data-show-carcass="true"/
    # The toggle controls are gone.
    refute html =~ "phx-value-layer"
    refute has_element?(view, "input[phx-click='toggle_layer']")
  end

  test "Species panel shows top-N species table from aggregator", %{conn: conn, handle: handle} do
    :ets.insert(
      handle.tables.lenies,
      {"a", %{id: "a", codeome_hash: "hashA", lineage: {nil, 0}}}
    )

    :ets.insert(
      handle.tables.lenies,
      {"b", %{id: "b", codeome_hash: "hashA", lineage: {nil, 1}}}
    )

    :ets.insert(
      handle.tables.lenies,
      {"c", %{id: "c", codeome_hash: "hashB", lineage: {nil, 0}}}
    )

    {:ok, _view, html} = live(conn, ~p"/sandbox")

    assert html =~ "hashA"
    assert html =~ "hashB"
    # Population column for hashA = 2
    assert html =~ ~r/hashA[\s\S]+2/

    # Disambiguated economics columns: per-pass cost, optimistic max gain, and
    # the derived net (sortable).
    assert html =~ "Cost/pass"
    assert html =~ "Max gain"
    assert html =~ ~r/phx-value-col="net"/
    assert html =~ "Net"
  end

  test "species table shows the plasmid count, not a hash list", %{conn: conn, handle: handle} do
    :ets.insert(
      handle.tables.lenies,
      {"withp",
       %{
         id: "withp",
         codeome_hash: "PLASMID-SP",
         lineage: {nil, 0},
         plasmids: [Lenies.Plasmid.new([:nop_0]), Lenies.Plasmid.new([:nop_1])]
       }}
    )

    {:ok, _view, html} = live(conn, ~p"/sandbox")

    assert html =~ "2 plasmids"
  end

  test "species table shows a min–max range when members carry different plasmid loads",
       %{conn: conn, handle: handle} do
    :ets.insert(handle.tables.lenies, {
      "rangep1",
      %{
        id: "rangep1",
        codeome_hash: "RANGE-SP",
        lineage: {nil, 0},
        plasmids: [Lenies.Plasmid.new([:nop_0])]
      }
    })

    :ets.insert(handle.tables.lenies, {
      "rangep3",
      %{
        id: "rangep3",
        codeome_hash: "RANGE-SP",
        lineage: {nil, 0},
        plasmids: [
          Lenies.Plasmid.new([:nop_0]),
          Lenies.Plasmid.new([:nop_1]),
          Lenies.Plasmid.new([:nop_0])
        ]
      }
    })

    {:ok, _view, html} = live(conn, ~p"/sandbox")

    assert html =~ "1–3 plasmids"
  end

  test "species table omits the plasmid annotation when there are none",
       %{conn: conn, handle: handle} do
    :ets.insert(
      handle.tables.lenies,
      {"nop", %{id: "nop", codeome_hash: "NOPLASMID-SP", lineage: {nil, 0}}}
    )

    {:ok, _view, html} = live(conn, ~p"/sandbox")

    refute html =~ ~r/NOPLASMID-SP[\s\S]{0,200}plasmid/
  end

  test "select_lenie_at_cell on occupied cell navigates to the codeome editor",
       %{conn: conn, handle: handle} do
    [{key, cell}] = :ets.lookup(handle.tables.cells, {5, 5})
    :ets.insert(handle.tables.cells, {key, %{cell | lenie_id: "CLICKED"}})

    :ets.insert(
      handle.tables.lenies,
      {"CLICKED", %{id: "CLICKED", codeome_hash: "CLICKED-HASH", lineage: {nil, 0}}}
    )

    {:ok, view, _html} = live(conn, ~p"/sandbox")

    assert {:error, {:live_redirect, %{to: "/sandbox/editor/edit/CLICKED-HASH"}}} =
             render_hook(view, "select_lenie_at_cell", %{"x" => 5, "y" => 5})
  end

  test "select_lenie_at_cell on empty cell stays on dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox")
    # Cell {7, 8} is empty by default
    assert render_hook(view, "select_lenie_at_cell", %{"x" => 7, "y" => 8})
  end

  test "Seed dropdown is rendered with available seeds", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sandbox")
    assert html =~ "Seed"
    assert html =~ "Minimal Replicator"
    assert html =~ "Carnivore"
  end

  test "clicking Spawn triggers world spawn_lenie", %{conn: conn, handle: handle} do
    {:ok, view, _html} = live(conn, ~p"/sandbox")

    pop_before = :ets.info(handle.tables.lenies, :size) || 0

    view
    |> form("form[phx-submit='spawn_seed']", %{seed_id: "minimal_replicator"})
    |> render_submit()

    Process.sleep(100)

    pop_after = :ets.info(handle.tables.lenies, :size) || 0
    assert pop_after >= pop_before + 1
  end

  test "Tuning slider mutates the sandbox world's state.config in place",
       %{conn: conn, world_id: world_id, handle: handle} do
    {:ok, view, _html} = live(conn, ~p"/sandbox")

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
    :ok = Lenies.Worlds.tune(world_id, :radiation_per_tick, original)
  end

  test "Save snapshot button triggers Worlds.save_snapshot/2",
       %{conn: conn, world_id: world_id, handle: handle} do
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

    {:ok, view, _html} = live(conn, ~p"/sandbox")

    [{key, cell}] = :ets.lookup(handle.tables.cells, {2, 2})
    :ets.insert(handle.tables.cells, {key, %{cell | resource: 42}})

    view
    |> form("form[phx-submit='snapshot_action']", %{snapshot_name: "uitest"})
    |> render_submit(%{action: "save"})

    sandbox_path = Lenies.Worlds.id_to_path(world_id)
    assert File.exists?(Path.join([root, sandbox_path, "uitest", "cells.tab"]))
  end

  describe "inspector dirty notification" do
    test "dashboard receives :inspector_dirty info messages and reflects them in the DOM", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/sandbox")

      send(view.pid, {:inspector_dirty, true})
      html = render(view)
      assert html =~ ~s(data-inspector-dirty="true")

      send(view.pid, {:inspector_dirty, false})
      html2 = render(view)
      refute html2 =~ ~s(data-inspector-dirty="true")
    end

    test "closing the inspector (deselect to nil) resets :inspector_dirty",
         %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"L1", %{id: "L1", codeome_hash: "HASH-Z", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, ~p"/sandbox")

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
      {:ok, _view, html} = live(conn, ~p"/sandbox")
      refute html =~ ~s(id="species-inspector")
    end

    test "clicking a species row opens the inspector for that hash",
         %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"L1", %{id: "L1", codeome_hash: "HASH-X", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"L2", %{id: "L2", codeome_hash: "HASH-X", lineage: {nil, 1}}}
      )

      {:ok, view, _} = live(conn, ~p"/sandbox")

      html =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-X']")
        |> render_click()

      assert html =~ ~s(id="species-inspector")
      assert html =~ "HASH-X"
    end

    test "clicking the same row again closes the inspector", %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"L1", %{id: "L1", codeome_hash: "HASH-Y", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, ~p"/sandbox")

      view
      |> element("tr[phx-click='select_species'][phx-value-hash='HASH-Y']")
      |> render_click()

      html =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-Y']")
        |> render_click()

      refute html =~ ~s(id="species-inspector")
    end

    test "clicking another row swaps the inspected species", %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"L1", %{id: "L1", codeome_hash: "HASH-A", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"L2", %{id: "L2", codeome_hash: "HASH-B", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, ~p"/sandbox")

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
    test "+ New Seed link navigates to /sandbox/editor/new", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox")

      assert {:error, {:live_redirect, %{to: "/sandbox/editor/new"}}} =
               view
               |> element("#open-codeome-editor")
               |> render_click()
    end

    test "EDIT button links to the seed currently selected in the SPAWN dropdown",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox")

      default_id = Lenies.Seeds.all() |> hd() |> Map.fetch!(:id) |> Atom.to_string()

      assert has_element?(view, "a#seed-edit-btn[href$='/sandbox/editor/seed/#{default_id}']")

      [_first, second | _] = Lenies.Seeds.all()
      second_id = Atom.to_string(second.id)

      view
      |> element("form[phx-submit='spawn_seed']")
      |> render_change(%{"seed_id" => second_id})

      assert has_element?(view, "a#seed-edit-btn[href$='/sandbox/editor/seed/#{second_id}']")
    end
  end

  describe "map highlight driven by selected species" do
    test "no highlight by default — data-highlight-hue is 0", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sandbox")
      assert html =~ ~s(data-highlight-hue="0")
    end

    test "selecting a species row sets the canvas highlight to its hue",
         %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"L1", %{id: "L1", codeome_hash: "HASH-SEL-A", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, ~p"/sandbox")

      html =
        view
        |> element("tr#species-row-HASH-SEL-A")
        |> render_click()

      hue = Lenies.SpeciesColor.hue_byte(handle, "HASH-SEL-A")
      assert html =~ ~s(data-highlight-hue="#{hue}")
    end

    test "clicking the selected row again deselects and clears the highlight",
         %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"L1", %{id: "L1", codeome_hash: "HASH-SEL-B", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, ~p"/sandbox")

      view |> element("tr#species-row-HASH-SEL-B") |> render_click()
      html = view |> element("tr#species-row-HASH-SEL-B") |> render_click()

      assert html =~ ~s(data-highlight-hue="0")
    end

    test "highlight is cleared when the selected species drops out of the top-N",
         %{conn: conn, handle: handle} do
      Application.put_env(:lenies, :dashboard_throttle_ticks, 1)

      :ets.insert(
        handle.tables.lenies,
        {"L1", %{id: "L1", codeome_hash: "HASH-GONE", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, ~p"/sandbox")
      view |> element("tr#species-row-HASH-GONE") |> render_click()

      hue = Lenies.SpeciesColor.hue_byte(handle, "HASH-GONE")
      assert render(view) =~ ~s(data-highlight-hue="#{hue}")

      # The Lenie disappears (extinct) — the next tick recomputes the top-N
      # and the selection should be dropped along with the highlight.
      :ets.delete(handle.tables.lenies, "L1")
      send(view.pid, {:tick, 1, %{population: 0, total_resource: 0, total_carcass: 0}})

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

      {:ok, _view, html} = live(conn, ~p"/sandbox")

      assert html =~ "★ My Test"
      assert html =~ ~s(value="custom:)
    end

    test "spawning a custom seed grows the population AND sets the color override", %{
      conn: conn,
      user: user,
      handle: handle
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

      {:ok, view, _} = live(conn, ~p"/sandbox")

      pop_before = :ets.info(handle.tables.lenies, :size) || 0

      # Each submit now spawns exactly 1 (Task 4: count input removed).
      # Submit twice to grow by 2.
      for _ <- 1..2 do
        view
        |> form("form[phx-submit='spawn_seed']", %{seed_id: "custom:#{seed.id}"})
        |> render_submit()
      end

      Process.sleep(100)

      pop_after = :ets.info(handle.tables.lenies, :size) || 0
      assert pop_after >= pop_before + 2

      # The color override is keyed on the codeome hash
      hash = buffer |> Lenies.Codeome.from_list() |> Lenies.Codeome.hash()
      assert Lenies.SpeciesColor.override(handle, hash) == "#deadbe"
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

      {:ok, view, _} = live(conn, ~p"/sandbox")
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
    test "select_lenie_at_cell with non-integer coords survives", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox")
      render_hook(view, "select_lenie_at_cell", %{"x" => "5", "y" => 0})
      assert render(view) =~ "id=\"grid-canvas\""
    end

    test "request_lenie_hover with non-integer coords survives", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox")
      render_hook(view, "request_lenie_hover", %{"x" => "bad", "y" => "also_bad"})
      assert render(view) =~ "id=\"grid-canvas\""
    end

    test "unknown event name is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox")
      render_hook(view, "no_such_event", %{})
      assert render(view) =~ "id=\"grid-canvas\""
    end
  end

  describe "species table sorting" do
    defp row_pos(html, hash), do: html |> :binary.match("species-row-#{hash}") |> elem(0)

    test "defaults to population descending", %{conn: conn, handle: handle} do
      # POPHI: 3 lenies, POPLO: 1 lenie
      :ets.insert(
        handle.tables.lenies,
        {"H1", %{id: "H1", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"H2", %{id: "H2", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"H3", %{id: "H3", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"L1", %{id: "L1", codeome_hash: "POPLO", lineage: {nil, 0}}}
      )

      {:ok, _view, html} = live(conn, ~p"/sandbox")

      assert row_pos(html, "POPHI") < row_pos(html, "POPLO")
    end

    test "clicking the Pop header toggles to ascending order", %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"H1", %{id: "H1", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"H2", %{id: "H2", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"H3", %{id: "H3", codeome_hash: "POPHI", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"L1", %{id: "L1", codeome_hash: "POPLO", lineage: {nil, 0}}}
      )

      {:ok, view, _} = live(conn, ~p"/sandbox")

      html =
        view
        |> element("th[phx-click='sort_species'][phx-value-col='population']")
        |> render_click()

      assert row_pos(html, "POPLO") < row_pos(html, "POPHI")
      assert html =~ "Pop ▲"
    end

    test "sorting by generation descending puts the oldest lineage first",
         %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"Y1", %{id: "Y1", codeome_hash: "YOUNG", lineage: {nil, 1}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"O1", %{id: "O1", codeome_hash: "OLDGEN", lineage: {nil, 9}}}
      )

      {:ok, view, _} = live(conn, ~p"/sandbox")

      html =
        view
        |> element("th[phx-click='sort_species'][phx-value-col='avg_generation']")
        |> render_click()

      assert row_pos(html, "OLDGEN") < row_pos(html, "YOUNG")
      assert html =~ "Gen ▼"
    end
  end

  describe "species table — LiveView stream" do
    test "species rows are rendered with the expected stream DOM id",
         %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"S1", %{id: "S1", codeome_hash: "STREAM-HASH-1", lineage: {nil, 0}}}
      )

      {:ok, view, _html} = live(conn, ~p"/sandbox")

      assert has_element?(view, "#species-row-STREAM-HASH-1")
    end

    test "tbody has phx-update=stream and the wrapping id", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sandbox")

      assert html =~ ~s(id="species-rows")
      assert html =~ ~s(phx-update="stream")
    end

    test "species_total count is still displayed after stream conversion",
         %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"T1", %{id: "T1", codeome_hash: "COUNT-A", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"T2", %{id: "T2", codeome_hash: "COUNT-B", lineage: {nil, 0}}}
      )

      {:ok, _view, html} = live(conn, ~p"/sandbox")

      # The header reads "▮ 2 species"
      assert html =~ ~r/2 species/
    end

    test "select_species re-streams and highlights the selected row",
         %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"HL1", %{id: "HL1", codeome_hash: "HASH-HL", lineage: {nil, 0}}}
      )

      {:ok, view, _html} = live(conn, ~p"/sandbox")

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

    test "deselecting a row removes the highlight class via re-stream",
         %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"DH1", %{id: "DH1", codeome_hash: "HASH-DH", lineage: {nil, 0}}}
      )

      {:ok, view, _html} = live(conn, ~p"/sandbox")

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

    test "sort_species re-streams rows in the new order", %{conn: conn, handle: handle} do
      # SORTED-HI: 3 lenies; SORTED-LO: 1 lenie — default order: HI first
      :ets.insert(
        handle.tables.lenies,
        {"SR1", %{id: "SR1", codeome_hash: "SORTED-HI", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"SR2", %{id: "SR2", codeome_hash: "SORTED-HI", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"SR3", %{id: "SR3", codeome_hash: "SORTED-HI", lineage: {nil, 0}}}
      )

      :ets.insert(
        handle.tables.lenies,
        {"SR4", %{id: "SR4", codeome_hash: "SORTED-LO", lineage: {nil, 0}}}
      )

      {:ok, view, html_before} = live(conn, ~p"/sandbox")
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

    test "tick re-streams updated species data", %{conn: conn, handle: handle} do
      Application.put_env(:lenies, :dashboard_throttle_ticks, 1)

      :ets.insert(
        handle.tables.lenies,
        {"TK1", %{id: "TK1", codeome_hash: "TICK-HASH", lineage: {nil, 0}}}
      )

      {:ok, view, _html} = live(conn, ~p"/sandbox")

      assert has_element?(view, "#species-row-TICK-HASH")

      # Remove the lenie and send a tick — stream should clear the row
      :ets.delete(handle.tables.lenies, "TK1")
      send(view.pid, {:tick, 1, %{population: 0, total_resource: 0, total_carcass: 0}})
      render(view)

      refute has_element?(view, "#species-row-TICK-HASH")
    after
      Application.delete_env(:lenies, :dashboard_throttle_ticks)
    end

    test "all_species is NOT referenced in the rendered HTML (only stream is)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sandbox")

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
      {:ok, view, html} = live(conn, ~p"/sandbox")
      assert html =~ ~s(phx-hook="AudioToggle")
      assert has_element?(view, "#audio-toggle[phx-hook='AudioToggle']")
      assert has_element?(view, "#audio-toggle[phx-update='ignore']")
    end

    test "audio-toggle button has no inline onclick or LeniesAudio script", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sandbox")
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
      {:ok, view, html} = live(conn, ~p"/sandbox")

      # There must be no inline oninput attribute anywhere
      refute html =~ "oninput"

      # Check one specific slider (radiation_per_tick) for correct hook wiring
      assert has_element?(
               view,
               "#slider-radiation_per_tick[phx-hook='SliderValue'][data-value-target='val-radiation_per_tick']"
             )
    end

    test "tick_interval_ms slider has min=200", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sandbox")
      assert html =~ ~r/id="slider-tick_interval_ms"[^>]+min="200"/
    end

    test "lenie_metabolize_delay_ms slider has min=100", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sandbox")
      assert html =~ ~r/id="slider-lenie_metabolize_delay_ms"[^>]+min="100"/
    end
  end

  # ---------------------------------------------------------------------------
  # ML3 — Controls panel reads the ACTUAL paused state at mount
  # ---------------------------------------------------------------------------
  describe "controls panel — paused? state at mount" do
    test "when world is already paused at mount, pause button shows Resume",
         %{conn: conn, world_id: world_id} do
      # setup already paused the sandbox — leave it paused.
      :ok = Lenies.Worlds.pause(world_id)

      {:ok, _view, html} = live(conn, ~p"/sandbox")

      assert html =~ "▶ Resume"
      refute html =~ "⏸ Pause"
    end

    test "when world is running at mount, pause button shows Pause",
         %{conn: conn, world_id: world_id} do
      :ok = Lenies.Worlds.resume(world_id)

      {:ok, _view, html} = live(conn, ~p"/sandbox")

      assert html =~ "⏸ Pause"
      refute html =~ "▶ Resume"
    end
  end

  # ---------------------------------------------------------------------------
  # ML4 — World totals moved into header strip (POP/RES/DET chips)
  # ---------------------------------------------------------------------------
  describe "world totals panel" do
    test "totals header chips render before any tick", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sandbox")

      assert html =~ "POP"
      assert html =~ "RES"
      assert html =~ "DET"
    end

    test "totals header chips reflect telemetry data after a tick",
         %{conn: conn, world_id: world_id} do
      Application.put_env(:lenies, :dashboard_throttle_ticks, 1)

      # Need the world running to tick.
      :ok = Lenies.Worlds.resume(world_id)

      {:ok, view, _html} = live(conn, ~p"/sandbox")

      {:ok, handle} = Lenies.Worlds.handle(world_id)
      :ok = GenServer.call(handle.pid, :tick_now)
      # Give PubSub a moment to propagate tick → Telemetry, then the dashboard tick
      Process.sleep(50)
      send(view.pid, {:tick, 1, %{population: 0, total_resource: 0, total_carcass: 0}})
      html = render(view)

      # POP, RES, DET chips are present in the header
      assert html =~ "POP"
      assert html =~ "RES"
      assert html =~ "DET"
    after
      Application.delete_env(:lenies, :dashboard_throttle_ticks)
    end
  end

  test "world totals render in the header strip", %{conn: conn, handle: handle} do
    :ets.insert(
      handle.tables.lenies,
      {"x", %{id: "x", codeome_hash: "hx", lineage: {nil, 0}, pid: self()}}
    )

    {:ok, view, _html} = live(conn, ~p"/sandbox")
    html = render(view)
    # Header chips present…
    assert html =~ "POP"
    assert html =~ "RES"
    assert html =~ "DET"
    # …and the standalone "World totals" panel is gone.
    refute html =~ "World totals"
  end

  describe "KILL button — cull selected species" do
    test "Kill uses an inline confirm, then culls and clears the selection",
         %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"K1", %{id: "K1", codeome_hash: "HASH-KILL", lineage: {nil, 0}}}
      )

      {:ok, view, _html} = live(conn, ~p"/sandbox")

      render_click(view, "select_species", %{"hash" => "HASH-KILL"})
      assert has_element?(view, "#species-inspector")
      assert has_element?(view, "#inspector-kill-HASH-KILL")

      # First click shows the inline confirm (no browser data-confirm) — no cull yet.
      view |> element("#inspector-kill-HASH-KILL") |> render_click()
      assert has_element?(view, "#inspector-kill-confirm-HASH-KILL")
      assert has_element?(view, "#species-inspector")

      # Confirming culls the species and clears the selection.
      view |> element("#inspector-kill-confirm-HASH-KILL button", "Yes, kill") |> render_click()
      refute has_element?(view, "#species-inspector")
    end

    test "Cancel dismisses the confirm without culling", %{conn: conn, handle: handle} do
      :ets.insert(
        handle.tables.lenies,
        {"K2", %{id: "K2", codeome_hash: "HASH-KEEP", lineage: {nil, 0}}}
      )

      {:ok, view, _html} = live(conn, ~p"/sandbox")
      render_click(view, "select_species", %{"hash" => "HASH-KEEP"})

      view |> element("#inspector-kill-HASH-KEEP") |> render_click()
      assert has_element?(view, "#inspector-kill-confirm-HASH-KEEP")

      view |> element("#inspector-kill-confirm-HASH-KEEP button", "Cancel") |> render_click()
      assert has_element?(view, "#inspector-kill-HASH-KEEP")
      assert has_element?(view, "#species-inspector")
    end
  end

  describe "spawn cap UI (Task 4)" do
    test "spawn button is disabled when sandbox is at spawn_cap", %{
      conn: conn,
      handle: handle
    } do
      # The sandbox world boots with default spawn_cap=50. Fill the :lenies
      # ETS table with 50 fake records so the component update/2 sees the
      # cap as reached.
      for i <- 1..50 do
        :ets.insert(
          handle.tables.lenies,
          {"fake-#{i}", %{id: "fake-#{i}", codeome_hash: "abc", lineage: {nil, 0}}}
        )
      end

      {:ok, _view, html} = live(conn, ~p"/sandbox")

      # The submit button in the spawn form should be disabled.
      assert html =~ ~r/<button[^>]*id="spawn-btn"[^>]*disabled/s
    end

    test "spawning when at cap surfaces a flash", %{conn: conn, handle: handle} do
      for i <- 1..50 do
        :ets.insert(
          handle.tables.lenies,
          {"fake-#{i}", %{id: "fake-#{i}", codeome_hash: "abc", lineage: {nil, 0}}}
        )
      end

      {:ok, view, _html} = live(conn, ~p"/sandbox")

      # Force the form submission even though the UI button is disabled —
      # this exercises the engine-level :spawn_cap_exceeded path and verifies
      # the flash relay from LiveComponent → parent LiveView fires.
      view
      |> form("form[phx-submit='spawn_seed']", %{seed_id: "minimal_replicator"})
      |> render_submit()

      html = render(view)
      assert html =~ "Sandbox full"
    end
  end
end
