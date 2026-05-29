defmodule LeniesWeb.PageControllerTest do
  use LeniesWeb.ConnCase

  setup :register_and_log_in_user

  test "GET /sandbox renders the LiveView dashboard", %{conn: conn} do
    conn = get(conn, ~p"/sandbox")
    assert html_response(conn, 200) =~ "LENIES"
  end
end
