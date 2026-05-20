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
        # Generous energy so the Lenie outlives the editor mount even when
        # earlier tests leave the BEAM scheduler under load — the editor
        # just needs the codeome via one GenServer.call, but at energy 100
        # MR can starve before that call lands.
        energy: 50_000.0,
        pos: {0, 0},
        dir: :n,
        lineage: {nil, 0}
      )

    :ets.insert(:lenies, {"TEST-EDITOR-L1", %{id: "TEST-EDITOR-L1", codeome_hash: hash}})

    {:ok, _view, html} = live(conn, "/editor/edit/#{hash}")
    assert html =~ "155 ops"
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
    editable_blocks =
      Regex.scan(~r/codeome-block-editable[^>]*>.*?codeome-block-name[^>]*>\s*([A-Z0-9]+)/s, html)

    assert editable_blocks == [["PUSH1", "PUSH1"]] or
             Enum.map(editable_blocks, &List.last/1) == ["PUSH1"]
  end

  test "submit_opcode_text appends all tokens when all valid", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")

    view
    |> form("form[phx-submit=submit_opcode_text]", %{opcodes: "push0 push1 add"})
    |> render_submit()

    html = render(view)
    assert html =~ "Codeome — 3 ops"
    assert html =~ "PUSH0"
    assert html =~ "PUSH1"
    assert html =~ "ADD"
    refute html =~ "palette-text-input-error"
  end

  test "submit_opcode_text is case-insensitive and tolerates commas", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")

    view
    |> form("form[phx-submit=submit_opcode_text]", %{opcodes: "PUSH0, ADD"})
    |> render_submit()

    html = render(view)
    assert html =~ "Codeome — 2 ops"
  end

  test "submit_opcode_text rejects all-or-nothing on invalid token and surfaces error",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")

    view
    |> form("form[phx-submit=submit_opcode_text]", %{opcodes: "push0 foobar baz"})
    |> render_submit()

    html = render(view)
    # buffer unchanged
    assert html =~ "Codeome — 0 ops"
    # error visible with the unknown tokens listed
    assert html =~ "unknown: foobar, baz"
    # input value preserved so user can edit it
    assert html =~ ~s(value="push0 foobar baz")
  end

  test "submit_opcode_text with empty input is a no-op", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")

    view
    |> form("form[phx-submit=submit_opcode_text]", %{opcodes: "   "})
    |> render_submit()

    html = render(view)
    assert html =~ "Codeome — 0 ops"
    refute html =~ "palette-text-input-error"
  end

  describe "block selection" do
    defp seeded_editor(conn) do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add move eat"})
      view
    end

    test "click selects a single block and highlights it", %{conn: conn} do
      view = seeded_editor(conn)
      html = render_hook(view, "select_block", %{"index" => 2, "shift" => false})
      assert html =~ ~r/codeome-block-editable[^"]*codeome-block-selected[^>]*data-idx="2"/ or
               html =~ ~r/data-idx="2"[^>]*codeome-block-selected/
    end

    test "shift-click extends a range from the anchor", %{conn: conn} do
      view = seeded_editor(conn)
      render_hook(view, "select_block", %{"index" => 1, "shift" => false})
      html = render_hook(view, "select_block", %{"index" => 3, "shift" => true})
      assert html =~ ~s(data-idx="1")
      selected_count = Regex.scan(~r/codeome-block-selected/, html) |> length()
      assert selected_count == 3
    end

    test "clear_selection removes all highlights", %{conn: conn} do
      view = seeded_editor(conn)
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      html = render_hook(view, "clear_selection", %{})
      refute html =~ "codeome-block-selected"
    end

    test "non-numeric index is a safe no-op", %{conn: conn} do
      view = seeded_editor(conn)
      html = render_hook(view, "select_block", %{"index" => "abc", "shift" => false})
      refute html =~ "codeome-block-selected"
    end
  end

  describe "clipboard and editing" do
    defp seeded_editor2(conn) do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add move eat"})
      view
    end

    defp listing_opcodes(html) do
      Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
      |> Enum.map(fn [_, name] -> name end)
    end

    test "copy then paste duplicates the range after the selection", %{conn: conn} do
      view = seeded_editor2(conn)
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "select_block", %{"index" => 1, "shift" => true})
      render_hook(view, "copy_selection", %{})
      html = render_hook(view, "paste_clipboard", %{})
      assert listing_opcodes(html) ==
               ["PUSH0", "PUSH1", "PUSH0", "PUSH1", "ADD", "MOVE", "EAT"]
      # paste selects the inserted range (PUSH0 PUSH1 at idx 2..3)
      assert (Regex.scan(~r/codeome-block-selected/, html) |> length()) == 2
    end

    test "cut removes the range and fills the clipboard", %{conn: conn} do
      view = seeded_editor2(conn)
      render_hook(view, "select_block", %{"index" => 1, "shift" => false})
      render_hook(view, "select_block", %{"index" => 2, "shift" => true})
      html = render_hook(view, "cut_selection", %{})
      assert listing_opcodes(html) == ["PUSH0", "MOVE", "EAT"]
      refute html =~ "codeome-block-selected"
      html2 = render_hook(view, "paste_clipboard", %{})
      assert listing_opcodes(html2) == ["PUSH0", "MOVE", "EAT", "PUSH1", "ADD"]
    end

    test "delete_selection removes the range", %{conn: conn} do
      view = seeded_editor2(conn)
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "select_block", %{"index" => 2, "shift" => true})
      html = render_hook(view, "delete_selection", %{})
      assert listing_opcodes(html) == ["MOVE", "EAT"]
    end

    test "duplicate_selection inserts a copy right after", %{conn: conn} do
      view = seeded_editor2(conn)
      render_hook(view, "select_block", %{"index" => 3, "shift" => false})
      html = render_hook(view, "duplicate_selection", %{})
      assert listing_opcodes(html) == ["PUSH0", "PUSH1", "ADD", "MOVE", "MOVE", "EAT"]
      # the duplicate (single MOVE at idx 4) is selected
      assert (Regex.scan(~r/codeome-block-selected/, html) |> length()) == 1
    end

    test "copy/paste with empty clipboard is a no-op", %{conn: conn} do
      view = seeded_editor2(conn)
      html = render_hook(view, "paste_clipboard", %{})
      assert listing_opcodes(html) == ["PUSH0", "PUSH1", "ADD", "MOVE", "EAT"]
    end
  end

  describe "undo / redo" do
    defp seeded_editor3(conn) do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
      view
    end

    defp names(html) do
      Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
      |> Enum.map(fn [_, n] -> n end)
    end

    test "undo reverts the last mutation; redo reapplies it", %{conn: conn} do
      view = seeded_editor3(conn)
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      html_after_delete = render_hook(view, "delete_selection", %{})
      assert names(html_after_delete) == ["PUSH1", "ADD"]

      html_undo = render_hook(view, "undo", %{})
      assert names(html_undo) == ["PUSH0", "PUSH1", "ADD"]

      html_redo = render_hook(view, "redo", %{})
      assert names(html_redo) == ["PUSH1", "ADD"]
    end

    test "undo with empty history is a no-op", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      html = render_hook(view, "undo", %{})
      assert names(html) == []
    end

    test "a new mutation after undo clears the redo stack", %{conn: conn} do
      view = seeded_editor3(conn)
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "delete_selection", %{})
      render_hook(view, "undo", %{})
      render_hook(view, "submit_opcode_text", %{"opcodes" => "move"})
      html = render_hook(view, "redo", %{})
      assert names(html) == ["PUSH0", "PUSH1", "ADD", "MOVE"]
    end
  end
end
