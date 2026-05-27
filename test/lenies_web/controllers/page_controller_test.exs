defmodule LeniesWeb.PageControllerTest do
  use LeniesWeb.ConnCase

  setup :register_and_log_in_user

  test "GET / redirects to LiveView dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "LENIES"
  end
end
