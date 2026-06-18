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

  test "inserting const K=8 puts the doubling chain at the caret", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_submit(view, "insert_stdlib", %{"id" => "const-k", "params" => %{"K" => "8"}})
    html = render(view)
    assert html =~ "push1"
    assert html =~ "dup"
  end

  defp chromosome_len(view) do
    :sys.get_state(view.pid).socket.assigns.genome.chromosome |> length()
  end

  test "inserting a function appends a body and a call; re-inserting adds only a call", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "insert_stdlib", %{"id" => "scan-turn"})
    html1 = render(view)
    assert html1 =~ "call_t"
    assert html1 =~ "ret"
    len1 = chromosome_len(view)
    render_hook(view, "insert_stdlib", %{"id" => "scan-turn"})
    len2 = chromosome_len(view)
    assert len2 - len1 <= 6   # only a small call added, no second body
  end
end
