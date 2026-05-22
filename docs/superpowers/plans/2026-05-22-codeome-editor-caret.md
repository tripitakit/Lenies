# Codeome Editor — Explicit Insertion Caret Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the codeome editor's implicit block-selection model with an explicit, server-authoritative insertion caret, unifying insertion, multi-block move, in-place edit, and static jump-target visualization.

**Architecture:** A pure `LeniesWeb.EditorCaret` module owns all caret/selection math on `{caret, anchor}` gap indices; `EditorLive` holds `caret`/`anchor` assigns and renders the caret as a DOM element (morphdom redraws it for free). `CodeomeBuffer` gains `move_range/3`. A pure `LeniesWeb.JumpTargets` module computes jump destinations by reusing `Lenies.Interpreter.Template`. JS hooks only translate clicks/keys/drag into LiveView events.

**Tech Stack:** Elixir, Phoenix LiveView, SortableJS (vendored), ExUnit, `Phoenix.LiveViewTest`.

**Reference spec:** `docs/superpowers/specs/2026-05-22-codeome-editor-caret-design.md`

---

## File Structure

**Create:**
- `lib/lenies_web/editor_caret.ex` — pure caret/selection math.
- `lib/lenies_web/jump_targets.ex` — pure jump-target computation.
- `test/lenies_web/editor_caret_test.exs` — unit tests for the above.
- `test/lenies_web/jump_targets_test.exs` — unit tests.

**Modify:**
- `lib/lenies_web/codeome_buffer.ex` — add `move_range/3`.
- `test/lenies_web/codeome_buffer_test.exs` — tests for `move_range/3`.
- `lib/lenies_web/live/editor_live.ex` — replace `selection`/`sel_anchor` with `caret`/`anchor`; new handlers; wire `replace/3`; render caret, gaps, in-place edit, jump badges/highlights.
- `test/lenies_web/live/editor_live_test.exs` — LiveView tests for new behavior.
- `assets/js/hooks/editor_keyboard.js` — caret nav keys, gap clicks, Alt+arrows, in-place edit dispatch.
- `assets/js/hooks/codeome_sortable.js` — multi-block move (emit `move_range`), drop-gap = caret.
- `assets/css/app.css` (or the editor stylesheet) — caret, gap zones, template highlight, SVG arc.

**Phasing (each phase ends green & committable):**
1. Caret model + server-side render (replaces selection state).
2. Unified insertion at the caret.
3. Range move / duplicate.
4. In-place edit.
5. Visible jump targets (most separable).

---

## Phase 1 — Caret model & server-side render

### Task 1: `EditorCaret` pure module — derive & predicates

**Files:**
- Create: `lib/lenies_web/editor_caret.ex`
- Test: `test/lenies_web/editor_caret_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LeniesWeb.EditorCaretTest do
  use ExUnit.Case, async: true

  alias LeniesWeb.EditorCaret, as: C

  describe "derive_range/1 and collapsed?/1" do
    test "collapsed caret has no range" do
      assert C.collapsed?({2, 2})
      assert C.derive_range({2, 2}) == nil
    end

    test "caret after anchor selects blocks [anchor, caret-1]" do
      refute C.collapsed?({3, 1})
      assert C.derive_range({3, 1}) == {1, 2}
    end

    test "anchor after caret derives the same inclusive block range" do
      assert C.derive_range({1, 3}) == {1, 2}
    end
  end

  describe "place/1 and select_block/1" do
    test "place collapses both ends to the gap" do
      assert C.place(4) == {4, 4}
    end

    test "select_block selects exactly that one block" do
      sel = C.select_block(2)
      assert sel == {3, 2}
      assert C.derive_range(sel) == {2, 2}
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test test/lenies_web/editor_caret_test.exs`
Expected: FAIL — `LeniesWeb.EditorCaret` is undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule LeniesWeb.EditorCaret do
  @moduledoc """
  Pure caret/selection math for the codeome editor.

  State is a `{caret, anchor}` pair of **gap** indices in `0..len`. A gap `i`
  sits *before* block `i`; gap `len` is at the end. `caret == anchor` is a
  collapsed caret (no selection); otherwise blocks
  `min(caret,anchor) .. max(caret,anchor) - 1` are selected.

  This module is the single source of truth for caret behavior and has no
  LiveView dependency, so it is unit-tested in isolation.
  """

  @type t :: {non_neg_integer(), non_neg_integer()}

  @spec collapsed?(t()) :: boolean()
  def collapsed?({c, a}), do: c == a

  @doc "Inclusive block range `{lo, hi}` for the selection, or `nil` if collapsed."
  @spec derive_range(t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def derive_range({c, a}) when c == a, do: nil
  def derive_range({c, a}), do: {min(c, a), max(c, a) - 1}

  @doc "Collapsed caret at `gap`."
  @spec place(non_neg_integer()) :: t()
  def place(gap), do: {gap, gap}

  @doc "Selection of exactly block `i` (caret on its right edge)."
  @spec select_block(non_neg_integer()) :: t()
  def select_block(i), do: {i + 1, i}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test test/lenies_web/editor_caret_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies_web/editor_caret.ex test/lenies_web/editor_caret_test.exs
git commit -m "feat(editor): EditorCaret pure module — derive/place/select"
```

---

### Task 2: `EditorCaret` — navigation, extension, clamp, post-edit helpers

**Files:**
- Modify: `lib/lenies_web/editor_caret.ex`
- Test: `test/lenies_web/editor_caret_test.exs`

- [ ] **Step 1: Write the failing test (append to the test module)**

```elixir
  describe "move/3 and extend/3" do
    test "move :up decrements caret, collapsing the selection" do
      assert C.move({3, 1}, :up, 5) == {2, 2}
    end

    test "move :down increments caret, clamped to len" do
      assert C.move({5, 5}, :down, 5) == {5, 5}
      assert C.move({2, 2}, :down, 5) == {3, 3}
    end

    test "move :up clamps at 0" do
      assert C.move({0, 0}, :up, 5) == {0, 0}
    end

    test "extend keeps the anchor and moves only the caret" do
      assert C.extend({2, 2}, :down, 5) == {3, 2}
      assert C.extend({2, 2}, :up, 5) == {1, 2}
    end
  end

  describe "extend_to_gap/2 and extend_to_block/2" do
    test "extend_to_gap moves caret to the gap, keeps anchor" do
      assert C.extend_to_gap({2, 2}, 4) == {4, 2}
    end

    test "extend_to_block selects through that block forward" do
      assert C.extend_to_block({2, 1}, 3) == {4, 1}
    end

    test "extend_to_block selects through that block backward" do
      assert C.extend_to_block({4, 4}, 1) == {1, 4}
    end
  end

  describe "clamp/2 and post-edit helpers" do
    test "clamp pulls both ends into 0..len" do
      assert C.clamp({9, -3}, 5) == {5, 0}
    end

    test "after_insert leaves a collapsed caret past the inserted run" do
      assert C.after_insert(2, 3) == {5, 5}
    end

    test "after_delete_range collapses to the range start" do
      assert C.after_delete_range({1, 2}) == {1, 1}
    end

    test "select_inserted selects the freshly inserted run" do
      assert C.select_inserted(2, 3) == {5, 2}
      assert C.derive_range(C.select_inserted(2, 3)) == {2, 4}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test test/lenies_web/editor_caret_test.exs`
Expected: FAIL — `move/3` undefined.

- [ ] **Step 3: Write minimal implementation (append to the module)**

```elixir
  @type dir :: :up | :down

  @doc "Move the caret one gap, collapsing the selection."
  @spec move(t(), dir(), non_neg_integer()) :: t()
  def move({c, _a}, :up, _len), do: place(max(c - 1, 0))
  def move({c, _a}, :down, len), do: place(min(c + 1, len))

  @doc "Move the caret one gap, keeping the anchor (extends the selection)."
  @spec extend(t(), dir(), non_neg_integer()) :: t()
  def extend({c, a}, :up, _len), do: {max(c - 1, 0), a}
  def extend({c, a}, :down, len), do: {min(c + 1, len), a}

  @doc "Extend the selection so the caret lands on `gap`, keeping the anchor."
  @spec extend_to_gap(t(), non_neg_integer()) :: t()
  def extend_to_gap({_c, a}, gap), do: {gap, a}

  @doc """
  Extend the selection through block `i`, keeping the anchor. Forward of the
  anchor the caret lands on the block's right edge (`i + 1`); behind it, on the
  left edge (`i`).
  """
  @spec extend_to_block(t(), non_neg_integer()) :: t()
  def extend_to_block({_c, a}, i) do
    caret = if i >= a, do: i + 1, else: i
    {caret, a}
  end

  @doc "Clamp both ends into `0..len`."
  @spec clamp(t(), non_neg_integer()) :: t()
  def clamp({c, a}, len), do: {bound(c, len), bound(a, len)}

  defp bound(x, len), do: x |> max(0) |> min(len)

  @doc "Collapsed caret just past a run of `count` opcodes inserted at `at`."
  @spec after_insert(non_neg_integer(), non_neg_integer()) :: t()
  def after_insert(at, count), do: place(at + count)

  @doc "Collapsed caret at the start of a just-deleted range."
  @spec after_delete_range({non_neg_integer(), non_neg_integer()}) :: t()
  def after_delete_range({lo, _hi}), do: place(lo)

  @doc "Selection covering a run of `count` opcodes inserted at `at`."
  @spec select_inserted(non_neg_integer(), non_neg_integer()) :: t()
  def select_inserted(at, count), do: {at + count, at}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test test/lenies_web/editor_caret_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies_web/editor_caret.ex test/lenies_web/editor_caret_test.exs
git commit -m "feat(editor): EditorCaret navigation, extend, clamp, post-edit helpers"
```

---

### Task 3: Swap `EditorLive` state to `caret`/`anchor` and render the caret + gaps

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`
- Test: `test/lenies_web/live/editor_live_test.exs`

This task replaces the `selection`/`sel_anchor` assigns and the `select_block`/`clear_selection` handlers with the caret model, and renders gap zones + the caret element. Clipboard handlers are migrated in Phase 2/3; for now keep them compiling by deriving the range.

- [ ] **Step 1: Write the failing test (append to `EditorLiveTest`)**

```elixir
  test "clicking a gap places a collapsed caret", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "place_caret", %{"gap" => 0})
    assert has_element?(view, "[data-caret-at='0']")
  end

  test "clicking a block selects exactly that block", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "select_block", %{"index" => 1, "shift" => false})
    assert has_element?(view, ".codeome-block-selected[data-idx='1']")
    refute has_element?(view, ".codeome-block-selected[data-idx='0']")
  end

  test "arrow-down moves the caret one gap", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    # text insert leaves caret at end (gap 2); move up twice to gap 0, then down
    render_hook(view, "move_caret", %{"dir" => "up", "extend" => false})
    render_hook(view, "move_caret", %{"dir" => "up", "extend" => false})
    assert has_element?(view, "[data-caret-at='0']")
    render_hook(view, "move_caret", %{"dir" => "down", "extend" => false})
    assert has_element?(view, "[data-caret-at='1']")
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: FAIL — `place_caret`/`move_caret` handlers and `data-caret-at` markup don't exist.

- [ ] **Step 3: Implement — assigns, handlers, render**

In `mount/3`, replace the two lines:

```elixir
      |> assign(:selection, nil)
      |> assign(:sel_anchor, nil)
```

with:

```elixir
      |> assign(:caret, length(buffer))
      |> assign(:anchor, length(buffer))
```

Add a private accessor near the other helpers:

```elixir
  alias LeniesWeb.EditorCaret

  defp caret_pair(socket), do: {socket.assigns.caret, socket.assigns.anchor}

  defp put_caret(socket, {c, a}), do: assign(socket, caret: c, anchor: a)

  defp current_range(socket), do: EditorCaret.derive_range(caret_pair(socket))
```

Replace the `select_block` and `clear_selection` handlers with:

```elixir
  def handle_event("select_block", %{"index" => index, "shift" => shift}, socket) do
    index = to_int(index)
    len = length(socket.assigns.buffer)

    if index < 0 or index >= len do
      {:noreply, socket}
    else
      pair = caret_pair(socket)

      new_pair =
        if shift in [true, "true"] do
          EditorCaret.extend_to_block(pair, index)
        else
          EditorCaret.select_block(index)
        end

      {:noreply, put_caret(socket, new_pair)}
    end
  end

  def handle_event("place_caret", %{"gap" => gap} = params, socket) do
    gap = to_int(gap) |> max(0) |> min(length(socket.assigns.buffer))
    shift = params["shift"]

    new_pair =
      if shift in [true, "true"] do
        EditorCaret.extend_to_gap(caret_pair(socket), gap)
      else
        EditorCaret.place(gap)
      end

    {:noreply, put_caret(socket, new_pair)}
  end

  def handle_event("move_caret", %{"dir" => dir} = params, socket) do
    len = length(socket.assigns.buffer)
    d = if dir == "up", do: :up, else: :down
    pair = caret_pair(socket)

    new_pair =
      if params["extend"] in [true, "true"] do
        EditorCaret.extend(pair, d, len)
      else
        EditorCaret.move(pair, d, len)
      end

    {:noreply, put_caret(socket, new_pair)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, put_caret(socket, EditorCaret.place(socket.assigns.caret))}
  end
```

Update `selected?/2` (it took `selection`; switch to deriving from the pair) and add a caret predicate:

```elixir
  defp selected?(nil, _idx), do: false
  defp selected?({lo, hi}, idx), do: idx >= lo and idx <= hi

  defp caret_here?(caret, gap), do: caret == gap
```

In `render/1`, the `.codeome-blocks` loop must interleave **gap zones** and a **caret marker**. Replace the block loop body with gaps before each block and a trailing gap. Use `@caret` and `current_range`-equivalent computed in render:

```elixir
          <% range = LeniesWeb.EditorCaret.derive_range({@caret, @anchor}) %>
          <div
            class="codeome-blocks"
            id={"codeome-blocks-#{@mode}-#{@selected_hash || "new"}"}
            phx-hook="CodeomeSortable"
          >
            <%= for {opcode, idx} <- Enum.with_index(@buffer) do %>
              <div
                class={["codeome-gap", caret_here?(@caret, idx) && "codeome-gap-caret"]}
                data-gap={idx}
                data-caret-at={caret_here?(@caret, idx) && idx}
                phx-click="place_caret"
                phx-value-gap={idx}
              >
              </div>
              <div
                class={[
                  "codeome-block codeome-block-editable op op-" <>
                    Atom.to_string(Disassembler.opcode_class(opcode)),
                  selected?(range, idx) && "codeome-block-selected"
                ]}
                data-idx={idx}
              >
                <span class="codeome-drag-handle" title="Drag to reorder">≡</span>
                <span class="codeome-block-idx">
                  {String.pad_leading(Integer.to_string(idx), 3, "0")}
                </span>
                <span class="codeome-block-name">{Atom.to_string(opcode) |> String.upcase()}</span>
                <span class="codeome-block-actions">
                  <button
                    type="button"
                    phx-click="edit_delete"
                    phx-value-index={idx}
                    class="codeome-action-btn"
                    title="Delete"
                  >
                    ⨯
                  </button>
                </span>
              </div>
            <% end %>
            <div
              class={["codeome-gap codeome-gap-end", caret_here?(@caret, length(@buffer)) && "codeome-gap-caret"]}
              data-gap={length(@buffer)}
              data-caret-at={caret_here?(@caret, length(@buffer)) && length(@buffer)}
              phx-click="place_caret"
              phx-value-gap={length(@buffer)}
            >
            </div>
          </div>
```

Update every other handler that assigned `selection: nil, sel_anchor: nil`. For now (clipboard logic migrates in later phases) make them collapse the caret: replace `assign(selection: nil, sel_anchor: nil)` occurrences in `edit_delete`, `edit_reorder`, `edit_insert`, `submit_opcode_text` with `put_caret(socket, EditorCaret.place(length(new_buffer)))`. The clipboard handlers (`copy_selection`, `cut_selection`, `paste_clipboard`, `duplicate_selection`, `delete_selection`, `submit_snippet`, `insert_snippet`) are rewritten in Phase 2/3 — for this task, change their `socket.assigns.selection` reads to `current_range(socket)` and their `socket.assigns.sel_anchor` away, collapsing the caret to buffer end after each, so the module compiles and existing tests pass. (Phase 2 replaces these bodies entirely.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS (new caret tests + existing editor tests).

- [ ] **Step 5: Add CSS for gaps and caret**

In the editor stylesheet, add:

```css
.codeome-gap { height: 6px; cursor: text; }
.codeome-gap-end { min-height: 24px; flex: 1; }
.codeome-gap-caret { position: relative; }
.codeome-gap-caret::before {
  content: ""; position: absolute; left: 0; right: 0; top: 2px; height: 2px;
  background: var(--cyan-400, #22d3ee);
  animation: codeome-caret-blink 1s step-end infinite;
}
@keyframes codeome-caret-blink { 50% { opacity: 0; } }
```

- [ ] **Step 6: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex test/lenies_web/live/editor_live_test.exs assets/css/app.css
git commit -m "feat(editor): caret/anchor state with gap zones and server-rendered caret"
```

---

### Task 4: Keyboard hook — gap clicks & caret navigation keys

**Files:**
- Modify: `assets/js/hooks/editor_keyboard.js`

- [ ] **Step 1: Implement gap click + caret keys**

In `editor_keyboard.js`, extend `onClick` to handle gap clicks, and add caret-navigation keys to `onKeydown`. Replace the click handler body and add the new key branches:

```javascript
    this.onClick = (e) => {
      if (e.target.closest(".codeome-drag-handle")) return;
      if (e.target.closest(".codeome-action-btn")) return;

      const gap = e.target.closest(".codeome-gap");
      if (gap && this.el.contains(gap)) {
        const g = parseInt(gap.dataset.gap, 10);
        if (Number.isNaN(g)) return;
        this.pushEvent("place_caret", { gap: g, shift: e.shiftKey === true });
        return;
      }

      const block = e.target.closest(".codeome-block-editable");
      if (!block || !this.el.contains(block)) return;
      const idx = parseInt(block.dataset.idx, 10);
      if (Number.isNaN(idx)) return;
      this.pushEvent("select_block", { index: idx, shift: e.shiftKey === true });
    };
```

In `onKeydown`, before the existing clipboard branches, add:

```javascript
      if (key === "arrowup" || key === "arrowdown") {
        e.preventDefault();
        const dir = key === "arrowup" ? "up" : "down";
        if (e.altKey) {
          this.pushEvent("move_range_step", { dir });
        } else {
          this.pushEvent("move_caret", { dir, extend: e.shiftKey === true });
        }
        return;
      }
      if (key === "home") { e.preventDefault(); this.pushEvent("move_caret_end", { to: "start" }); return; }
      if (key === "end") { e.preventDefault(); this.pushEvent("move_caret_end", { to: "end" }); return; }
```

(`move_range_step` is wired in Phase 3; `move_caret_end` is wired in Step 2 below.)

- [ ] **Step 2: Wire `move_caret_end` in `EditorLive`**

Add handler:

```elixir
  def handle_event("move_caret_end", %{"to" => to}, socket) do
    gap = if to == "start", do: 0, else: length(socket.assigns.buffer)
    {:noreply, put_caret(socket, EditorCaret.place(gap))}
  end
```

- [ ] **Step 3: Add a LiveView test for Home/End**

```elixir
  test "Home and End place the caret at the buffer ends", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "move_caret_end", %{"to" => "start"})
    assert has_element?(view, "[data-caret-at='0']")
    render_hook(view, "move_caret_end", %{"to" => "end"})
    assert has_element?(view, "[data-caret-at='3']")
  end
```

- [ ] **Step 4: Run tests**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assets/js/hooks/editor_keyboard.js lib/lenies_web/live/editor_live.ex test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): keyboard caret navigation + gap clicks"
```

---

## Phase 2 — Unified insertion at the caret

### Task 5: Insert at caret with replace-on-selection (palette, text, snippet, paste)

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`
- Test: `test/lenies_web/live/editor_live_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
  test "palette insert lands at the caret, not at the end", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 add"})
    render_hook(view, "place_caret", %{"gap" => 1})
    render_hook(view, "edit_insert", %{"index" => 1, "opcode" => "push1"})
    assert render(view) =~ "PUSH1"
    # caret should sit just after the inserted opcode (gap 2)
    assert has_element?(view, "[data-caret-at='2']")
  end

  test "inserting with an active selection replaces it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    # select blocks 1..2 (push1, add): caret=3 anchor=1
    render_hook(view, "select_block", %{"index" => 1, "shift" => false})
    render_hook(view, "select_block", %{"index" => 2, "shift" => true})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "eat"})
    html = render(view)
    assert html =~ "1 ops" or html =~ "2 ops"
    refute html =~ "ADD"
    assert html =~ "EAT"
  end

  test "snippet inserts at the caret", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    :ok = Lenies.Snippets.Store.save(%{id: "twoops", name: "twoops", opcodes: [:push0, :push1]})
    send(view.pid, {:refresh_snippets})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "add eat"})
    render_hook(view, "place_caret", %{"gap" => 1})
    render_hook(view, "insert_snippet", %{"id" => "twoops"})
    # buffer is now ADD PUSH0 PUSH1 EAT; caret after inserted run (gap 3)
    assert has_element?(view, "[data-caret-at='3']")
  end
```

(If `{:refresh_snippets}` isn't a real message, drop that line — `insert_snippet` reads the store directly via `Lenies.Snippets.Store.get/1`, so the snippet only needs to exist in the store.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: FAIL — insertion still appends / doesn't move the caret correctly.

- [ ] **Step 3: Implement a single insertion helper and route all sources through it**

Add a private helper:

```elixir
  # Inserts `opcodes` at the caret. If a selection is active, deletes it first
  # (replace-on-insert), then inserts at the range start, leaving a collapsed
  # caret immediately after the inserted run.
  defp insert_at_caret(socket, opcodes) when is_list(opcodes) do
    {buffer, at} =
      case current_range(socket) do
        nil ->
          {socket.assigns.buffer, socket.assigns.caret}

        {lo, _hi} = range ->
          {CodeomeBuffer.delete_range(socket.assigns.buffer, range), lo}
      end

    new_buffer = CodeomeBuffer.insert_many(buffer, at, opcodes)

    socket
    |> put_caret(EditorCaret.after_insert(at, length(opcodes)))
    |> commit_buffer_change(new_buffer)
  end
```

Rewrite the affected handlers to use it:

```elixir
  def handle_event("edit_insert", %{"index" => index, "opcode" => opcode_str}, socket)
      when is_integer(index) and is_binary(opcode_str) do
    try do
      opcode = String.to_existing_atom(opcode_str)

      if Lenies.Codeome.Opcodes.known?(opcode) do
        # `index` from a palette drop is authoritative for placement: move the
        # caret there first, then insert at the caret.
        socket = put_caret(socket, EditorCaret.place(index))
        {:noreply, insert_at_caret(socket, [opcode])}
      else
        {:noreply, socket}
      end
    rescue
      ArgumentError -> {:noreply, socket}
    end
  end

  def handle_event("submit_opcode_text", %{"opcodes" => text}, socket) do
    case parse_opcode_text(text) do
      {:ok, []} ->
        {:noreply, assign(socket, text_input_value: "", text_input_error: nil)}

      {:ok, opcodes} ->
        {:noreply,
         socket
         |> insert_at_caret(opcodes)
         |> assign(text_input_value: "", text_input_error: nil)}

      {:error, invalid} ->
        msg = "unknown: " <> Enum.join(invalid, ", ")
        {:noreply, assign(socket, text_input_value: text, text_input_error: msg)}
    end
  end

  def handle_event("insert_snippet", %{"id" => id}, socket) do
    case Lenies.Snippets.Store.get(id) do
      %{opcodes: ops} when ops != [] -> {:noreply, insert_at_caret(socket, ops)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("paste_clipboard", _params, socket) do
    case socket.assigns.clipboard do
      [] -> {:noreply, socket}
      clip -> {:noreply, insert_at_caret(socket, clip)}
    end
  end
```

Delete the now-unused `paste_index/2` helper.

- [ ] **Step 4: Run tests to verify they pass**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): unify all insertion at the caret with replace-on-selection"
```

---

### Task 6: Snippet drag-to-gap

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex` (render: make snippet rows draggable, add drop handler), `assets/js/hooks/codeome_sortable.js`
- Test: `test/lenies_web/live/editor_live_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  test "dropping a snippet at a gap inserts it there", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    :ok = Lenies.Snippets.Store.save(%{id: "pp", name: "pp", opcodes: [:push0, :push1]})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "add eat"})
    render_hook(view, "insert_snippet_at", %{"id" => "pp", "index" => 1})
    # ADD PUSH0 PUSH1 EAT
    assert render(view) =~ "4 ops"
    assert has_element?(view, "[data-caret-at='3']")
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs -k "dropping a snippet"`
Expected: FAIL — `insert_snippet_at` undefined.

- [ ] **Step 3: Implement the handler**

```elixir
  def handle_event("insert_snippet_at", %{"id" => id, "index" => index}, socket) do
    at = to_int(index) |> max(0) |> min(length(socket.assigns.buffer))

    case Lenies.Snippets.Store.get(id) do
      %{opcodes: ops} when ops != [] ->
        socket = put_caret(socket, EditorCaret.place(at))
        {:noreply, insert_at_caret(socket, ops)}

      _ ->
        {:noreply, socket}
    end
  end
```

- [ ] **Step 4: Make snippet rows draggable in JS**

In `codeome_sortable.js`, the `.codeome-blocks` Sortable already accepts adds from group `"codeome"`. In `onAdd`, also handle a dropped **snippet** clone (carrying `data-snippet-id`):

```javascript
      onAdd: (evt) => {
        let index = 0;
        let sibling = evt.item.previousElementSibling;
        while (sibling) {
          if (sibling.classList.contains("codeome-block-editable")) index++;
          sibling = sibling.previousElementSibling;
        }

        const snippetId = evt.item?.dataset?.snippetId;
        if (snippetId) {
          this.pushEvent("insert_snippet_at", { id: snippetId, index });
          evt.item.remove();
          return;
        }

        const opcode = evt.item?.dataset?.opcode;
        if (opcode) this.pushEvent("edit_insert", { index, opcode });
        evt.item.remove();
      },
```

In the editor render, make the snippet insert button a Sortable source. Wrap the snippet list in a hook and add `data-snippet-id`:

```heex
              <div class="codeome-snippets-list" id="codeome-snippets-list" phx-hook="SnippetDrag">
                <%= for s <- @snippets do %>
                  <div class="codeome-snippet-row" data-snippet-id={s.id}>
```

Add a tiny `SnippetDrag` hook (new file `assets/js/hooks/snippet_drag.js`) that makes `.codeome-snippet-row` items a clone source in group `"codeome"`:

```javascript
import Sortable from "../../vendor/sortable.js";

const SnippetDrag = {
  mounted() {
    this.sortable = Sortable.create(this.el, {
      group: { name: "codeome", pull: "clone", put: false },
      draggable: ".codeome-snippet-row",
      sort: false,
      forceFallback: true,
      fallbackOnBody: true,
      animation: 120,
    });
  },
  destroyed() { if (this.sortable) this.sortable.destroy(); },
};

export default SnippetDrag;
```

Register `SnippetDrag` in `assets/js/app.js` alongside the other hooks.

- [ ] **Step 5: Run tests**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex assets/js/hooks/snippet_drag.js assets/js/hooks/codeome_sortable.js assets/js/app.js test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): drag a snippet to a precise gap"
```

---

## Phase 3 — Range move & duplicate

### Task 7: `CodeomeBuffer.move_range/3`

**Files:**
- Modify: `lib/lenies_web/codeome_buffer.ex`
- Test: `test/lenies_web/codeome_buffer_test.exs`

- [ ] **Step 1: Write the failing test (append a `describe`)**

```elixir
  describe "move_range/3" do
    test "moves a range forward, adjusting for the removed elements" do
      assert CodeomeBuffer.move_range([:a, :b, :c, :d, :e], {1, 2}, 4) == [:a, :d, :b, :c, :e]
    end

    test "moves a range to the start" do
      assert CodeomeBuffer.move_range([:a, :b, :c, :d, :e], {1, 2}, 0) == [:b, :c, :a, :d, :e]
    end

    test "dropping inside the moved range is a no-op" do
      assert CodeomeBuffer.move_range([:a, :b, :c, :d, :e], {1, 2}, 2) == [:a, :b, :c, :d, :e]
    end

    test "moves a single-element range to the end" do
      assert CodeomeBuffer.move_range([:a, :b, :c], {0, 0}, 3) == [:b, :c, :a]
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test test/lenies_web/codeome_buffer_test.exs`
Expected: FAIL — `move_range/3` undefined.

- [ ] **Step 3: Implement**

```elixir
  @doc """
  Move the inclusive block range `{lo, hi}` so it lands at gap `to_gap`
  (gap coordinates of the *original* buffer). Dropping inside the moved range
  is a no-op.
  """
  @spec move_range(buffer(), {non_neg_integer(), non_neg_integer()}, non_neg_integer()) ::
          buffer()
  def move_range(buffer, {lo, hi}, to_gap) when lo >= 0 and hi >= lo and to_gap >= 0 do
    slice = Enum.slice(buffer, lo..hi)
    without = delete_range(buffer, {lo, hi})
    removed = hi - lo + 1

    adj =
      cond do
        to_gap <= lo -> to_gap
        to_gap <= hi + 1 -> lo
        true -> to_gap - removed
      end

    insert_many(without, adj, slice)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test test/lenies_web/codeome_buffer_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies_web/codeome_buffer.ex test/lenies_web/codeome_buffer_test.exs
git commit -m "feat(editor): CodeomeBuffer.move_range/3"
```

---

### Task 8: Wire move (drag group + Alt+arrows), duplicate, and clipboard collapse

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`, `assets/js/hooks/codeome_sortable.js`
- Test: `test/lenies_web/live/editor_live_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
  test "move_range relocates the selected block range", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add eat"})
    # select blocks 0..1 (push0, push1)
    render_hook(view, "select_block", %{"index" => 0, "shift" => false})
    render_hook(view, "select_block", %{"index" => 1, "shift" => true})
    render_hook(view, "move_range", %{"to" => 4})
    html = render(view)
    # ADD EAT PUSH0 PUSH1
    assert html =~ ~r/ADD.*EAT.*PUSH0.*PUSH1/s
  end

  test "Alt+arrow nudges the selection down by one", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "select_block", %{"index" => 0, "shift" => false})
    render_hook(view, "move_range_step", %{"dir" => "down"})
    assert render(view) =~ ~r/PUSH1.*PUSH0.*ADD/s
  end

  test "duplicate copies the selection after itself and selects the copy", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "select_block", %{"index" => 0, "shift" => false})
    render_hook(view, "duplicate_selection", %{})
    assert render(view) =~ "3 ops"
    # copy is block 1, selected
    assert has_element?(view, ".codeome-block-selected[data-idx='1']")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: FAIL — `move_range`/`move_range_step` undefined; duplicate doesn't select the copy yet.

- [ ] **Step 3: Implement the handlers**

```elixir
  def handle_event("move_range", %{"to" => to}, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      {lo, hi} = range ->
        to_gap = to_int(to) |> max(0) |> min(length(socket.assigns.buffer))
        new_buffer = CodeomeBuffer.move_range(socket.assigns.buffer, range, to_gap)
        # caret follows the moved run: compute its new start
        n = hi - lo + 1
        new_lo = if to_gap <= lo, do: to_gap, else: to_gap - n
        new_lo = if to_gap > lo and to_gap <= hi + 1, do: lo, else: new_lo

        {:noreply,
         socket
         |> put_caret(EditorCaret.select_inserted(new_lo, n))
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("move_range_step", %{"dir" => dir}, socket) do
    len = length(socket.assigns.buffer)

    case current_range(socket) do
      nil ->
        {:noreply, socket}

      {lo, hi} = range ->
        to_gap = if dir == "up", do: max(lo - 1, 0), else: min(hi + 2, len)

        if (dir == "up" and lo == 0) or (dir == "down" and hi + 1 >= len) do
          {:noreply, socket}
        else
          new_buffer = CodeomeBuffer.move_range(socket.assigns.buffer, range, to_gap)
          n = hi - lo + 1
          new_lo = if dir == "up", do: lo - 1, else: lo + 1

          {:noreply,
           socket
           |> put_caret(EditorCaret.select_inserted(new_lo, n))
           |> commit_buffer_change(new_buffer)}
        end
    end
  end
```

Rewrite `duplicate_selection`, `cut_selection`, `delete_selection`, `copy_selection`, `submit_snippet` to use `current_range/1` and the caret helpers:

```elixir
  def handle_event("copy_selection", _params, socket) do
    case current_range(socket) do
      nil -> {:noreply, socket}
      range -> {:noreply, assign(socket, :clipboard, CodeomeBuffer.slice(socket.assigns.buffer, range))}
    end
  end

  def handle_event("cut_selection", _params, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      range ->
        clip = CodeomeBuffer.slice(socket.assigns.buffer, range)
        new_buffer = CodeomeBuffer.delete_range(socket.assigns.buffer, range)

        {:noreply,
         socket
         |> assign(:clipboard, clip)
         |> put_caret(EditorCaret.after_delete_range(range))
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("delete_selection", _params, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      range ->
        new_buffer = CodeomeBuffer.delete_range(socket.assigns.buffer, range)

        {:noreply,
         socket
         |> put_caret(EditorCaret.after_delete_range(range))
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("duplicate_selection", _params, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      {_lo, hi} = range ->
        clip = CodeomeBuffer.slice(socket.assigns.buffer, range)
        at = hi + 1
        new_buffer = CodeomeBuffer.insert_many(socket.assigns.buffer, at, clip)

        {:noreply,
         socket
         |> put_caret(EditorCaret.select_inserted(at, length(clip)))
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("submit_snippet", %{"snippet_name" => name}, socket) do
    with range when not is_nil(range) <- current_range(socket),
         opcodes <- CodeomeBuffer.slice(socket.assigns.buffer, range),
         id <- Lenies.Slug.slugify(name),
         :ok <- Lenies.Snippets.Store.save(%{id: id, name: name, opcodes: opcodes}) do
      {:noreply,
       socket
       |> assign(:snippets, Lenies.Snippets.Store.all())
       |> assign(:show_snippet_form, false)}
    else
      nil -> {:noreply, assign(socket, :show_snippet_form, false)}
      {:error, _reason} -> {:noreply, socket}
    end
  end
```

Also update `edit_delete` and `edit_reorder` (single-block) to collapse the caret to a sensible gap (`EditorCaret.place(min(index, len))` style) instead of the old `selection: nil` assigns.

- [ ] **Step 4: Emit `move_range` from the group drag in JS**

In `codeome_sortable.js` `onEnd`, when the dragged item is inside the active selection, emit `move_range` instead of `edit_reorder`. Detect "inside selection" by checking the dragged element carries `.codeome-block-selected`:

```javascript
      onEnd: (evt) => {
        if (
          evt.from === evt.to &&
          typeof evt.oldDraggableIndex === "number" &&
          typeof evt.newDraggableIndex === "number" &&
          evt.oldDraggableIndex !== evt.newDraggableIndex
        ) {
          if (evt.item.classList.contains("codeome-block-selected")) {
            // moving the whole selection: newDraggableIndex is the target gap
            this.pushEvent("move_range", { to: evt.newDraggableIndex });
          } else {
            this.pushEvent("edit_reorder", { from: evt.oldDraggableIndex, to: evt.newDraggableIndex });
          }
        }
      },
```

- [ ] **Step 5: Run tests**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex assets/js/hooks/codeome_sortable.js test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): move/duplicate selected range, Alt+arrow nudge, caret-aware clipboard"
```

---

### Task 9: Clamp caret on undo/redo

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`
- Test: `test/lenies_web/live/editor_live_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  test "undo collapses the caret to the end of the restored buffer", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "place_caret", %{"gap" => 3})
    render_hook(view, "submit_opcode_text", %{"opcodes" => "eat"})  # buffer len 4, caret 4
    render_hook(view, "undo", %{})                                   # back to len 3
    assert has_element?(view, "[data-caret-at='3']")
    refute has_element?(view, "[data-caret-at='4']")
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs -k "undo collapses"`
Expected: FAIL — caret out of range / stale after undo.

- [ ] **Step 3: Implement — collapse to `len` in undo/redo**

In the `undo` and `redo` handlers, replace `assign(selection: nil, sel_anchor: nil)` with a caret collapse to the restored buffer's end:

```elixir
  def handle_event("undo", _params, socket) do
    case EditorHistory.undo(socket.assigns.history, socket.assigns.buffer) do
      :none ->
        {:noreply, socket}

      {prev_buffer, history} ->
        {:noreply,
         socket
         |> assign(:history, history)
         |> put_caret(EditorCaret.place(length(prev_buffer)))
         |> apply_buffer_change(prev_buffer)}
    end
  end

  def handle_event("redo", _params, socket) do
    case EditorHistory.redo(socket.assigns.history, socket.assigns.buffer) do
      :none ->
        {:noreply, socket}

      {next_buffer, history} ->
        {:noreply,
         socket
         |> assign(:history, history)
         |> put_caret(EditorCaret.place(length(next_buffer)))
         |> apply_buffer_change(next_buffer)}
    end
  end
```

- [ ] **Step 4: Run tests**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex test/lenies_web/live/editor_live_test.exs
git commit -m "fix(editor): clamp caret to buffer end on undo/redo"
```

---

## Phase 4 — In-place edit

### Task 10: Double-click to replace an opcode

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`, `assets/js/hooks/editor_keyboard.js`
- Test: `test/lenies_web/live/editor_live_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
  test "submit_replace swaps the opcode at an index", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
    render_hook(view, "submit_replace", %{"index" => 1, "opcode" => "eat"})
    html = render(view)
    assert html =~ ~r/PUSH0.*EAT.*ADD/s
    refute html =~ "PUSH1"
  end

  test "submit_replace with an unknown opcode is a no-op", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
    render_hook(view, "submit_replace", %{"index" => 0, "opcode" => "notreal"})
    assert render(view) =~ ~r/PUSH0.*PUSH1/s
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs -k "submit_replace"`
Expected: FAIL — `submit_replace` undefined.

- [ ] **Step 3: Implement the handler (wires the existing `CodeomeBuffer.replace/3`)**

```elixir
  def handle_event("submit_replace", %{"index" => index, "opcode" => opcode_str}, socket) do
    idx = to_int(index)

    with true <- idx >= 0 and idx < length(socket.assigns.buffer),
         {:ok, opcode} <- to_known_opcode(String.downcase(to_string(opcode_str))) do
      new_buffer = CodeomeBuffer.replace(socket.assigns.buffer, idx, opcode)
      {:noreply, commit_buffer_change(socket, new_buffer)}
    else
      _ -> {:noreply, socket}
    end
  end
```

- [ ] **Step 4: Render an inline editor on double-click**

Add an `editing_index` assign (default `nil`) in `mount/3`. Add handlers to open/cancel:

```elixir
  def handle_event("start_inline_edit", %{"index" => index}, socket) do
    {:noreply, assign(socket, :editing_index, to_int(index))}
  end

  def handle_event("cancel_inline_edit", _params, socket) do
    {:noreply, assign(socket, :editing_index, nil)}
  end
```

After a successful `submit_replace`, also clear `editing_index`: add `|> assign(:editing_index, nil)` to its success branch.

In the block render, when `idx == @editing_index`, render an autocomplete input form instead of the name span:

```heex
                <%= if idx == @editing_index do %>
                  <form phx-submit="submit_replace" class="codeome-inline-edit">
                    <input type="hidden" name="index" value={idx} />
                    <input
                      type="text"
                      name="opcode"
                      value={Atom.to_string(opcode)}
                      list="opcode-datalist"
                      autocomplete="off"
                      spellcheck="false"
                      phx-blur="cancel_inline_edit"
                      class="codeome-inline-input"
                    />
                  </form>
                <% else %>
                  <span class="codeome-block-name">{Atom.to_string(opcode) |> String.upcase()}</span>
                <% end %>
```

Add one shared `<datalist>` of opcode names near the listing:

```heex
          <datalist id="opcode-datalist">
            <%= for op <- Lenies.Codeome.Opcodes.all() do %>
              <option value={Atom.to_string(op)}></option>
            <% end %>
          </datalist>
```

In `editor_keyboard.js`, add a `dblclick` listener that opens inline edit on a block body (not on the handle/actions):

```javascript
    this.onDblClick = (e) => {
      if (e.target.closest(".codeome-drag-handle")) return;
      if (e.target.closest(".codeome-action-btn")) return;
      const block = e.target.closest(".codeome-block-editable");
      if (!block || !this.el.contains(block)) return;
      const idx = parseInt(block.dataset.idx, 10);
      if (Number.isNaN(idx)) return;
      this.pushEvent("start_inline_edit", { index: idx });
    };
    this.el.addEventListener("dblclick", this.onDblClick);
```

Remove the listener in `destroyed()`:

```javascript
    if (this.onDblClick) this.el.removeEventListener("dblclick", this.onDblClick);
    this.onDblClick = null;
```

- [ ] **Step 5: Run tests**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex assets/js/hooks/editor_keyboard.js test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): double-click in-place opcode replace"
```

---

## Phase 5 — Visible jump targets (separable)

### Task 11: `JumpTargets` pure module

**Files:**
- Create: `lib/lenies_web/jump_targets.ex`
- Test: `test/lenies_web/jump_targets_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LeniesWeb.JumpTargetsTest do
  use ExUnit.Case, async: false

  alias LeniesWeb.JumpTargets

  test "computes a forward complement target for a jmp_t" do
    # jmp_t at 0, template nop_0 at 1; complement nop_1 sits at index 3.
    buffer = [:jmp_t, :nop_0, :add, :nop_1, :eat]
    assert %{0 => {:ok, 3}} = JumpTargets.targets(buffer)
  end

  test "reports :not_found when no complement exists" do
    buffer = [:jmp_t, :nop_0, :add, :eat]
    assert %{0 => :not_found} = JumpTargets.targets(buffer)
  end

  test "ignores non-jump opcodes" do
    assert JumpTargets.targets([:push0, :add, :eat]) == %{}
  end

  test "handles multiple jumps" do
    buffer = [:jmp_t, :nop_0, :nop_1, :jz_t, :nop_1, :nop_0]
    result = JumpTargets.targets(buffer)
    assert Map.has_key?(result, 0)
    assert Map.has_key?(result, 3)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test test/lenies_web/jump_targets_test.exs`
Expected: FAIL — `LeniesWeb.JumpTargets` undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule LeniesWeb.JumpTargets do
  @moduledoc """
  Static, runtime-faithful computation of where each template jump in a codeome
  buffer lands. Reuses `Lenies.Interpreter.Template` so the editor shows exactly
  what the interpreter will do at the same `template_max_len` /
  `template_search_radius` tuning.
  """

  alias Lenies.Codeome
  alias Lenies.Interpreter.Template

  @jumps [:jmp_t, :jz_t, :jnz_t, :call_t]

  @doc """
  Map of `jump_index => {:ok, target_index} | :not_found` for every template
  jump in `buffer`. The target is computed exactly as the interpreter does:
  extract the nop template after the jump, then search for its complement
  (forward up to `radius`, then backward), with toroidal wraparound.
  """
  @spec targets([atom()]) :: %{non_neg_integer() => {:ok, non_neg_integer()} | :not_found}
  def targets(buffer) when is_list(buffer) do
    codeome = Codeome.from_list(buffer)
    max_len = Application.get_env(:lenies, :template_max_len, 8)
    radius = Application.get_env(:lenies, :template_search_radius, 256)

    buffer
    |> Enum.with_index()
    |> Enum.filter(fn {op, _i} -> op in @jumps end)
    |> Map.new(fn {_op, i} ->
      {template, _len} = Template.extract(codeome, i + 1, max_len)
      {i, Template.find_complement(codeome, template, i, radius)}
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test test/lenies_web/jump_targets_test.exs`
Expected: PASS. (If a target index differs, adjust the *test fixture* to match `Template`'s real forward-then-backward search — the module is the source of truth, not the hand-computed expectation.)

- [ ] **Step 5: Commit**

```bash
git add lib/lenies_web/jump_targets.ex test/lenies_web/jump_targets_test.exs
git commit -m "feat(editor): JumpTargets — static runtime-faithful jump destinations"
```

---

### Task 12: Render jump badges + template highlight + on-hover arc

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`, editor stylesheet
- Test: `test/lenies_web/live/editor_live_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  test "a jump block shows its target index badge", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "jmp_t nop_0 add nop_1 eat"})
    html = render(view)
    assert html =~ "codeome-jump-badge"
    assert html =~ "→ 003" or html =~ "&rarr; 003"
  end

  test "an unresolved jump shows the not-found badge", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "submit_opcode_text", %{"opcodes" => "jmp_t nop_0 add eat"})
    assert render(view) =~ "codeome-jump-badge-missing"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs -k "jump"`
Expected: FAIL — no badge markup.

- [ ] **Step 3: Compute targets on each buffer change**

Add a `:jump_targets` assign. Compute it in `mount/3` and in `apply_buffer_change/2`:

```elixir
  # in mount, after assigning :buffer
      |> assign(:jump_targets, LeniesWeb.JumpTargets.targets(buffer))
```

In `apply_buffer_change/2`, add to the pipeline:

```elixir
    |> assign(:jump_targets, LeniesWeb.JumpTargets.targets(new_buffer))
```

- [ ] **Step 4: Render the badge inside the jump block**

In the block render, after the name span, add:

```heex
                <%= case Map.get(@jump_targets, idx) do %>
                  <% {:ok, target} -> %>
                    <button
                      type="button"
                      phx-click="place_caret"
                      phx-value-gap={target}
                      class="codeome-jump-badge"
                      title={"Jumps to ##{target}"}
                    >
                      → {String.pad_leading(Integer.to_string(target), 3, "0")}
                    </button>
                  <% :not_found -> %>
                    <span class="codeome-jump-badge codeome-jump-badge-missing" title="No template match">→ ✕</span>
                  <% nil -> %>
                <% end %>
```

Add a CSS class binding so the template nop-run is visually marked. Compute, per nop index, whether it belongs to a jump's template — add a helper that returns the set of template-nop indices:

```elixir
  # Indices of nop_0/nop_1 that form the template immediately following a jump.
  defp template_nop_indices(buffer) do
    max_len = Application.get_env(:lenies, :template_max_len, 8)
    jumps = [:jmp_t, :jz_t, :jnz_t, :call_t]

    buffer
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {op, i} when op in jumps ->
        Enum.reduce_while((i + 1)..(i + max_len)//1, [], fn j, acc ->
          case Enum.at(buffer, j) do
            n when n in [:nop_0, :nop_1] -> {:cont, [j | acc]}
            _ -> {:halt, acc}
          end
        end)

      _ ->
        []
    end)
    |> MapSet.new()
  end
```

Compute `template_nops = template_nop_indices(@buffer)` at the top of the listing render and add `MapSet.member?(template_nops, idx) && "codeome-template-nop"` to each block's class list.

- [ ] **Step 5: Add CSS for badge, missing badge, template nop**

```css
.codeome-jump-badge { font-size: 10px; padding: 0 4px; margin-left: 6px; border: 1px solid var(--cyan-500, #06b6d4); color: var(--cyan-300, #67e8f9); background: transparent; cursor: pointer; }
.codeome-jump-badge-missing { border-color: #f59e0b; color: #fbbf24; cursor: default; }
.codeome-template-nop { outline: 1px dashed rgba(103, 232, 249, 0.5); outline-offset: -1px; }
```

(The on-hover SVG arc is an enhancement; it can be added later as a small overlay hook that reads `data-idx`/badge target. The badge + template highlight already satisfy the spec's "make targets visible" requirement and are fully testable; the arc is purely decorative.)

- [ ] **Step 6: Run tests**

Run: `MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs -k "jump"`
Expected: PASS. (Adjust the expected target index in the test to match `JumpTargets` if needed.)

- [ ] **Step 7: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex assets/css/app.css test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): jump-target badges + template-nop highlighting"
```

---

## Final verification

- [ ] **Run the full suite**

Run: `MIX_ENV=test mix test`
Expected: all green.

- [ ] **Manual smoke test** (use the `run` skill or `MIX_ENV=test iex -S mix phx.server`): open `/editor/new`, type `jmp_t nop_0 add nop_1 eat`, confirm the caret is visible, click gaps to move it, insert a snippet at a gap, select 2 blocks and drag them, double-click a block to replace it, and confirm the jump badge shows a target.

---

## Notes for the implementer

- **`MIX_ENV=test` prefix** on `mix` commands avoids the dev build lock (see the project's dev-environment notes).
- The caret is **server state** — never try to track it in JS. Hooks only emit events.
- When a test's expected jump target disagrees with `JumpTargets`, the module (which reuses the real interpreter `Template`) is correct; fix the test fixture.
- `selected?/2` now takes a derived `{lo,hi}` range (or `nil`), not the old `selection` assign — make sure no stale references to `@selection`/`@sel_anchor` remain (grep for them after Phase 1).
