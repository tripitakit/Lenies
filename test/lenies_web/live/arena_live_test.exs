defmodule LeniesWeb.ArenaLiveTest do
  use LeniesWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "anonymous viewer" do
    test "mounts at / and sees Arena content", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/arena")
      assert html =~ "watching"
    end

    test "presence count visible (1 viewer = self)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/arena")
      Process.sleep(50)
      assert render(view) =~ "watching"
    end

    test "shows the 'Log in to seed' prompt instead of seed/apoptosis controls",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/arena")
      assert html =~ "Log in to seed"
      refute html =~ "Seed your Lenie"
    end
  end

  describe "authenticated viewer (no collection codeomes)" do
    setup %{conn: conn} do
      user = Lenies.AccountsFixtures.user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "shows the 'Save a codeome in your Sandbox first' hint", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/arena")
      assert html =~ "Save a codeome in your Sandbox first"
    end
  end

  describe "authenticated viewer with a codeome and lineage=0" do
    setup %{conn: conn} do
      user = Lenies.AccountsFixtures.user_fixture()

      {:ok, codeome} =
        Lenies.Collection.create_codeome(user, %{
          name: "MyArenaSeed",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      on_exit(fn -> Lenies.Worlds.stop_world(:arena) end)
      %{conn: log_in_user(conn, user), user: user, codeome: codeome}
    end

    test "shows the codeome dropdown + Seed button", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/arena")
      # Assert on the interactive control, not a substring of the page text,
      # so a copy tweak elsewhere can't silently pass/fail this.
      assert has_element?(view, "button", "Seed your Lenie")
      assert html =~ "MyArenaSeed"
    end

    test "clicking Seed spawns and updates lineage_count", %{
      conn: conn,
      user: user,
      codeome: codeome
    } do
      {:ok, view, _html} = live(conn, ~p"/arena")

      view
      |> form("form[phx-submit=seed]", %{codeome_id: to_string(codeome.id)})
      |> render_submit()

      Process.sleep(150)

      assert Lenies.Arena.lineage_count(user.id) == 1
      assert render(view) =~ "Your lineage:"
    end
  end

  describe "authenticated viewer with lineage>0" do
    setup %{conn: conn} do
      user = Lenies.AccountsFixtures.user_fixture()

      {:ok, codeome} =
        Lenies.Collection.create_codeome(user, %{
          name: "MyArenaSeed",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      :ok = Lenies.Arena.attach_viewer()
      {:ok, :seeded} = Lenies.Arena.seed(user, codeome.id)
      Process.sleep(50)

      on_exit(fn -> Lenies.Worlds.stop_world(:arena) end)
      %{conn: log_in_user(conn, user), user: user}
    end

    test "shows Apoptosis button with count", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/arena")
      # Target the actual control by its phx-click, robust to label/markup edits.
      assert has_element?(view, "button[phx-click=apoptosis_init]", "Apoptosis")
      assert html =~ "Your lineage:"
    end

    test "two-step Apoptosis (init + confirm) kills the lineage", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/arena")

      view |> element("button[phx-click=apoptosis_init]") |> render_click()
      assert render(view) =~ "Confirm"

      view |> element("button[phx-click=apoptosis_confirm]") |> render_click()
      Process.sleep(150)

      assert Lenies.Arena.lineage_count(user.id) == 0
    end
  end

  describe "route migration" do
    test "anonymous GET /sandbox redirects to /users/log-in", %{conn: conn} do
      conn = get(conn, ~p"/sandbox")
      assert redirected_to(conn) =~ "/users/log-in"
    end

    test "authenticated GET /sandbox is 200 DashboardLive", %{conn: conn} do
      user = Lenies.AccountsFixtures.user_fixture()
      conn = log_in_user(conn, user)
      assert {:ok, _view, _html} = live(conn, ~p"/sandbox")
    end

    test "/ is now the public splash, no redirect to login", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert conn.status == 200
    end

    test "/arena is public (anon), no redirect to login", %{conn: conn} do
      conn = get(conn, ~p"/arena")
      assert conn.status == 200
    end
  end

  describe "species table plasmid badge (ETS pre-populate)" do
    setup do
      :ok = Lenies.Arena.attach_viewer()
      {:ok, handle} = Lenies.Worlds.handle(:arena)
      :ok = Lenies.Worlds.pause(:arena)

      on_exit(fn -> Lenies.Worlds.stop_world(:arena) end)

      %{handle: handle}
    end

    test "shows a min–max range badge when members carry different plasmid loads",
         %{conn: conn, handle: handle} do
      :ets.insert(handle.tables.lenies, {
        "arangep1",
        %{id: "arangep1", codeome_hash: "ARENA-RANGE-SP", lineage: {nil, 0},
          plasmids: [Lenies.Plasmid.new([:nop_0])]}
      })
      :ets.insert(handle.tables.lenies, {
        "arangep3",
        %{id: "arangep3", codeome_hash: "ARENA-RANGE-SP", lineage: {nil, 0},
          plasmids: [Lenies.Plasmid.new([:nop_0]), Lenies.Plasmid.new([:nop_1]),
                     Lenies.Plasmid.new([:nop_0])]}
      })

      {:ok, _view, html} = live(conn, ~p"/arena")

      assert html =~ "1–3 plasmids"
    end

    test "omits the plasmid badge when there are none", %{conn: conn, handle: handle} do
      :ets.insert(handle.tables.lenies, {
        "anone",
        %{id: "anone", codeome_hash: "ARENA-NOPLASMID-SP", lineage: {nil, 0}}
      })

      {:ok, _view, html} = live(conn, ~p"/arena")

      refute html =~ ~r/ARENA-NOPLASMID-SP[\s\S]{0,200}plasmid/
    end
  end

  describe "canvas layers (no toggles)" do
    test "canvas always renders all three layers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/arena")
      html = render(view)
      assert html =~ ~r/data-show-lenies="true"/
      assert html =~ ~r/data-show-resource="true"/
      assert html =~ ~r/data-show-carcass="true"/
      refute html =~ "phx-value-layer"
      refute has_element?(view, "input[phx-click='toggle_layer']")
    end

    test "world totals render in the header, not a panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/arena")
      html = render(view)
      assert html =~ "POP"
      assert html =~ "RES"
      assert html =~ "DET"
      refute html =~ "World totals"
      assert html =~ "ARENA"
    end
  end

  describe "species SAVE button" do
    setup %{conn: conn} do
      user = Lenies.AccountsFixtures.user_fixture()
      :ok = Lenies.Arena.attach_viewer()
      {:ok, handle} = Lenies.Worlds.handle(:arena)
      :ok = Lenies.Worlds.pause(:arena)

      hash = "ARENA-SAVE-SP"

      :ets.insert(handle.tables.lenies, {
        "asave1",
        %{id: "asave1", codeome_hash: hash, lineage: {nil, 0},
          seeder_user_id: user.id,
          codeome: [:nop_1, :eat, :move],
          plasmids: [Lenies.Plasmid.new([:nop_0])]}
      })

      :ets.insert(handle.tables.lenies, {
        "asave3",
        %{id: "asave3", codeome_hash: hash, lineage: {nil, 0},
          seeder_user_id: user.id,
          codeome: [:nop_1, :eat, :move],
          plasmids: [Lenies.Plasmid.new([:nop_0]), Lenies.Plasmid.new([:nop_1]),
                     Lenies.Plasmid.new([:eat])]}
      })

      on_exit(fn -> Lenies.Worlds.stop_world(:arena) end)
      %{conn: conn, user: user, handle: handle, hash: hash}
    end

    test "SAVE button renders for an owned species", %{conn: conn, user: user, hash: hash} do
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/arena")

      assert has_element?(
               view,
               "button[phx-click=save_species_init][phx-value-hash='#{hash}']"
             )
    end

    test "no SAVE button for anonymous viewers", %{conn: conn, hash: hash} do
      {:ok, view, _html} = live(conn, ~p"/arena")

      refute has_element?(
               view,
               "button[phx-click=save_species_init][phx-value-hash='#{hash}']"
             )
    end

    test "clicking SAVE opens the name bar; Cancel closes it", %{conn: conn, user: user, hash: hash} do
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/arena")

      view
      |> element("button[phx-click=save_species_init][phx-value-hash='#{hash}']")
      |> render_click()

      assert has_element?(view, "form[phx-submit=save_species_confirm]")

      view |> element("button[phx-click=save_species_cancel]") |> render_click()

      refute has_element?(view, "form[phx-submit=save_species_confirm]")
    end

    test "name_taken keeps the bar open with an error and creates nothing new", %{conn: conn, user: user, hash: hash} do
      {:ok, _existing} =
        Lenies.Collection.create_codeome(user, %{
          name: "Taken",
          color_hex: "#123456",
          energy_default: 10_000.0,
          opcodes: ["nop_0"]
        })

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/arena")

      view
      |> element("button[phx-click=save_species_init][phx-value-hash='#{hash}']")
      |> render_click()

      html =
        view
        |> form("form[phx-submit=save_species_confirm]", %{name: "Taken"})
        |> render_submit()

      assert html =~ "already taken"
      assert has_element?(view, "form[phx-submit=save_species_confirm]")
      # exactly one codeome named "Taken" — no duplicate created
      assert Lenies.Collection.list_codeomes(user)
             |> Enum.count(&(&1.name == "Taken")) == 1
    end

    test "save ignores other users' members of the same species", %{conn: conn, user: user, handle: handle, hash: hash} do
      other = Lenies.AccountsFixtures.user_fixture()

      :ets.insert(handle.tables.lenies, {
        "aforeign5",
        %{id: "aforeign5", codeome_hash: hash, lineage: {nil, 0},
          seeder_user_id: other.id,
          codeome: [:nop_1, :eat, :move],
          plasmids: [
            Lenies.Plasmid.new([:nop_0]), Lenies.Plasmid.new([:nop_1]),
            Lenies.Plasmid.new([:eat]), Lenies.Plasmid.new([:move]),
            Lenies.Plasmid.new([:nop_0])
          ]}
      })

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/arena")

      view
      |> element("button[phx-click=save_species_init][phx-value-hash='#{hash}']")
      |> render_click()

      view
      |> form("form[phx-submit=save_species_confirm]", %{name: "MineOnly"})
      |> render_submit()

      codeome =
        Lenies.Collection.list_codeomes(user)
        |> Enum.find(&(&1.name == "MineOnly"))

      assert codeome
      # the user's own max-plasmid member has 3 plasmids, not the foreign 5
      assert length(codeome.plasmids) == 3
    end

    test "confirm saves codeome + the max-plasmid member's plasmids", %{conn: conn, user: user, hash: hash} do
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/arena")

      view
      |> element("button[phx-click=save_species_init][phx-value-hash='#{hash}']")
      |> render_click()

      view
      |> form("form[phx-submit=save_species_confirm]", %{name: "EvolvedInArena"})
      |> render_submit()

      codeome =
        Lenies.Collection.list_codeomes(user)
        |> Enum.find(&(&1.name == "EvolvedInArena"))

      assert codeome
      assert codeome.opcodes == ["nop_1", "eat", "move"]
      assert length(codeome.plasmids) == 3
      refute has_element?(view, "form[phx-submit=save_species_confirm]")
    end
  end
end
