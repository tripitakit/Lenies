defmodule LeniesWeb.Router do
  use LeniesWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LeniesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", LeniesWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/lenie/:id", LenieInspectorLive, :show
    live "/species/:hash", SpeciesLive, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", LeniesWeb do
  #   pipe_through :api
  # end
end
