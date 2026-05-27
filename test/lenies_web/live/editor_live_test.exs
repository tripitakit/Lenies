defmodule LeniesWeb.EditorLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup do
    case Process.whereis(Lenies.World) do
      nil -> {:ok, _} = Lenies.World.start_link(tick_interval_ms: 0)
      _ -> :ok
    end

    case Process.whereis(Lenies.Manual) do
      nil -> {:ok, _} = Lenies.Manual.start_link([])
      _ -> :ok
    end

    case Process.whereis(Lenies.Snippets.Store) do
      nil -> {:ok, _} = Lenies.Snippets.Store.start_link([])
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

  test "flash group is rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/editor/new")
    assert has_element?(view, "#flash-group")
    assert has_element?(view, "#client-error")
    assert has_element?(view, "#server-error")
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

    test "copy then paste replaces the active selection with the clipboard", %{conn: conn} do
      view = seeded_editor2(conn)
      # Select blocks 0..1 (PUSH0, PUSH1) and copy them.
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "select_block", %{"index" => 1, "shift" => true})
      render_hook(view, "copy_selection", %{})
      # Paste with the selection still active: replaces selected blocks with the clipboard.
      # clipboard=[push0,push1], delete {0,1} → [add,move,eat], insert at 0 → [push0,push1,add,move,eat]
      html = render_hook(view, "paste_clipboard", %{})
      assert listing_opcodes(html) == ["PUSH0", "PUSH1", "ADD", "MOVE", "EAT"]
      # caret collapsed just after inserted run (gap 2), no selection
      refute html =~ "codeome-block-selected"
    end

    test "cut removes the range and fills the clipboard", %{conn: conn} do
      view = seeded_editor2(conn)
      render_hook(view, "select_block", %{"index" => 1, "shift" => false})
      render_hook(view, "select_block", %{"index" => 2, "shift" => true})
      html = render_hook(view, "cut_selection", %{})
      assert listing_opcodes(html) == ["PUSH0", "MOVE", "EAT"]
      refute html =~ "codeome-block-selected"
      # After cut, caret collapses to the deletion site (gap 1 = between PUSH0 and
      # MOVE). Paste inserts the clipboard [PUSH1, ADD] at gap 1, yielding:
      # [PUSH0, PUSH1, ADD, MOVE, EAT].
      html2 = render_hook(view, "paste_clipboard", %{})
      assert listing_opcodes(html2) == ["PUSH0", "PUSH1", "ADD", "MOVE", "EAT"]
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

    test "dirty flag tracks undo/redo back to the original buffer", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      html_after = render_hook(view, "submit_opcode_text", %{"opcodes" => "push0"})
      assert html_after =~ "●dirty"

      html_undo = render_hook(view, "undo", %{})
      refute html_undo =~ "●dirty"

      html_redo = render_hook(view, "redo", %{})
      assert html_redo =~ "●dirty"
    end

    test "paste is undoable", %{conn: conn} do
      view = seeded_editor3(conn)
      # Copy block 0, clear the selection, then paste at end (gap 3).
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "copy_selection", %{})
      render_hook(view, "move_caret_end", %{"to" => "end"})
      pasted = render_hook(view, "paste_clipboard", %{})
      assert names(pasted) == ["PUSH0", "PUSH1", "ADD", "PUSH0"]

      undone = render_hook(view, "undo", %{})
      assert names(undone) == ["PUSH0", "PUSH1", "ADD"]
    end
  end

  describe "snippet library" do
    @snip_env :__test_user_snippets_file__

    setup do
      tmp = Path.join(System.tmp_dir!(), "lenies_snips_live_#{System.unique_integer([:positive])}.json")
      orig = Application.get_env(:lenies, @snip_env)
      Application.put_env(:lenies, @snip_env, tmp)
      if Process.whereis(Lenies.Snippets.Store), do: Agent.stop(Lenies.Snippets.Store)
      {:ok, _} = Lenies.Snippets.Store.start_link([])

      on_exit(fn ->
        if Process.whereis(Lenies.Snippets.Store) do
          try do
            Agent.stop(Lenies.Snippets.Store)
          catch
            :exit, _ -> :ok
          end
        end

        File.rm(tmp)
        if orig, do: Application.put_env(:lenies, @snip_env, orig), else: Application.delete_env(:lenies, @snip_env)
      end)

      :ok
    end

    defp names4(html) do
      Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
      |> Enum.map(fn [_, n] -> n end)
    end

    test "save selection as snippet, then insert it", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "select_block", %{"index" => 1, "shift" => true})

      html = render_hook(view, "submit_snippet", %{"snippet_name" => "Pair"})
      assert html =~ "Pair"
      assert [%{name: "Pair", opcodes: [:push0, :push1]}] = Lenies.Snippets.Store.all()

      # Move caret to end so the snippet inserts after the existing ops.
      render_hook(view, "move_caret_end", %{"to" => "end"})
      html2 = render_hook(view, "insert_snippet", %{"id" => "pair"})
      assert names4(html2) == ["PUSH0", "PUSH1", "ADD", "PUSH0", "PUSH1"]
    end

    test "delete a snippet removes it from the section", %{conn: conn} do
      Lenies.Snippets.Store.save(%{id: "loop", name: "Loop", opcodes: [:move, :eat]})
      {:ok, view, _} = live(conn, "/editor/new")
      assert render(view) =~ "codeome-snippet-insert"
      html = render_hook(view, "delete_snippet", %{"id" => "loop"})
      refute html =~ "codeome-snippet-insert"
    end

    test "submit_snippet with no selection is a no-op", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0"})
      render_hook(view, "submit_snippet", %{"snippet_name" => "X"})
      assert Lenies.Snippets.Store.all() == []
    end

    test "submit_snippet with an invalid name keeps the form open and saves nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "open_snippet_form", %{})
      html = render_hook(view, "submit_snippet", %{"snippet_name" => "---"})
      assert Lenies.Snippets.Store.all() == []
      assert html =~ ~s(name="snippet_name")
    end
  end

  describe "editor toolbar" do
    test "paste button is disabled with an empty clipboard", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      html = render(view)
      assert html =~ ~r/phx-click="paste_clipboard"[^>]*disabled/
    end

    test "copy button enables once a block is selected", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
      html = render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      refute html =~ ~r/phx-click="copy_selection"[^>]*disabled/
    end

    test "clicking the Delete toolbar button removes the selection", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})

      html =
        view
        |> element("button[phx-click='delete_selection']")
        |> render_click()

      names =
        Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
        |> Enum.map(fn [_, n] -> n end)

      assert names == ["PUSH1", "ADD"]
    end

    test "undo button enables after a mutation", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      assert render(view) =~ ~r/phx-click="undo"[^>]*disabled/
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0"})
      refute render(view) =~ ~r/phx-click="undo"[^>]*disabled/
    end
  end

  test "clicking a gap places a collapsed caret", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0"})
    # buffer len 1; caret defaults to end (gap 1). Click gap 0.
    render_hook(view, "place_caret", %{"gap" => 0})
    assert has_element?(view, "[data-caret-at='0']")
    refute has_element?(view, "[data-caret-at='1']")
  end

  test "clicking a block selects exactly that block", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "select_block", %{"index" => 1, "shift" => false})
    assert has_element?(view, ".codeome-block-selected[data-idx='1']")
    refute has_element?(view, ".codeome-block-selected[data-idx='0']")
  end

  test "move_caret up and down navigate through gaps", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "move_caret", %{"dir" => "up", "extend" => false})
    render_hook(view, "move_caret", %{"dir" => "up", "extend" => false})
    assert has_element?(view, "[data-caret-at='0']")
    render_hook(view, "move_caret", %{"dir" => "down", "extend" => false})
    assert has_element?(view, "[data-caret-at='1']")
  end

  test "Home and End place the caret at the buffer ends", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "move_caret_end", %{"to" => "start"})
    assert has_element?(view, "[data-caret-at='0']")
    render_hook(view, "move_caret_end", %{"to" => "end"})
    assert has_element?(view, "[data-caret-at='3']")
  end

  test "palette insert lands at the caret, not at the end", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 add"})
    render_hook(view, "place_caret", %{"gap" => 1})
    render_hook(view, "edit_insert", %{"index" => 1, "opcode" => "push1"})
    assert render(view) =~ "PUSH1"
    assert has_element?(view, "[data-caret-at='2']")
  end

  test "inserting with an active selection replaces it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "select_block", %{"index" => 1, "shift" => false})
    render_hook(view, "select_block", %{"index" => 2, "shift" => true})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "eat"})
    html = render(view)
    assert html =~ "2 ops"
    block_names =
      Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
      |> Enum.map(fn [_, n] -> n end)
    assert block_names == ["PUSH0", "EAT"]
  end

  test "snippet inserts at the caret", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    :ok = Lenies.Snippets.Store.save(%{id: "twoops", name: "twoops", opcodes: [:push0, :push1]})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "add eat"})
    render_hook(view, "place_caret", %{"gap" => 1})
    render_hook(view, "insert_snippet", %{"id" => "twoops"})
    assert has_element?(view, "[data-caret-at='3']")
  end

  test "dropping a snippet at a gap inserts it there", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    :ok = Lenies.Snippets.Store.save(%{id: "pp", name: "pp", opcodes: [:push0, :push1]})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "add eat"})
    render_hook(view, "insert_snippet_at", %{"id" => "pp", "index" => 1})
    assert render(view) =~ "4 ops"
    assert has_element?(view, "[data-caret-at='3']")
  end

  # Helper: extract the ordered list of opcode names from the listing pane blocks.
  # Regex targets .codeome-block-name spans which only appear in the listing, not
  # the palette chips (which use class "palette-chip", not "codeome-block-name").
  defp listing_names(html) do
    Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
    |> Enum.map(fn [_, name] -> name end)
  end

  test "move_range relocates the selected block range", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add eat"})
    render_hook(view, "select_block", %{"index" => 0, "shift" => false})
    render_hook(view, "select_block", %{"index" => 1, "shift" => true})
    render_hook(view, "move_range", %{"to" => 4})
    html = render(view)
    # Buffer should be [add, eat, push0, push1] after moving range {0,1} to gap 4.
    # Using listing_names to verify buffer order — avoids matching palette chip text.
    assert listing_names(html) == ["ADD", "EAT", "PUSH0", "PUSH1"]
  end

  test "Alt+arrow nudges the selection down by one", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "select_block", %{"index" => 0, "shift" => false})
    render_hook(view, "move_range_step", %{"dir" => "down"})
    html = render(view)
    # Buffer should be [push1, push0, add] after nudging push0 down by one.
    assert listing_names(html) == ["PUSH1", "PUSH0", "ADD"]
  end

  test "duplicate copies the selection after itself and selects the copy", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "select_block", %{"index" => 0, "shift" => false})
    render_hook(view, "duplicate_selection", %{})
    assert render(view) =~ "3 ops"
    # The copy is at index 1 (immediately after the original at index 0).
    assert has_element?(view, ".codeome-block-selected[data-idx='1']")
  end

  test "undo collapses the caret to the end of the restored buffer", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "place_caret", %{"gap" => 3})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "eat"})
    render_hook(view, "undo", %{})
    assert has_element?(view, "[data-caret-at='3']")
    refute has_element?(view, "[data-caret-at='4']")
  end

  # Note: we use listing_names/1 (already defined above) to check the buffer
  # order in the listing pane — this avoids false positives from palette chips
  # (e.g. PUSH1 appears in the palette regardless of buffer contents).
  test "submit_replace swaps the opcode at an index", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "submit_replace", %{"index" => 1, "opcode" => "eat"})
    html = render(view)
    assert listing_names(html) == ["PUSH0", "EAT", "ADD"]
  end

  test "submit_replace with an unknown opcode keeps the editor open and shows an error", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "start_inline_edit", %{"index" => 0})
    render_hook(view, "submit_replace", %{"index" => 0, "opcode" => "notreal"})
    html = render(view)
    assert html =~ "Codeome — 2 ops"                    # buffer unchanged (still 2 ops)
    assert html =~ "codeome-inline-input"               # editor still open
    assert html =~ "codeome-inline-error"               # error shown
    # block at idx 0 is being edited (input, not span); idx 1 still shows its name
    assert listing_names(html) == ["PUSH1"]
  end

  test "submit_replace with a valid opcode closes the editor", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "start_inline_edit", %{"index" => 1})
    render_hook(view, "submit_replace", %{"index" => 1, "opcode" => "eat"})
    html = render(view)
    assert listing_names(html) == ["PUSH0", "EAT", "ADD"]
    refute html =~ "codeome-inline-input"
  end

  test "cancel_inline_edit closes the inline editor", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "start_inline_edit", %{"index" => 0})
    assert render(view) =~ "codeome-inline-input"
    render_hook(view, "cancel_inline_edit", %{})
    refute render(view) =~ "codeome-inline-input"
  end

  test "a jump block shows its target index badge", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "jmp_t nop_0 add nop_1 eat"})
    html = render(view)
    assert html =~ "codeome-jump-badge"
    assert html =~ "003"
  end

  test "an unresolved jump shows the not-found badge", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "jmp_t nop_0 add eat"})
    assert render(view) =~ "codeome-jump-badge-missing"
  end
end
