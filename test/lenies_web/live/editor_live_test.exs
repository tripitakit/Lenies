defmodule LeniesWeb.EditorLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    # Attach the test pid to the user's sandbox so its ETS tables (and
    # LenieSupervisor / Registry entries) are available BEFORE the LV
    # mounts. Pause immediately to match the legacy tick_interval_ms: 0
    # behaviour — the editor tests pre-populate ETS / Registry and only
    # then call `live(conn, "/sandbox/editor/...")`.
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

  test "mounts on /sandbox/editor/new with empty buffer", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sandbox/editor/new")
    assert html =~ "New Seed"
    assert html =~ ~s(id="manual-pane")
  end

  test "flash group is rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
    assert has_element?(view, "#flash-group")
    assert has_element?(view, "#client-error")
    assert has_element?(view, "#server-error")
  end

  test "mounts on /sandbox/editor/edit/:hash with empty buffer when hash unknown", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sandbox/editor/edit/NONEXISTENT")
    assert html =~ "Edit: NONEXISTENT"
    assert html =~ "0 ops"
  end

  describe "plasmid panel render" do
    test "shows + Plasmide and the chromosome chip", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      assert has_element?(view, "[data-target-chip='chromosome']")
      assert has_element?(view, "button", "+ Plasmide")
    end

    test "adding a plasmid renders its chip and listing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "add_plasmid", %{})
      render_hook(view, "edit_insert", %{"index" => 0, "opcode" => "nop_1"})
      html = render(view)
      assert html =~ ~s(data-plasmid-chip="0")
      assert html =~ "NOP_1"
      assert html =~ "1/#{Lenies.Plasmid.max_length()}"
    end
  end

  test "toggling the manual pane updates the grid class", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    refute render(view) =~ "manual-collapsed"

    render_hook(view, "toggle_manual", %{})

    assert render(view) =~ "manual-collapsed"
  end

  test "selecting a chapter updates the current chapter", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "select_chapter", %{"chapter" => "04-loops-and-templates.md"})

    html = render(view)
    assert html =~ ~r/Loops|Templates/
  end

  test "/sandbox/editor/edit/:hash loads codeome of a live species", %{conn: conn, handle: handle} do
    codeome = Lenies.Codeomes.MinimalReplicator.codeome()
    hash = Lenies.Codeome.hash(codeome)

    {:ok, _pid} =
      Lenies.Lenie.start_link({handle,
       [
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
       ]})

    :ets.insert(
      handle.tables.lenies,
      {"TEST-EDITOR-L1", %{id: "TEST-EDITOR-L1", codeome_hash: hash}}
    )

    {:ok, _view, html} = live(conn, ~p"/sandbox/editor/edit/#{hash}")
    # MinimalReplicator chromosome is 123 opcodes (the Twitch plasmid is
    # extra-chromosomal and no longer baked into codeome/0).
    assert html =~ "123 ops"
  end

  test "drag-drop insert via edit_insert handler appends opcode and marks dirty", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    refute render(view) =~ "●dirty"

    render_hook(view, "edit_insert", %{"index" => 0, "opcode" => "push0"})

    html = render(view)
    assert html =~ "1 ops"
    assert html =~ "●dirty"
  end

  test "delete handler removes the opcode at the given index", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

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
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

    view
    |> form("form[phx-submit=submit_opcode_text]", %{opcodes: "PUSH0, ADD"})
    |> render_submit()

    html = render(view)
    assert html =~ "Codeome — 2 ops"
  end

  test "submit_opcode_text rejects all-or-nothing on invalid token and surfaces error",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

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
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

    view
    |> form("form[phx-submit=submit_opcode_text]", %{opcodes: "   "})
    |> render_submit()

    html = render(view)
    assert html =~ "Codeome — 0 ops"
    refute html =~ "palette-text-input-error"
  end

  describe "block selection" do
    defp seeded_editor(conn) do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
      assert Regex.scan(~r/codeome-block-selected/, html) |> length() == 1
    end

    test "copy/paste with empty clipboard is a no-op", %{conn: conn} do
      view = seeded_editor2(conn)
      html = render_hook(view, "paste_clipboard", %{})
      assert listing_opcodes(html) == ["PUSH0", "PUSH1", "ADD", "MOVE", "EAT"]
    end
  end

  describe "undo / redo" do
    defp seeded_editor3(conn) do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
      tmp =
        Path.join(
          System.tmp_dir!(),
          "lenies_snips_live_#{System.unique_integer([:positive])}.json"
        )

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

        if orig,
          do: Application.put_env(:lenies, @snip_env, orig),
          else: Application.delete_env(:lenies, @snip_env)
      end)

      :ok
    end

    defp names4(html) do
      Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
      |> Enum.map(fn [_, n] -> n end)
    end

    test "save selection as snippet, then insert it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      assert render(view) =~ "codeome-snippet-insert"
      html = render_hook(view, "delete_snippet", %{"id" => "loop"})
      refute html =~ "codeome-snippet-insert"
    end

    test "submit_snippet with no selection is a no-op", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0"})
      render_hook(view, "submit_snippet", %{"snippet_name" => "X"})
      assert Lenies.Snippets.Store.all() == []
    end

    test "submit_snippet with an invalid name keeps the form open and saves nothing", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      html = render(view)
      assert html =~ ~r/phx-click="paste_clipboard"[^>]*disabled/
    end

    test "copy button enables once a block is selected", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
      html = render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      refute html =~ ~r/phx-click="copy_selection"[^>]*disabled/
    end

    test "clicking the Delete toolbar button removes the selection", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      assert render(view) =~ ~r/phx-click="undo"[^>]*disabled/
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0"})
      refute render(view) =~ ~r/phx-click="undo"[^>]*disabled/
    end
  end

  test "clicking a gap places a collapsed caret", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0"})
    # buffer len 1; caret defaults to end (gap 1). Click gap 0.
    render_hook(view, "place_caret", %{"gap" => 0})
    assert has_element?(view, "[data-caret-at='0']")
    refute has_element?(view, "[data-caret-at='1']")
  end

  test "clicking a block selects exactly that block", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "select_block", %{"index" => 1, "shift" => false})
    assert has_element?(view, ".codeome-block-selected[data-idx='1']")
    refute has_element?(view, ".codeome-block-selected[data-idx='0']")
  end

  test "move_caret up and down navigate through gaps", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "move_caret", %{"dir" => "up", "extend" => false})
    render_hook(view, "move_caret", %{"dir" => "up", "extend" => false})
    assert has_element?(view, "[data-caret-at='0']")
    render_hook(view, "move_caret", %{"dir" => "down", "extend" => false})
    assert has_element?(view, "[data-caret-at='1']")
  end

  test "Home and End place the caret at the buffer ends", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "move_caret_end", %{"to" => "start"})
    assert has_element?(view, "[data-caret-at='0']")
    render_hook(view, "move_caret_end", %{"to" => "end"})
    assert has_element?(view, "[data-caret-at='3']")
  end

  test "palette insert lands at the caret, not at the end", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 add"})
    render_hook(view, "place_caret", %{"gap" => 1})
    render_hook(view, "edit_insert", %{"index" => 1, "opcode" => "push1"})
    assert render(view) =~ "PUSH1"
    assert has_element?(view, "[data-caret-at='2']")
  end

  test "inserting with an active selection replaces it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    :ok = Lenies.Snippets.Store.save(%{id: "twoops", name: "twoops", opcodes: [:push0, :push1]})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "add eat"})
    render_hook(view, "place_caret", %{"gap" => 1})
    render_hook(view, "insert_snippet", %{"id" => "twoops"})
    assert has_element?(view, "[data-caret-at='3']")
  end

  test "dropping a snippet at a gap inserts it there", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "select_block", %{"index" => 0, "shift" => false})
    render_hook(view, "move_range_step", %{"dir" => "down"})
    html = render(view)
    # Buffer should be [push1, push0, add] after nudging push0 down by one.
    assert listing_names(html) == ["PUSH1", "PUSH0", "ADD"]
  end

  test "duplicate copies the selection after itself and selects the copy", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "select_block", %{"index" => 0, "shift" => false})
    render_hook(view, "duplicate_selection", %{})
    assert render(view) =~ "3 ops"
    # The copy is at index 1 (immediately after the original at index 0).
    assert has_element?(view, ".codeome-block-selected[data-idx='1']")
  end

  test "undo collapses the caret to the end of the restored buffer", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
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
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "submit_replace", %{"index" => 1, "opcode" => "eat"})
    html = render(view)
    assert listing_names(html) == ["PUSH0", "EAT", "ADD"]
  end

  test "submit_replace with an unknown opcode keeps the editor open and shows an error", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "start_inline_edit", %{"index" => 0})
    render_hook(view, "submit_replace", %{"index" => 0, "opcode" => "notreal"})
    html = render(view)
    # buffer unchanged (still 2 ops)
    assert html =~ "Codeome — 2 ops"
    # editor still open
    assert html =~ "codeome-inline-input"
    # error shown
    assert html =~ "codeome-inline-error"
    # block at idx 0 is being edited (input, not span); idx 1 still shows its name
    assert listing_names(html) == ["PUSH1"]
  end

  test "submit_replace with a valid opcode closes the editor", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "start_inline_edit", %{"index" => 1})
    render_hook(view, "submit_replace", %{"index" => 1, "opcode" => "eat"})
    html = render(view)
    assert listing_names(html) == ["PUSH0", "EAT", "ADD"]
    refute html =~ "codeome-inline-input"
  end

  test "cancel_inline_edit closes the inline editor", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "start_inline_edit", %{"index" => 0})
    assert render(view) =~ "codeome-inline-input"
    render_hook(view, "cancel_inline_edit", %{})
    refute render(view) =~ "codeome-inline-input"
  end

  test "a jump block shows its target index badge", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "jmp_t nop_0 add nop_1 eat"})
    html = render(view)
    assert html =~ "codeome-jump-badge"
    assert html =~ "003"
  end

  test "an unresolved jump shows the not-found badge", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "jmp_t nop_0 add eat"})
    assert render(view) =~ "codeome-jump-badge-missing"
  end

  describe "save as fork in :edit mode" do
    # 10+ non-nop opcodes to satisfy min_viable_codeome_opcodes = 10 so the
    # validation passes and the Save button isn't disabled.
    @valid_buf_text "push0 push1 add move eat push0 push1 add move eat"

    test "save button is visible in :edit mode (was hidden before)", %{conn: conn} do
      # Editor in :edit mode with an unknown hash mounts with an empty
      # buffer — that's enough to verify the button's render condition;
      # we don't need a live Lenie for this assertion.
      {:ok, _view, html} = live(conn, ~p"/sandbox/editor/edit/NONEXISTENT")

      assert html =~ ~r/phx-click="open_save_form"/
    end

    test "save with a new name in :edit mode creates a new Collection entry (fork)",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/edit/NONEXISTENT")
      render_hook(view, "submit_opcode_text", %{"opcodes" => @valid_buf_text})
      render_click(view, "open_save_form")

      view
      |> form("form[phx-submit='submit_save_seed']", %{
        "seed_name" => "evolved-v1",
        "color_hex" => "#abcdef",
        "energy_default" => "600"
      })
      |> render_submit()

      assert [c] = Lenies.Collection.list_codeomes(user)
      assert c.name == "evolved-v1"
      assert c.color_hex == "#abcdef"
    end

    test "save with an existing name shows inline name-taken error",
         %{conn: conn, user: user} do
      {:ok, _} =
        Lenies.Collection.create_codeome(user, %{
          name: "taken",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat"]
        })

      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/edit/NONEXISTENT")
      render_hook(view, "submit_opcode_text", %{"opcodes" => @valid_buf_text})
      render_click(view, "open_save_form")

      result =
        view
        |> form("form[phx-submit='submit_save_seed']", %{
          "seed_name" => "taken",
          "color_hex" => "#ffffff",
          "energy_default" => "500"
        })
        |> render_submit()

      assert result =~ ~r/already (taken|exists)|name.*taken/i
      # No new entry created — still only the seed row.
      assert length(Lenies.Collection.list_codeomes(user)) == 1
    end
  end

  describe "spawn form (simplified)" do
    test "spawn form has no count input and no energy input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")

      # Seed the buffer with something valid so the Spawn button is enabled
      # and the spawn form is reachable.
      # 10+ non-nop opcodes to satisfy min_viable_codeome_opcodes = 10
      render_hook(view, "submit_opcode_text", %{
        "opcodes" => "push0 push1 add move eat push0 push1 add move eat"
      })

      render_click(view, "open_spawn_form")
      html = render(view)

      refute html =~ ~r/<input[^>]+name=["']count["']/
      refute html =~ ~r/<input[^>]+name=["']energy["']/
    end

    test "submit_spawn fires with no params required", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
      # 10+ non-nop opcodes to satisfy min_viable_codeome_opcodes = 10
      render_hook(view, "submit_opcode_text", %{
        "opcodes" => "push0 push1 add move eat push0 push1 add move eat"
      })

      render_click(view, "open_spawn_form")

      # The handler must accept an empty params map (form has no inputs)
      # and navigate back to /sandbox.
      render_submit(form(view, "form[phx-submit='submit_spawn']"), %{})
      assert_redirect(view, "/sandbox")
    end
  end

  test "the SAVE form is right-aligned under the SAVE button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")

    # Open the save form directly (the handler sets show_save_form: true
    # without re-checking validation, so this works without a valid buffer).
    html = render_hook(view, "open_save_form", %{})

    assert html =~ ~s(id="save-seed-form")
    assert has_element?(view, "form#save-seed-form.justify-end")
  end

  describe "plasmid preload on open" do
    test "opening a Collection seed preloads its persisted plasmids", %{conn: conn, user: user} do
      {:ok, seed} =
        Lenies.Collection.create_codeome(user, %{
          name: "withplasmid",
          color_hex: "#88ccff",
          energy_default: 10_000.0,
          opcodes: ["nop_0", "move"],
          plasmids: [%{opcodes: ["nop_1"]}]
        })

      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/seed/custom:#{seed.id}")

      assert :sys.get_state(view.pid).socket.assigns.plasmid_buffers == [[:nop_1]]
      assert :sys.get_state(view.pid).socket.assigns.active_target == :chromosome
    end

    test "opening a built-in seed preloads its plasmid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/seed/minimal_replicator")
      plasmids = :sys.get_state(view.pid).socket.assigns.plasmid_buffers
      assert is_list(plasmids)
      assert length(plasmids) == 1
      assert is_list(hd(plasmids))
      assert hd(plasmids) != []
    end

    test "opening /new has no plasmids", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
      assert :sys.get_state(view.pid).socket.assigns.plasmid_buffers == []
      assert :sys.get_state(view.pid).socket.assigns.active_target == :chromosome
    end
  end

  describe "insert routing via active target" do
    test "palette insert goes to chromosome by default", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "edit_insert", %{"index" => 0, "opcode" => "move"})
      state = :sys.get_state(view.pid).socket.assigns
      assert state.buffer == [:move]
      assert state.plasmid_buffers == []
    end

    test "with a plasmid target, palette insert appends to that plasmid", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "add_plasmid", %{})
      render_hook(view, "set_target", %{"target" => "plasmid", "index" => "0"})
      render_hook(view, "edit_insert", %{"index" => 0, "opcode" => "nop_1"})
      state = :sys.get_state(view.pid).socket.assigns
      assert state.buffer == []
      assert state.plasmid_buffers == [[:nop_1]]
      assert state.active_target == {:plasmid, 0}
    end
  end

  describe "plasmid mutators" do
    setup %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "add_plasmid", %{})
      render_hook(view, "set_target", %{"target" => "plasmid", "index" => "0"})
      %{view: view}
    end

    test "delete removes an opcode from the active plasmid", %{view: view} do
      for op <- ["nop_1", "move", "eat"],
          do: render_hook(view, "edit_insert", %{"index" => 0, "opcode" => op})

      render_hook(view, "plasmid_delete_op", %{"index" => "1"})
      assert :sys.get_state(view.pid).socket.assigns.plasmid_buffers == [[:nop_1, :eat]]
    end

    test "reorder moves an opcode within the active plasmid", %{view: view} do
      for op <- ["nop_1", "move"],
          do: render_hook(view, "edit_insert", %{"index" => 0, "opcode" => op})

      render_hook(view, "plasmid_reorder", %{"from" => "0", "to" => "2"})
      assert :sys.get_state(view.pid).socket.assigns.plasmid_buffers == [[:move, :nop_1]]
    end

    test "remove deletes the active plasmid and resets target to chromosome", %{view: view} do
      render_hook(view, "plasmid_remove", %{})
      state = :sys.get_state(view.pid).socket.assigns
      assert state.plasmid_buffers == []
      assert state.active_target == :chromosome
    end

    test "insert past the cap is a no-op", %{view: view} do
      cap = Lenies.Plasmid.max_length()

      for _ <- 1..(cap + 5),
          do: render_hook(view, "edit_insert", %{"index" => 0, "opcode" => "nop_0"})

      [plasmid] = :sys.get_state(view.pid).socket.assigns.plasmid_buffers
      assert length(plasmid) == cap
    end
  end
end
