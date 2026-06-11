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

  describe "genome panel render" do
    test "shows + Plasmid and the Chromosome row in the Genome tab", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      assert has_element?(view, "button[phx-value-section='chromosome']", "Chromosome")
      assert has_element?(view, "button", "+ Plasmid")
    end

    test "adding a plasmid renders its row and central listing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "add_plasmid", %{})
      render_hook(view, "edit_insert", %{"section" => "p0", "index" => 0, "opcode" => "nop_1"})
      html = render(view)
      assert html =~ ~s(data-plasmid-row="0")
      assert html =~ "NOP_1"
      assert html =~ "1/#{Lenies.Plasmid.max_length()}"
    end

    test "authored plasmids render in the central listing with a divider", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

      render_hook(view, "edit_insert", %{
        "section" => "chromosome",
        "index" => 0,
        "opcode" => "nop_0"
      })

      render_hook(view, "edit_insert", %{
        "section" => "chromosome",
        "index" => 1,
        "opcode" => "move"
      })

      render_hook(view, "add_plasmid", %{})
      render_hook(view, "edit_insert", %{"section" => "p0", "index" => 0, "opcode" => "nop_1"})

      html = render(view)
      # exec = chromosome ++ plasmid → the lettered plasmid separator is present
      assert html =~ "plasmid A"
    end
  end

  describe "sectioned genome editing" do
    test "plasmid code renders in the central listing with a divider and flat indices",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")

      # build: 2 chromosome ops, one plasmid with 1 op
      render_submit(view, "submit_opcode_text", %{"opcodes" => "push0 add"})
      render_click(view, "add_plasmid", %{})
      render_submit(view, "submit_opcode_text", %{"opcodes" => "move"})

      html = render(view)
      assert html =~ "plasmid A"
      # plasmid op displays its FLAT exec index (002), not 0
      assert html =~ ~r/002.*MOVE/s
      assert has_element?(view, "#codeome-blocks-p0 .codeome-block-editable")
    end

    test "add_plasmid moves the caret into the new section so inserts land there",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
      render_submit(view, "submit_opcode_text", %{"opcodes" => "push0"})
      render_click(view, "add_plasmid", %{})
      render_submit(view, "submit_opcode_text", %{"opcodes" => "eat eat"})

      assert has_element?(view, "#codeome-blocks-p0 [data-idx='1']")
      refute has_element?(view, "#codeome-blocks-chromosome [data-idx='1']")
    end

    test "caret crosses the section divider with move_caret", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
      render_submit(view, "submit_opcode_text", %{"opcodes" => "push0"})
      render_click(view, "add_plasmid", %{})

      # caret is at the end of plasmid p0 (empty -> gap 0); move up twice:
      # gap 0 of p0 -> last gap of chromosome (1) -> gap 0 of chromosome
      render_click(view, "move_caret", %{"dir" => "up"})
      render_click(view, "move_caret", %{"dir" => "up"})
      assert has_element?(view, "#codeome-blocks-chromosome [data-gap='0'].codeome-gap-caret")
    end

    test "selection operations carry the section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
      render_click(view, "add_plasmid", %{})
      render_submit(view, "submit_opcode_text", %{"opcodes" => "eat move"})

      render_click(view, "select_block", %{"section" => "p0", "index" => 0, "shift" => false})
      render_click(view, "copy_selection", %{})
      render_click(view, "place_caret", %{"section" => "chromosome", "gap" => 0})
      render_click(view, "paste_clipboard", %{})

      assert has_element?(view, "#codeome-blocks-chromosome [data-idx='0']")
      html = render(view)
      assert html =~ ~r/codeome-blocks-chromosome.*EAT/s
    end

    test "undo reverts a plasmid edit (history now covers the whole genome)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
      render_click(view, "add_plasmid", %{})
      render_submit(view, "submit_opcode_text", %{"opcodes" => "eat"})
      assert has_element?(view, "#codeome-blocks-p0 .codeome-block-editable")

      render_click(view, "undo", %{})
      refute has_element?(view, "#codeome-blocks-p0 .codeome-block-editable")
    end

    test "removing a plasmid goes through the two-step confirm in the Genome tab",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
      render_click(view, "add_plasmid", %{})
      render_click(view, "plasmid_remove_init", %{"index" => 0})
      assert render(view) =~ "Delete?"
      render_click(view, "plasmid_remove_confirm", %{})
      refute has_element?(view, "#codeome-blocks-p0")
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

    render_hook(view, "edit_insert", %{
      "section" => "chromosome",
      "index" => 0,
      "opcode" => "push0"
    })

    html = render(view)
    assert html =~ "1 ops"
    assert html =~ "●dirty"
  end

  test "delete handler removes the opcode at the given index", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

    render_hook(view, "edit_insert", %{
      "section" => "chromosome",
      "index" => 0,
      "opcode" => "push0"
    })

    render_hook(view, "edit_insert", %{
      "section" => "chromosome",
      "index" => 1,
      "opcode" => "push1"
    })

    render_hook(view, "edit_delete", %{"section" => "chromosome", "index" => "0"})

    html = render(view)
    assert html =~ "Genome — 1 ops"
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
    assert html =~ "Genome — 3 ops"
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
    assert html =~ "Genome — 2 ops"
  end

  test "submit_opcode_text rejects all-or-nothing on invalid token and surfaces error",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

    view
    |> form("form[phx-submit=submit_opcode_text]", %{opcodes: "push0 foobar baz"})
    |> render_submit()

    html = render(view)
    # buffer unchanged
    assert html =~ "Genome — 0 ops"
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
    assert html =~ "Genome — 0 ops"
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

      html =
        render_hook(view, "select_block", %{
          "section" => "chromosome",
          "index" => 2,
          "shift" => false
        })

      assert html =~ ~r/codeome-block-editable[^"]*codeome-block-selected[^>]*data-idx="2"/ or
               html =~ ~r/data-idx="2"[^>]*codeome-block-selected/
    end

    test "shift-click extends a range from the anchor", %{conn: conn} do
      view = seeded_editor(conn)

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 1,
        "shift" => false
      })

      html =
        render_hook(view, "select_block", %{
          "section" => "chromosome",
          "index" => 3,
          "shift" => true
        })

      assert html =~ ~s(data-idx="1")
      selected_count = Regex.scan(~r/codeome-block-selected/, html) |> length()
      assert selected_count == 3
    end

    test "clear_selection removes all highlights", %{conn: conn} do
      view = seeded_editor(conn)

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 0,
        "shift" => false
      })

      html = render_hook(view, "clear_selection", %{})
      refute html =~ "codeome-block-selected"
    end

    test "non-numeric index is a safe no-op", %{conn: conn} do
      view = seeded_editor(conn)

      html =
        render_hook(view, "select_block", %{
          "section" => "chromosome",
          "index" => "abc",
          "shift" => false
        })

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
      Regex.scan(~r/codeome-block-name">\s*([A-Z0-9_]+)\s*</, html)
      |> Enum.map(fn [_, name] -> name end)
    end

    test "copy then paste replaces the active selection with the clipboard", %{conn: conn} do
      view = seeded_editor2(conn)
      # Select blocks 0..1 (PUSH0, PUSH1) and copy them.
      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 0,
        "shift" => false
      })

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 1,
        "shift" => true
      })

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

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 1,
        "shift" => false
      })

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 2,
        "shift" => true
      })

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

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 0,
        "shift" => false
      })

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 2,
        "shift" => true
      })

      html = render_hook(view, "delete_selection", %{})
      assert listing_opcodes(html) == ["MOVE", "EAT"]
    end

    test "duplicate_selection inserts a copy right after", %{conn: conn} do
      view = seeded_editor2(conn)

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 3,
        "shift" => false
      })

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
      Regex.scan(~r/codeome-block-name">\s*([A-Z0-9_]+)\s*</, html)
      |> Enum.map(fn [_, n] -> n end)
    end

    test "undo reverts the last mutation; redo reapplies it", %{conn: conn} do
      view = seeded_editor3(conn)

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 0,
        "shift" => false
      })

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

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 0,
        "shift" => false
      })

      render_hook(view, "delete_selection", %{})
      render_hook(view, "undo", %{})
      # Caret is clamped (not auto-moved to the end) after undo, so move it to
      # the end before the new mutation to keep the append deterministic.
      render_hook(view, "move_caret_end", %{"to" => "end"})
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
      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 0,
        "shift" => false
      })

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
      Regex.scan(~r/codeome-block-name">\s*([A-Z0-9_]+)\s*</, html)
      |> Enum.map(fn [_, n] -> n end)
    end

    test "save selection as snippet, then insert it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 0,
        "shift" => false
      })

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 1,
        "shift" => true
      })

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

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 0,
        "shift" => false
      })

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

      html =
        render_hook(view, "select_block", %{
          "section" => "chromosome",
          "index" => 0,
          "shift" => false
        })

      refute html =~ ~r/phx-click="copy_selection"[^>]*disabled/
    end

    test "clicking the Delete toolbar button removes the selection", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})

      render_hook(view, "select_block", %{
        "section" => "chromosome",
        "index" => 0,
        "shift" => false
      })

      html =
        view
        |> element("button[phx-click='delete_selection']")
        |> render_click()

      names =
        Regex.scan(~r/codeome-block-name">\s*([A-Z0-9_]+)\s*</, html)
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
    render_hook(view, "place_caret", %{"section" => "chromosome", "gap" => 0})
    assert has_element?(view, "#codeome-blocks-chromosome [data-gap='0'].codeome-gap-caret")
    refute has_element?(view, "#codeome-blocks-chromosome [data-gap='1'].codeome-gap-caret")
  end

  test "clicking a block selects exactly that block", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})

    render_hook(view, "select_block", %{"section" => "chromosome", "index" => 1, "shift" => false})

    assert has_element?(view, ".codeome-block-selected[data-idx='1']")
    refute has_element?(view, ".codeome-block-selected[data-idx='0']")
  end

  test "move_caret up and down navigate through gaps", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "move_caret", %{"dir" => "up", "extend" => false})
    render_hook(view, "move_caret", %{"dir" => "up", "extend" => false})
    assert has_element?(view, "#codeome-blocks-chromosome [data-gap='0'].codeome-gap-caret")
    render_hook(view, "move_caret", %{"dir" => "down", "extend" => false})
    assert has_element?(view, "#codeome-blocks-chromosome [data-gap='1'].codeome-gap-caret")
  end

  test "Home and End place the caret at the buffer ends", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "move_caret_end", %{"to" => "start"})
    assert has_element?(view, "#codeome-blocks-chromosome [data-gap='0'].codeome-gap-caret")
    render_hook(view, "move_caret_end", %{"to" => "end"})
    assert has_element?(view, "#codeome-blocks-chromosome [data-gap='3'].codeome-gap-caret")
  end

  test "palette insert lands at the caret, not at the end", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 add"})
    render_hook(view, "place_caret", %{"section" => "chromosome", "gap" => 1})

    render_hook(view, "edit_insert", %{
      "section" => "chromosome",
      "index" => 1,
      "opcode" => "push1"
    })

    assert render(view) =~ "PUSH1"
    assert has_element?(view, "#codeome-blocks-chromosome [data-gap='2'].codeome-gap-caret")
  end

  test "inserting with an active selection replaces it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})

    render_hook(view, "select_block", %{"section" => "chromosome", "index" => 1, "shift" => false})

    render_hook(view, "select_block", %{"section" => "chromosome", "index" => 2, "shift" => true})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "eat"})
    html = render(view)
    assert html =~ "2 ops"

    block_names =
      Regex.scan(~r/codeome-block-name">\s*([A-Z0-9_]+)\s*</, html)
      |> Enum.map(fn [_, n] -> n end)

    assert block_names == ["PUSH0", "EAT"]
  end

  test "snippet inserts at the caret", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    :ok = Lenies.Snippets.Store.save(%{id: "twoops", name: "twoops", opcodes: [:push0, :push1]})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "add eat"})
    render_hook(view, "place_caret", %{"section" => "chromosome", "gap" => 1})
    render_hook(view, "insert_snippet", %{"id" => "twoops"})
    assert has_element?(view, "#codeome-blocks-chromosome [data-gap='3'].codeome-gap-caret")
  end

  test "dropping a snippet at a gap inserts it there", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    :ok = Lenies.Snippets.Store.save(%{id: "pp", name: "pp", opcodes: [:push0, :push1]})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "add eat"})

    render_hook(view, "insert_snippet_at", %{
      "id" => "pp",
      "section" => "chromosome",
      "index" => 1
    })

    assert render(view) =~ "4 ops"
    assert has_element?(view, "#codeome-blocks-chromosome [data-gap='3'].codeome-gap-caret")
  end

  # Helper: extract the ordered list of opcode names from the listing pane blocks.
  # Regex targets .codeome-block-name spans which only appear in the listing, not
  # the palette chips (which use class "palette-chip", not "codeome-block-name").
  defp listing_names(html) do
    Regex.scan(~r/codeome-block-name">\s*([A-Z0-9_]+)\s*</, html)
    |> Enum.map(fn [_, name] -> name end)
  end

  test "move_range relocates the selected block range", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add eat"})

    render_hook(view, "select_block", %{"section" => "chromosome", "index" => 0, "shift" => false})

    render_hook(view, "select_block", %{"section" => "chromosome", "index" => 1, "shift" => true})
    render_hook(view, "move_range", %{"section" => "chromosome", "to" => 4})
    html = render(view)
    # Buffer should be [add, eat, push0, push1] after moving range {0,1} to gap 4.
    # Using listing_names to verify buffer order — avoids matching palette chip text.
    assert listing_names(html) == ["ADD", "EAT", "PUSH0", "PUSH1"]
  end

  test "Alt+arrow nudges the selection down by one", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})

    render_hook(view, "select_block", %{"section" => "chromosome", "index" => 0, "shift" => false})

    render_hook(view, "move_range_step", %{"dir" => "down"})
    html = render(view)
    # Buffer should be [push1, push0, add] after nudging push0 down by one.
    assert listing_names(html) == ["PUSH1", "PUSH0", "ADD"]
  end

  test "duplicate copies the selection after itself and selects the copy", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})

    render_hook(view, "select_block", %{"section" => "chromosome", "index" => 0, "shift" => false})

    render_hook(view, "duplicate_selection", %{})
    assert render(view) =~ "3 ops"
    # The copy is at index 1 (immediately after the original at index 0).
    assert has_element?(view, ".codeome-block-selected[data-idx='1']")
  end

  test "undo collapses the caret to the end of the restored buffer", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "place_caret", %{"section" => "chromosome", "gap" => 3})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "eat"})
    render_hook(view, "undo", %{})
    assert has_element?(view, "#codeome-blocks-chromosome [data-gap='3'].codeome-gap-caret")
    refute has_element?(view, "#codeome-blocks-chromosome [data-gap='4'].codeome-gap-caret")
  end

  # Note: we use listing_names/1 (already defined above) to check the buffer
  # order in the listing pane — this avoids false positives from palette chips
  # (e.g. PUSH1 appears in the palette regardless of buffer contents).
  test "submit_replace swaps the opcode at an index", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})

    render_hook(view, "submit_replace", %{
      "section" => "chromosome",
      "index" => 1,
      "opcode" => "eat"
    })

    html = render(view)
    assert listing_names(html) == ["PUSH0", "EAT", "ADD"]
  end

  test "submit_replace with an unknown opcode keeps the editor open and shows an error", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "start_inline_edit", %{"section" => "chromosome", "index" => 0})

    render_hook(view, "submit_replace", %{
      "section" => "chromosome",
      "index" => 0,
      "opcode" => "notreal"
    })

    html = render(view)
    # buffer unchanged (still 2 ops)
    assert html =~ "Genome — 2 ops"
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
    render_hook(view, "start_inline_edit", %{"section" => "chromosome", "index" => 1})

    render_hook(view, "submit_replace", %{
      "section" => "chromosome",
      "index" => 1,
      "opcode" => "eat"
    })

    html = render(view)
    assert listing_names(html) == ["PUSH0", "EAT", "ADD"]
    refute html =~ "codeome-inline-input"
  end

  test "cancel_inline_edit closes the inline editor", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "start_inline_edit", %{"section" => "chromosome", "index" => 0})
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

    test "save with a new name in :edit mode creates a new Collection entry and stays in editor",
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
      # stays in the editor — no navigation to /sandbox
      assert render(view) =~ "Genome —"
      assert render(view) =~ "Saved “evolved-v1”"
    end

    test "save with an existing name opens confirm dialog (no inline error)",
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

      # Opens the confirm dialog instead of showing an inline error
      assert result =~ ~r/Overwrite\s+\S*taken\S*\?/
      # No new entry created — still only the seed row.
      assert length(Lenies.Collection.list_codeomes(user)) == 1
    end
  end

  describe "save with overwrite confirm" do
    # 10 non-nop ops to satisfy min_viable_codeome_opcodes = 10
    @overwrite_buf_text "eat move eat move eat move eat move push0 push1"

    setup %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_submit(view, "submit_opcode_text", %{"opcodes" => @overwrite_buf_text})
      %{view: view}
    end

    test "fresh name saves immediately, flashes, clears dirty, stays in editor", %{view: view} do
      render_click(view, "open_save_form", %{})

      render_submit(view, "submit_save_seed", %{
        "seed_name" => "fresh-name",
        "color_hex" => "#aabbcc",
        "energy_default" => "10000"
      })

      # no navigation happened — still showing editor
      assert render(view) =~ "Genome —"
      assert render(view) =~ "Saved “fresh-name”"
      refute render(view) =~ "●dirty"
    end

    test "existing name opens the confirm dialog; cancel returns to the form",
         %{view: view, user: user} do
      {:ok, _} =
        Lenies.Collection.create_codeome(user, %{
          name: "taken",
          color_hex: "#aabbcc",
          energy_default: 10_000.0,
          opcodes: ["eat", "move", "eat", "move", "eat", "move", "eat", "move", "push0", "push1"]
        })

      render_click(view, "open_save_form", %{})

      render_submit(view, "submit_save_seed", %{
        "seed_name" => "taken",
        "color_hex" => "#aabbcc",
        "energy_default" => "10000"
      })

      assert render(view) =~ "Overwrite “taken”?"

      render_click(view, "cancel_overwrite", %{})
      refute render(view) =~ "Overwrite"
      # form still open for editing the name
      assert has_element?(view, "#save-seed-form")
    end

    test "confirm overwrites the record in place", %{view: view, user: user} do
      {:ok, c} =
        Lenies.Collection.create_codeome(user, %{
          name: "evolve-me",
          color_hex: "#aabbcc",
          energy_default: 10_000.0,
          opcodes: [
            "push0",
            "add",
            "push0",
            "add",
            "push0",
            "add",
            "push0",
            "add",
            "push0",
            "add"
          ]
        })

      render_click(view, "open_save_form", %{})

      render_submit(view, "submit_save_seed", %{
        "seed_name" => "evolve-me",
        "color_hex" => "#112233",
        "energy_default" => "9000"
      })

      render_click(view, "confirm_overwrite", %{})

      assert render(view) =~ "Saved “evolve-me”"
      updated = Lenies.Collection.get_codeome(user, c.id)
      assert updated.color_hex == "#112233"
      assert hd(updated.opcodes) == "eat"
      assert length(Lenies.Collection.list_codeomes(user)) == 1
    end

    test "loading a saved codeome pre-fills the save form name", %{conn: conn, user: user} do
      {:ok, c} =
        Lenies.Collection.create_codeome(user, %{
          name: "prefilled",
          color_hex: "#aabbcc",
          energy_default: 10_000.0,
          opcodes: ["eat", "move", "eat", "move", "eat", "move", "eat", "move", "push0", "push1"]
        })

      {:ok, view, _} = live(conn, ~p"/sandbox/editor/seed/custom:#{c.id}")
      render_click(view, "open_save_form", %{})

      assert has_element?(view, "#save-seed-form input[name='seed_name'][value='prefilled']")
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

      assert :sys.get_state(view.pid).socket.assigns.genome.plasmids == [[:nop_1]]
    end

    test "opening a built-in seed preloads its plasmid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/seed/minimal_replicator")
      plasmids = :sys.get_state(view.pid).socket.assigns.genome.plasmids
      assert plasmids == [Lenies.Codeomes.MinimalReplicator.plasmid()]
    end

    test "opening /new has no plasmids", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
      assert :sys.get_state(view.pid).socket.assigns.genome.plasmids == []
    end

    test "editing a live species member preloads its carried plasmids", %{
      conn: conn,
      handle: handle
    } do
      # A species member's carried plasmids live in its :lenies ETS snapshot;
      # the :edit route must surface them in the panel (issue: "+ N plasmids"
      # species were opening with an empty plasmid panel).
      :ets.insert(
        handle.tables.lenies,
        {"withp",
         %{
           id: "withp",
           codeome_hash: "EDIT-PLASMID-SP",
           lineage: {nil, 0},
           plasmids: [Lenies.Plasmid.new([:nop_1])]
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/sandbox/editor/edit/EDIT-PLASMID-SP")
      assert :sys.get_state(view.pid).socket.assigns.genome.plasmids == [[:nop_1]]
    end
  end

  describe "insert routing via section" do
    test "chromosome insert goes to the chromosome", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

      render_hook(view, "edit_insert", %{
        "section" => "chromosome",
        "index" => 0,
        "opcode" => "move"
      })

      state = :sys.get_state(view.pid).socket.assigns
      assert state.genome.chromosome == [:move]
      assert state.genome.plasmids == []
    end

    test "a p0 insert appends to that plasmid", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "add_plasmid", %{})
      render_hook(view, "edit_insert", %{"section" => "p0", "index" => 0, "opcode" => "nop_1"})
      state = :sys.get_state(view.pid).socket.assigns
      assert state.genome.chromosome == []
      assert state.genome.plasmids == [[:nop_1]]
    end
  end

  describe "plasmid mutators (central listing)" do
    setup %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      render_hook(view, "add_plasmid", %{})
      %{view: view}
    end

    test "plasmid identity is shown as a letter, not a number", %{view: view} do
      html = render(view)
      assert html =~ "Plasmid A"
      assert html =~ "plasmid A"
    end

    test "plasmid opcodes are colored by opcode class, like the chromosome", %{view: view} do
      render_hook(view, "edit_insert", %{"section" => "p0", "index" => 0, "opcode" => "move"})
      # The plasmid block carries the `op op-<class>` modifier (the same as the
      # chromosome) since it renders in the central listing now.
      assert has_element?(view, "#codeome-blocks-p0 .codeome-block-editable.op")
    end

    test "delete-plasmid uses the app's custom confirm, not native data-confirm", %{view: view} do
      assert has_element?(view, "button.codeome-plasmid-del-btn")

      render_hook(view, "plasmid_remove_init", %{"index" => 0})
      html = render(view)
      assert html =~ "Delete?"
      assert html =~ "plasmid_remove_confirm"
      # still present until confirmed
      assert :sys.get_state(view.pid).socket.assigns.genome.plasmids != []
    end

    test "delete removes an opcode from the plasmid", %{view: view} do
      for {op, i} <- Enum.with_index(["nop_1", "move", "eat"]),
          do: render_hook(view, "edit_insert", %{"section" => "p0", "index" => i, "opcode" => op})

      render_hook(view, "edit_delete", %{"section" => "p0", "index" => "1"})
      assert :sys.get_state(view.pid).socket.assigns.genome.plasmids == [[:nop_1, :eat]]
    end

    test "reorder moves an opcode within the plasmid", %{view: view} do
      for {op, i} <- Enum.with_index(["nop_1", "move"]),
          do: render_hook(view, "edit_insert", %{"section" => "p0", "index" => i, "opcode" => op})

      render_hook(view, "edit_reorder", %{"section" => "p0", "from" => "0", "to" => "1"})
      assert :sys.get_state(view.pid).socket.assigns.genome.plasmids == [[:move, :nop_1]]
    end

    test "remove (init → confirm) deletes the plasmid", %{view: view} do
      # Destructive remove is a custom two-step confirm, not native data-confirm.
      render_hook(view, "plasmid_remove_init", %{"index" => 0})
      assert :sys.get_state(view.pid).socket.assigns.plasmid_remove_confirming == 0

      render_hook(view, "plasmid_remove_confirm", %{})
      state = :sys.get_state(view.pid).socket.assigns
      assert state.genome.plasmids == []
      assert state.plasmid_remove_confirming == nil
    end

    test "remove cancel keeps the plasmid and closes the confirm", %{view: view} do
      render_hook(view, "edit_insert", %{"section" => "p0", "index" => 0, "opcode" => "nop_1"})
      render_hook(view, "plasmid_remove_init", %{"index" => 0})
      render_hook(view, "plasmid_remove_cancel", %{})
      state = :sys.get_state(view.pid).socket.assigns
      assert state.genome.plasmids == [[:nop_1]]
      assert state.plasmid_remove_confirming == nil
    end

    test "adding a plasmid dismisses a pending remove confirm", %{view: view} do
      render_hook(view, "plasmid_remove_init", %{"index" => 0})
      render_hook(view, "add_plasmid", %{})
      refute :sys.get_state(view.pid).socket.assigns.plasmid_remove_confirming
    end
  end

  test "saving a seed persists authored plasmids (empties dropped)", %{conn: conn, user: user} do
    # A genuinely save-valid chromosome (10 non-nop opcodes) — the same buffer
    # the other save tests in this file rely on — so we exercise the
    # persistence path without tuning the editor's validation bounds.
    valid_chromosome = ~w(push0 push1 add move eat push0 push1 add move eat)a

    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

    # Build the chromosome first (the caret starts at the chromosome end, so
    # submit_opcode_text inserts into the chromosome buffer).
    render_hook(view, "submit_opcode_text", %{
      "opcodes" => "push0 push1 add move eat push0 push1 add move eat"
    })

    # Author a plasmid with a single opcode (edit into section p0).
    render_hook(view, "add_plasmid", %{})
    render_hook(view, "edit_insert", %{"section" => "p0", "index" => 0, "opcode" => "nop_1"})

    # a second, empty plasmid that must be dropped on save
    render_hook(view, "add_plasmid", %{})

    render_hook(view, "submit_save_seed", %{
      "seed_name" => "plasmid_seed",
      "color_hex" => "#88ccff",
      "energy_default" => "10000"
    })

    seed = named_codeome(user, "plasmid_seed")
    assert Lenies.Collection.to_opcode_atoms(seed) == valid_chromosome
    # The authored plasmid persisted; the trailing empty plasmid was dropped.
    assert Lenies.Collection.to_plasmid_structs(seed) == [Lenies.Plasmid.new([:nop_1])]
  end

  defp named_codeome(user, name) do
    user
    |> Lenies.Collection.list_codeomes()
    |> Enum.find(&(&1.name == name))
  end
end
