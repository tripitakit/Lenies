defmodule LeniesWeb.PageControllerTest do
  use LeniesWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "splash (anon)" do
    test "GET / renders the splash with both Arena and Sandbox cards", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html =~ "Arena"
      assert html =~ "Sandbox"
      # Arena link goes to /arena (its new home)
      assert html =~ ~r/href="\/arena"/
    end

    test "anon Sandbox card links to /sandbox (auth plug handles return_to)", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      # Anon users see Sandbox card linking to /sandbox; the auth plug
      # then catches them on visit and stores :user_return_to, redirecting
      # to /users/log-in. After login, they land on /sandbox.
      assert html =~ ~r/href="\/sandbox"/
    end
  end

  describe "splash (auth)" do
    setup :register_and_log_in_user

    test "logged-in users see Sandbox card linking to /sandbox", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html =~ "Arena"
      assert html =~ "Sandbox"
      assert html =~ ~r/href="\/sandbox"/
      assert html =~ ~r/href="\/arena"/
    end
  end

  describe "arena route" do
    test "GET /arena renders ArenaLive (anon)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/arena")
      assert html =~ "Arena" or html =~ "ARENA"
    end
  end
end
