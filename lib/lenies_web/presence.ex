defmodule LeniesWeb.Presence do
  @moduledoc """
  Phoenix.Presence for tracking Arena viewers. Topic: `"arena:presence"`.

  Each `LeniesWeb.ArenaLive` mount calls `track(self(), "arena:presence",
  session_id, %{})` and subscribes to the same topic to receive diff updates.
  The display surfaces only the count — usernames are not tracked or shown.
  """
  use Phoenix.Presence,
    otp_app: :lenies,
    pubsub_server: Lenies.PubSub
end
