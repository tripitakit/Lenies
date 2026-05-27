defmodule LeniesWeb.LiveAcceptance do
  @moduledoc """
  `on_mount` hook that allows the connected LiveView process to share the
  test's Ecto SQL sandbox connection.

  Only wired into the router's `live_session` blocks when the
  `:sql_sandbox` configuration is enabled (test environment). See
  `Phoenix.Ecto.SQL.Sandbox` for details.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    socket =
      assign_new(socket, :phoenix_ecto_sandbox, fn ->
        if connected?(socket), do: get_connect_info(socket, :user_agent)
      end)

    metadata = socket.assigns.phoenix_ecto_sandbox
    Phoenix.Ecto.SQL.Sandbox.allow(metadata, Ecto.Adapters.SQL.Sandbox)
    {:cont, socket}
  end
end
