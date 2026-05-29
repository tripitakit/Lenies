defmodule LeniesWeb.PresenceTest do
  use ExUnit.Case, async: false

  test "track + list returns the tracked entry" do
    {:ok, _} = LeniesWeb.Presence.track(self(), "arena:presence", "session-x", %{})
    list = LeniesWeb.Presence.list("arena:presence")
    assert Map.has_key?(list, "session-x")
  end
end
