defmodule LeniesWeb.EditorLiveStdLibTest do
  use LeniesWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    :ok = Lenies.Sandboxes.attach(user.id)
    world_id = {:sandbox, user.id}
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    :ok = Lenies.Worlds.pause(world_id)

    case Process.whereis(Lenies.Manual) do
      nil -> {:ok, _} = Lenies.Manual.start_link([])
      _ -> :ok
    end

    case Process.whereis(Lenies.Snippets.Store) do
      nil -> {:ok, _} = Lenies.Snippets.Store.start_link([])
      _ -> :ok
    end

    on_exit(fn -> Lenies.Worlds.stop_world(world_id) end)
    %{world_id: world_id, handle: handle}
  end

  test "std-lib panel lists snippets and inserts one at the caret", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/sandbox/editor/new")
    assert html =~ "Std-lib"
    assert html =~ "graze step"

    render_hook(view, "insert_stdlib", %{"id" => "graze-step"})
    assert render(view) =~ "eat"
    assert render(view) =~ "move"
  end
end
