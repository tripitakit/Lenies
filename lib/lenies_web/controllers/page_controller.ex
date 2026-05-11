defmodule LeniesWeb.PageController do
  use LeniesWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
