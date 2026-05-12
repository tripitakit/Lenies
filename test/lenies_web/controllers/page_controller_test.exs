defmodule LeniesWeb.PageControllerTest do
  use LeniesWeb.ConnCase

  test "GET / redirects to LiveView dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "LENIES"
  end
end
