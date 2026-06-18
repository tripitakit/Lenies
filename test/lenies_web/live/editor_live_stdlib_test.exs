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

  test "std-lib categories are collapsed by default and toggle open", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/sandbox/editor/new")
    # cards are hidden when all categories are collapsed
    refute html =~ "std-lib-card"
    # category headers still render
    assert html =~ "std-lib-cat-head"
    html2 = view |> element(~s{[phx-click="toggle_stdlib_cat"][phx-value-cat="Logic"]}) |> render_click()
    assert html2 =~ "std-lib-card"
  end

  test "std-lib panel lists snippets and inserts one at the caret", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/sandbox/editor/new")
    assert html =~ "Std-lib"
    # open the Foraging category to see the graze card
    render_hook(view, "toggle_stdlib_cat", %{"cat" => "Foraging"})
    assert render(view) =~ "graze"

    render_hook(view, "insert_stdlib", %{"id" => "graze"})
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

  test "inserting a function appends a body and a call; re-inserting adds only a call", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "insert_stdlib", %{"id" => "replicate-self"})
    html1 = render(view)
    assert html1 =~ "call_t"
    assert html1 =~ "ret"
    len1 = chromosome_len(view)
    render_hook(view, "insert_stdlib", %{"id" => "replicate-self"})
    len2 = chromosome_len(view)
    # only a small call added, no second body
    assert len2 - len1 <= 6
  end

  test "function button label reflects whether it is already defined", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
    # open the Replication category to see the replicate-self card
    render_hook(view, "toggle_stdlib_cat", %{"cat" => "Replication"})
    assert render(view) =~ "+ definition &amp; call"
    render_hook(view, "insert_stdlib", %{"id" => "replicate-self"})
    assert render(view) =~ "+ call"
  end
end
