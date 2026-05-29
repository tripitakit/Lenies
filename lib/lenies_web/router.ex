defmodule LeniesWeb.Router do
  use LeniesWeb, :router

  import LeniesWeb.UserAuth

  # In the test environment, allow connected LiveView processes to share the
  # test's Ecto SQL sandbox connection. Prepended to every `live_session`
  # `on_mount` list so it runs before the auth hooks.
  @sandbox_on_mount if Application.compile_env(:lenies, :sql_sandbox),
                      do: [LeniesWeb.LiveAcceptance],
                      else: []

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LeniesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", LeniesWeb do
  #   pipe_through :api
  # end

  ## Authentication routes

  # Public scope: Arena + auth pages
  scope "/", LeniesWeb do
    pipe_through :browser

    live_session :arena_public,
      on_mount: @sandbox_on_mount ++ [{LeniesWeb.UserAuth, :mount_current_scope}] do
      live "/", ArenaLive, :index

      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # Authenticated scope: Sandbox + Settings, all under /sandbox/... (Settings keeps /users/settings/...)
  scope "/", LeniesWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: @sandbox_on_mount ++ [{LeniesWeb.UserAuth, :require_authenticated}] do
      live "/sandbox", DashboardLive, :index
      live "/sandbox/lenie/:id", LenieInspectorLive, :show
      live "/sandbox/species/:hash", SpeciesLive, :show
      live "/sandbox/editor/new", EditorLive, :new
      live "/sandbox/editor/edit/:hash", EditorLive, :edit

      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  # Enable Swoosh mailbox preview in development
  if Application.compile_env(:lenies, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
