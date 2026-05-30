defmodule LeniesWeb.Layouts.RootHtmlTest do
  use LeniesWeb.ConnCase

  # Task 4 will add /arena. Until then, probe /sandbox with a logged-in user —
  # the root layout is the same for any authenticated browser response.
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
