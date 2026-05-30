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
      {:ok, _view, html} = live(conn, ~p"/arena")
      assert html =~ "Seed your Lenie"
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
      {:ok, _view, html} = live(conn, ~p"/arena")
      assert html =~ "Apoptosis"
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
end
