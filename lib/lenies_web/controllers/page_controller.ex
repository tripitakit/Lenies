defmodule LeniesWeb.PageController do
  use LeniesWeb, :controller

  def landing(conn, _params) do
    # current_scope is set by fetch_current_scope_for_user/2 (browser pipeline).
    # Logged-in users see the Sandbox card with active link; anon users
    # see the same card but the link triggers the auth plug's
    # :user_return_to flow.
    render(conn, :landing)
  end
end
