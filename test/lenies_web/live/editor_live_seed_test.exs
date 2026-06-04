defmodule LeniesWeb.EditorLiveSeedTest do
  use LeniesWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    :ok = Lenies.Sandboxes.attach(user.id)
    world_id = {:sandbox, user.id}
    {:ok, _handle} = Lenies.Worlds.handle(world_id)
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
    %{world_id: world_id}
  end

  test "loads a builtin seed's opcodes into the editor", %{conn: conn} do
    seed = hd(Lenies.Seeds.all())
    expected = Lenies.Codeome.to_list(seed.codeome)

    {:ok, _view, html} = live(conn, ~p"/sandbox/editor/seed/#{Atom.to_string(seed.id)}")

    # Opcodes are rendered uppercase in codeome-block-name spans
    assert html =~ String.upcase(Atom.to_string(hd(expected)))
  end

  test "editor header shows New Seed mode for seed route", %{conn: conn} do
    seed = hd(Lenies.Seeds.all())

    {:ok, _view, html} = live(conn, ~p"/sandbox/editor/seed/#{Atom.to_string(seed.id)}")

    assert html =~ "New Seed"
  end

  test "an unknown seed id opens an empty editor without crashing", %{conn: conn} do
    assert {:ok, _view, _html} = live(conn, ~p"/sandbox/editor/seed/not_a_real_seed")
  end
end
