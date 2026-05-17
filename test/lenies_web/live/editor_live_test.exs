defmodule LeniesWeb.EditorLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    case Process.whereis(Lenies.World) do
      nil -> {:ok, _} = Lenies.World.start_link(tick_interval_ms: 0)
      _ -> :ok
    end

    case Process.whereis(Lenies.Manual) do
      nil -> {:ok, _} = Lenies.Manual.start_link([])
      _ -> :ok
    end

    on_exit(fn ->
      case Process.whereis(Lenies.World) do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      Lenies.World.Tables.delete_all()
    end)

    :ok
  end

  test "mounts on /editor/new with empty buffer", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/editor/new")
    assert html =~ "New Seed"
    assert html =~ ~s(id="manual-pane")
  end

  test "mounts on /editor/edit/:hash with empty buffer when hash unknown", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/editor/edit/NONEXISTENT")
    assert html =~ "Edit: NONEXISTENT"
    assert html =~ "0 ops"
  end

  test "toggling the manual pane updates the grid class", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    refute render(view) =~ "manual-collapsed"

    render_hook(view, "toggle_manual", %{})

    assert render(view) =~ "manual-collapsed"
  end

  test "selecting a chapter updates the current chapter", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "select_chapter", %{"chapter" => "04-loops-and-templates.md"})

    html = render(view)
    assert html =~ ~r/Loops|Templates/
  end

  test "/editor/edit/:hash loads codeome of a live species", %{conn: conn} do
    codeome = Lenies.Codeomes.MinimalReplicator.codeome()
    hash = Lenies.Codeome.hash(codeome)

    {:ok, _pid} =
      Lenies.Lenie.start_link(
        id: "TEST-EDITOR-L1",
        codeome: codeome,
        energy: 100.0,
        pos: {0, 0},
        dir: :n,
        lineage: {nil, 0}
      )

    :ets.insert(:lenies, {"TEST-EDITOR-L1", %{id: "TEST-EDITOR-L1", codeome_hash: hash}})

    {:ok, _view, html} = live(conn, "/editor/edit/#{hash}")
    assert html =~ "121 ops"
  end

  test "drag-drop insert via edit_insert handler appends opcode and marks dirty", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    refute render(view) =~ "●dirty"

    render_hook(view, "edit_insert", %{"index" => 0, "opcode" => "push0"})

    html = render(view)
    assert html =~ "1 ops"
    assert html =~ "●dirty"
  end

  test "delete handler removes the opcode at the given index", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "edit_insert", %{"index" => 0, "opcode" => "push0"})
    render_hook(view, "edit_insert", %{"index" => 1, "opcode" => "push1"})
    render_hook(view, "edit_delete", %{"index" => "0"})

    html = render(view)
    assert html =~ "Codeome — 1 ops"
    # After deleting index 0 (PUSH0), the sole remaining editable block is PUSH1.
    editable_blocks = Regex.scan(~r/codeome-block-editable[^>]*>.*?codeome-block-name[^>]*>\s*([A-Z0-9]+)/s, html)
    assert editable_blocks == [["PUSH1", "PUSH1"]] or Enum.map(editable_blocks, &List.last/1) == ["PUSH1"]
  end
end
