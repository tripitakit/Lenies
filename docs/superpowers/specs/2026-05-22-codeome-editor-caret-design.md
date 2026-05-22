# Codeome editor — explicit insertion caret & coherent editing model

**Date:** 2026-05-22
**Status:** Design approved, pending spec review
**Supersedes/extends:** `2026-05-20-codeome-editor-ergonomics-design.md` (selection, clipboard, snippets, undo/redo were introduced there)

## Problem

The codeome editor (`LeniesWeb.EditorLive`) is built on a *block-selection +
clipboard + single-block drag* model. It works, but four weak points all trace
back to one missing concept — **there is no explicit insertion point**:

1. **Where things land is implicit.** Snippets, palette double-clicks, the text
   input, and paste all follow a hidden rule (`paste_index/2`: "after the
   selection, or at the end"). The user must remember the rule rather than see
   it.
2. **You can only move one block at a time.** The drag handle reorders a single
   block. Moving a multi-block selection requires cut → re-select target →
   paste.
3. **No in-place edit; templates are opaque.** Changing one opcode means
   delete + re-insert. Template-addressed jumps (`jmp_t`/`jz_t`/`jnz_t`/`call_t`)
   read a run of `nop_0`/`nop_1` and search for the complement — but nothing in
   the UI shows which nops are a template or where a jump lands.
4. **Palette/snippet UX gaps.** Snippets can't be drag-placed at a precise spot.

**Target user:** both newcomers (manual open alongside, discoverability matters)
and the author/power users (speed). The chosen model must **scale with
experience** — obvious with a mouse, fast with the keyboard.

## Chosen approach: explicit insertion caret ("text editor for opcodes")

Introduce a **visible insertion caret** that lives *between* blocks and is the
single source of truth for where insertions land. Drag remains as an
accelerator layered on top. This one primitive explains all four weak points.

Rejected alternatives:
- **Enhanced drag-drop, no caret** — very discoverable but slow for power users
  and weak keyboard story; contradicts "scales with experience".
- **Bidirectional textual editor + synced blocks** — powerful, but two-way sync
  is treacherous and shifts focus away from the visual UX. Kept as a possible
  future direction (the current text input is a seed of it).

## Core model: caret/selection on gaps

Today's state is `selection :: nil | {lo, hi}` (block range) + `sel_anchor`.
Replace it with a text-editor-style model working on **gaps** — the slots
*between* blocks.

**State (`EditorLive` assigns):**
- `caret :: 0..len` — the gap where insertions land. Gap `i` = "before block
  `i`"; gap `len` = at the end.
- `anchor :: 0..len` — the other end of the selection.
- `caret == anchor` → collapsed: a bare blinking caret, no selection.
- `caret != anchor` → blocks `min(anchor,caret) .. max(anchor,caret) - 1` are
  selected.

The existing block range `{lo, hi}` is **derived** for the existing buffer ops:
`lo = min(anchor,caret)`, `hi = max(anchor,caret) - 1` (only meaningful when
`caret != anchor`).

```
gap:  0    1    2    3    4
      |    |    |    |    |
      +00--+01--+02--+03--+
       PUSH0 PUSH1 ADD  EAT

caret=2, anchor=2  -> caret between ADD and PUSH1, nothing selected
caret=3, anchor=1  -> blocks 1..2 selected (PUSH1, ADD), focus at right edge
```

`CodeomeBuffer` (slice / delete_range / insert_many / move) is **unchanged** —
it receives derived ranges. `clipboard` and `history` are unchanged.

### Base interaction

- **Click on a gap** (thin zone between blocks) → collapsed caret there.
- **Click on a block body `i`** → select that whole block (`anchor=i,
  caret=i+1`). Preserves today's "click selects block" habit. *(Decision: kept
  block-selection on body click; precise insertion is via gap clicks. The purer
  "click = caret before block" was considered and rejected to preserve the
  existing habit.)*
- **Shift+click** on block/gap → extend (move `caret`, keep `anchor`).
- **Arrows ↑/↓** → move caret one gap, collapsing the selection;
  **Shift+↑/↓** extends; **Home/End** jump to ends.
- **Esc** → collapse to caret.

## Insertion at the caret

All insertion sources converge on the caret. `paste_index/2` is removed.

**Single rule:** every insertion happens at gap `caret`. If a selection is
active (`caret != anchor`), first delete the derived range, then insert at
`min(anchor,caret)`, then set `caret = anchor = that_gap + n_inserted`
(collapsed caret *after* the inserted run). This is the approved **replace-on-
insert** behavior (replaces today's "paste inserts after selection").

| Source | New behavior |
|---|---|
| dblclick palette chip | insert opcode **at caret** (was: append at end) |
| text input (`push0 push1 add`) | insert sequence **at caret** (was: append) |
| insert snippet (click name) | insert snippet opcodes **at caret** (was: after selection/end) |
| paste (Ctrl/Cmd+V) | insert clipboard **at caret** |
| drag palette chip | the drop-gap highlighted during drag *is* the caret; insert there |
| drag snippet *(new)* | snippet rows become draggable to a gap, like a chip |

After every insertion the caret sits **immediately after** the inserted run, so
consecutive inserts chain naturally (snippet → type two opcodes → paste, all in
a row without re-clicking).

Consistency change: today `insert_snippet`/`paste` select the inserted range.
The new model leaves a **collapsed caret after the inserted run** instead, which
is what's expected when continuing to write. The only exception is `duplicate`
(see below).

## Range operations: move, duplicate, cut/copy/delete

**Move a multi-block selection — two ways, same result:**

1. **Drag** (accelerator, newcomer-friendly): grab any block *inside* the
   selection and drag the group; the highlighted gap is the destination. On
   drop, a new pure op `CodeomeBuffer.move_range(buffer, {lo,hi}, to_gap)`
   extracts the range and re-inserts it, recomputing the destination index net
   of the removal. JS implementation: a custom drag of the selection that emits
   a single `move_range` event (preferred over SortableJS MultiDrag for
   morphdom robustness).
2. **Keyboard / caret** (power user): select range, **cut** (Ctrl/Cmd+X → to
   clipboard, caret collapses where the range was), move the caret, **paste**.
   Predictable now because the caret is always visible.

Direct no-clipboard shortcut: **Alt+↑ / Alt+↓** moves the selection (or the
single block at the caret) up/down by one position — for micro-adjustments.

**Duplicate** (Ctrl/Cmd+D): duplicate the selection immediately after itself and
**select the copy** (so you can re-duplicate or drag it). This is the only
operation that leaves a selection rather than a collapsed caret.

**Cut/Copy/Delete:** logic unchanged (operate on the derived range), but:
- after **cut**/**delete**, the caret collapses to gap `min(anchor,caret)`.
- **copy** does not move the caret.

**Single block:** the existing per-block drag handle stays (`move/3`). Dragging
a block *outside* the current selection collapses the selection first.

New pure op: `CodeomeBuffer.move_range/3`. Everything else reuses existing ops.

## In-place edit & visible jump targets

**In-place edit of an opcode:**
- **Double-click a block** → the block becomes a small input with autocomplete
  over known opcodes (reusing `to_known_opcode/1`). **Enter** commits via
  `CodeomeBuffer.replace/3` (the function **already exists** at
  `codeome_buffer.ex:38`, currently unwired). **Esc** cancels. Invalid opcode →
  stays in editing, shows error, does not commit.
- No conflict with the palette's dblclick (palette chips vs. listing blocks are
  separate contexts).

**Visible jump targets** for the four template opcodes (`jmp_t`, `jz_t`,
`jnz_t`, `call_t`):

Computed statically, reusing `Lenies.Interpreter.Template`:
1. `extract/3` from `jump_index + 1` over the buffer-as-codeome → the nop run
   (template), capped at `template_max_len` (app env, default 8).
2. `find_complement/4` with `from = jump_index` (matching the interpreter, which
   passes `state.ip`, not `ip+1`) and `radius = template_search_radius` (app
   env, default 256) → target position, or `:not_found`.

Helper: `targets(buffer) :: %{jump_index => {:ok, target} | :not_found}`, in a
new `LeniesWeb.JumpTargets` module (or `Disassembler`). Recomputed on each
buffer change alongside `economics` (cost is bounded by `radius`; buffers ≤
~1000).

Visual rendering, two light levels (no full control-flow editor):
- **Template highlight:** the `nop_0`/`nop_1` run consumed by a jump gets a CSS
  class linking it visually to its jump (shared tint/border), distinguishing
  template-nops from "junk" nops.
- **Target badge + on-demand arc:** each jump shows a small clickable badge
  `-> 042` (places caret / scrolls to the target). When the jump is
  hovered/selected, a thin SVG arc is drawn from jump to target. `:not_found` →
  amber `-> X` badge. Rationale: badge always visible and uncluttered; arc only
  on demand so long codeomes don't become a cobweb.

Because the target depends on `from`, toroidal wraparound, and forward-then-
backward search, it is computed exactly as at runtime — what you see is what the
Lenie will do (at the same `template_max_len` / `template_search_radius`
tuning).

## Caret is server-authoritative

The caret is an **assign** (`caret`/`anchor`), rendered as a DOM element in the
listing — *not* the browser's native caret. So **morphdom redraws it for free**
on every re-render; there is no fragile JS caret state to preserve. JS hooks
only translate clicks/keys/drag into LiveView events; the source of truth is the
server.

## Edge cases

- Empty buffer → `caret = anchor = 0`; listing shows just the caret + a drop
  zone.
- After delete/cut/undo/redo: **clamp** `caret`/`anchor` to `0..len` and
  collapse. History keeps snapshotting **buffer only** (as today); after
  undo/redo the caret collapses to `len` (end of the restored buffer) — a
  single unambiguous default, since the pre-edit caret position isn't stored.
- In-place edit with an invalid opcode → stays in editing, shows error, no
  commit.
- Jump target recomputed on every buffer change with `economics`.

## Architecture & isolation

One unit, one purpose, each testable alone:

- **New pure module `LeniesWeb.EditorCaret`** — all caret/selection math:
  `derive_range/2`, `collapse/1`, `move/3`, `extend/3`, `clamp_after_edit/2`.
  No LiveView → pure unit tests. Keeps `editor_live.ex` thin.
- **`CodeomeBuffer.move_range/3`** — new pure op.
- **Jump-target helper** (`LeniesWeb.JumpTargets` or `Disassembler`) —
  `targets/1`, reusing `Interpreter.Template`.
- **`editor_live.ex`**: replace `selection`/`sel_anchor` handlers with
  `caret`/`anchor`; new events `place_caret`, `move_caret`, `submit_replace`,
  `move_range`, snippet drag; wire `replace/3`.
- **JS**: `editor_keyboard.js` (arrows, Home/End, Alt+↑↓, Esc),
  `codeome_sortable.js` (multi-move + drop-gap=caret), snippet drag. **CSS**:
  caret, clickable gap zones, template highlight, on-hover SVG arc.

## Testing

- **Pure:** `EditorCaret` (navigation, derive, clamp), `CodeomeBuffer.move_range/3`,
  jump-target helper.
- **LiveView:** select / place caret; insertion at caret (palette/text/snippet/
  paste) with and without a selection (replace); `move_range`; duplicate selects
  the copy; in-place replace (valid/invalid).
- **Regression:** snippet inserts at the correct caret gap; undo/redo clamps the
  caret.

## Suggested implementation sequence

Natural milestones:
1. Caret model + server-side render (replaces selection state).
2. Unified insertion at the caret.
3. Range move / duplicate.
4. In-place edit.
5. Visible jump targets.

Phase 5 is the most separable — it can ship as a standalone final phase if
desired.

## Out of scope

- Full control-flow graph editor (arcs everywhere, labeled basic blocks,
  click-to-navigate beyond the target badge).
- Block-level validation feedback (header validation stays as-is).
- Bidirectional textual buffer (possible future direction).
- Touch/mobile-specific redesign (desktop-first; existing `forceFallback` drag
  keeps basic touch working).
