defmodule LeniesWeb.Layouts.RootHtmlTest do
  use LeniesWeb.ConnCase

  describe "body + main wrapper" do
    setup :register_and_log_in_user

    test "root layout body uses flex column with bounded height", %{conn: conn} do
      conn = get(conn, ~p"/sandbox")
      html = html_response(conn, 200)

      # body must be flex column with h-screen + overflow-hidden so children
      # can shrink correctly (the bug was that navbar height was added on top
      # of the dashboard's h-screen, overflowing the viewport).
      assert html =~ ~r/<body[^>]*class="[^"]*flex flex-col h-screen overflow-hidden/

      # main wrapper must be flex-1 min-h-0 (lets it consume remaining height)
      assert html =~ ~r/<main[^>]*class="[^"]*flex-1 min-h-0 overflow-hidden/
    end
  end

  describe "navbar Arena ↔ Sandbox links" do
    test "Arena link is visible to anonymous users", %{conn: conn} do
      conn = get(conn, ~p"/arena")
      html = html_response(conn, 200)

      assert html =~ ~s(href="/arena")
      # Sandbox is gated behind login → must NOT appear in the anonymous navbar.
      refute html =~ ~s(href="/sandbox")
    end

    test "both Arena AND Sandbox links are visible to authed users", %{conn: conn} do
      conn = register_and_log_in_user(%{conn: conn}) |> Map.fetch!(:conn)
      conn = get(conn, ~p"/sandbox")
      html = html_response(conn, 200)

      assert html =~ ~s(href="/arena")
      assert html =~ ~s(href="/sandbox")
    end
  end
end
