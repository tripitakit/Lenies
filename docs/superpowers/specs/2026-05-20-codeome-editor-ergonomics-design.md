# Codeome Editor Ergonomics — Design

**Date:** 2026-05-20
**Status:** Approved (brainstorming) — pending implementation plan
**Scope:** `LeniesWeb.EditorLive` and supporting modules

## Goal

Make codeome authoring faster and less error-prone by adding three
capabilities to the editor: **block selection + clipboard**, a
**persistent snippet library**, and **undo/redo**. All driven server-side,
consistent with the editor's existing server-authoritative buffer model.

## Out of scope (parked)

- "Authoring aids" bundle (one-click template/anchor pairs, palette search,
  inline opcode docs, diff-vs-original). Candidate for a later spec.
- Simulation / game-mechanics ideas (new opcodes, ecological dynamics,
  goals/challenges). Separate brainstorming track.

## Decisions (from brainstorming)

- **Selection model:** range only — click selects one block, shift-click
  extends a contiguous range. No scattered multi-select.
- **Clipboard lifetime:** session-only (cleared on navigation). Durable
  reuse is served by the snippet library.
- **Snippet operations:** minimal — save-from-selection, insert, delete.
  Re-saving the same name overwrites. No separate rename UI.
- **Keyboard:** full shortcuts + an on-screen toolbar with the same commands.
- **Architecture:** server-authoritative. Selection, clipboard, and the
  undo/redo history live in `EditorLive` assigns; mutation logic lives in
  pure, ExUnit-testable modules; a thin JS hook translates keyboard/clicks
  into LiveView events.

## Architecture

### New `EditorLive` assigns

| assign | type | meaning |
|---|---|---|
| `:selection` | `{lo, hi}` \| `nil` | inclusive selected range |
| `:sel_anchor` | non-neg integer \| `nil` | anchor index for shift-extend |
| `:clipboard` | `[atom]` | copied/cut opcode fragment (`[]` = empty) |
| `:history` | `%EditorHistory{}` | undo/redo stacks |
| `:snippets` | `[%{id, name, opcodes}]` | snippet library, loaded from disk |
| `:show_snippet_form` | boolean | inline "save as snippet" form visibility |

Click (no shift): `sel_anchor = idx`, `selection = {idx, idx}`.
Shift-click: `selection = {min(anchor, idx), max(anchor, idx)}`, anchor
unchanged.

### New / extended modules (pure logic)

- **`LeniesWeb.CodeomeBuffer`** (extend) — add pure buffer ops:
  - `slice(buffer, {lo, hi})` → `[atom]` (copy a range)
  - `delete_range(buffer, {lo, hi})` → `buffer`
  - `insert_many(buffer, index, [atom])` → `buffer` (paste a list at index)
- **`LeniesWeb.EditorHistory`** (new) — undo/redo mechanics, decoupled from
  the LiveView:
  - struct `%EditorHistory{past: [buffer], future: [buffer], max: pos_integer}`
  - `record(hist, prev_buffer)` → pushes onto `past` (bounded by `max`,
    oldest discarded), clears `future`
  - `undo(hist, current)` → `{prev_buffer, hist'}` \| `:none`
  - `redo(hist, current)` → `{next_buffer, hist'}` \| `:none`
- **`Lenies.Snippets`** + **`Lenies.Snippets.Store`** (new) — snippet API and
  persistence, mirroring `Lenies.Seeds.CustomStore`:
  - Backed by JSON at `priv/user_snippets.json`, overridable for tests via a
    `:__test_user_snippets_file__` app env key (same pattern as
    `:__test_user_seeds_file__`).
  - State held in a process (same shape as `CustomStore`), loaded at app
    start; `load_from_disk` calls `Code.ensure_loaded!(Lenies.Codeome.Opcodes)`
    before decoding opcode atoms (the fix already applied to CustomStore).
  - Snippet = `%{id: String.t(), name: String.t(), opcodes: [atom]}`;
    `id` = `slug(name)` using the same slug rule as the editor. `slug/1` is
    currently private in `EditorLive`; extract it to a shared helper (e.g.
    `Lenies.Slug` or a function on the snippets module) so both call sites
    use one implementation.
  - API: `all/0`, `save/1` (upsert by id — same name overwrites),
    `delete/1`, `get/1`. Missing/corrupt file → empty list, no crash.

### Central commit point

Introduce `commit_buffer_change(socket, new_buffer)` in `EditorLive`. Before
applying the change it calls `EditorHistory.record(history, old_buffer)` and
clears the redo future, then performs the existing assign updates (buffer,
dirty, validation, economics). All existing mutating events
(`edit_delete`, `edit_reorder`, `edit_insert`, text-append) route through it,
so they become undoable without rewriting their logic.

## Interactions

### LiveView events (all server-side)

| event | payload | behavior |
|---|---|---|
| `select_block` | `{index, shift}` | no shift: single-select + set anchor; shift: extend range from anchor |
| `clear_selection` | — | `selection = nil` (Esc / click empty listing area) |
| `copy_selection` | — | `clipboard = slice(buffer, selection)` |
| `cut_selection` | — | copy, then `delete_range`; selection → `nil` |
| `paste_clipboard` | — | `insert_many` after selection (or at end); select pasted range |
| `duplicate_selection` | — | copy + immediate insert after selection; select the duplicate |
| `delete_selection` | — | `delete_range`; selection → `nil` |
| `undo` / `redo` | — | via `EditorHistory`; selection → `nil` |

**Selection-after-mutation rule:**
- paste / duplicate → select the newly inserted range.
- cut / delete-selection → `nil`.
- undo / redo, drag-reorder, palette insert/delete, text-append → `nil`
  (selection is a transient convenience, never a source of truth to resync).

### Paste/insert position rule

Insert *after* the current selection's `hi`; if no selection, append at the
end of the buffer. Snippet insertion uses the same rule.

### JS hook `EditorKeyboard`

Thin hook on the editor root:
- Click / shift-click on `.codeome-block-editable` body (not the `≡` drag
  handle) → `select_block {index, shift}`.
- Global keydown → Ctrl/Cmd+C/X/V; Ctrl/Cmd+Z (undo);
  Ctrl/Cmd+Shift+Z and Ctrl+Y (redo); Delete/Backspace (`delete_selection`);
  Esc (`clear_selection`); Ctrl/Cmd+D (`duplicate_selection`).
- **Input guard:** if the event target is an `<input>`/`<textarea>` or inside
  a form (opcode text box, spawn/save/snippet forms), the hook ignores the
  shortcut and lets native behavior through (so Ctrl+C in a text field copies
  text, not blocks).

### Toolbar

A button row in the listing-pane header: Copy · Cut · Paste · Duplicate ·
Delete · Undo · Redo · **Save as snippet**. Each fires the same event as its
shortcut. Disabled states:
- no selection → Copy/Cut/Duplicate/Delete/Save-as-snippet off
- empty clipboard → Paste off
- empty past/future stacks → Undo/Redo off respectively

### Selection highlight

Blocks whose `idx ∈ [lo, hi]` render with a `.codeome-block-selected` class
(server-rendered).

### Data flow

shortcut / click / button → `handle_event` → pure helper computes new
buffer / selection / clipboard / history → assigns → re-render (highlighted
blocks, enabled/disabled toolbar, updated listing).

## Snippet library UI

- **Create:** "Save as snippet" toolbar button (enabled only with a
  selection) opens an inline name form (styled like the existing spawn/save
  forms). Submit saves `slice(buffer, selection)` under the given name. No
  min-length validation — snippets are fragments.
- **Use:** a new **Snippets** section in the palette pane lists saved
  snippets as rows/chips by name. Click → insert opcodes using the paste
  position rule and select the inserted range. Each row has a `×` to delete
  it from the library. Empty library → discreet hint ("no snippets — select
  blocks and press Save as snippet").
- **Refresh:** after a save, the Snippets section re-reads the store
  (analogous to the custom-seed refresh after `submit_save_seed`).

## Edge cases / error handling

- No selection → copy/cut/duplicate/delete/save-snippet are no-ops (buttons
  disabled, shortcuts ignored).
- Empty clipboard → paste no-op. Empty undo/redo stack → no-op.
- Keyboard inside input/textarea/form → hook does not intercept.
- Paste/insert exceeding the codeome length cap → **allowed**; existing
  validation flags ⚠ "too long" without blocking (consistent with current
  behavior — the editor permits invalid buffers and surfaces warnings).
- Snippet name slug collision → overwrite (minimal model).
- Snippet store missing/corrupt file → empty list, no crash.
- `EditorHistory` beyond `max` depth → discard oldest snapshots.

## Testing

- **Pure ExUnit:**
  - `CodeomeBuffer.slice/2`, `delete_range/2`, `insert_many/3` including
    boundary indices and out-of-range ranges.
  - `EditorHistory` record/undo/redo and depth bound.
  - `Snippets.Store` save/load/delete roundtrip on a temp file (via the test
    env-key override).
- **LiveView (`EditorLive`):** `select_block` click and shift; copy→paste
  changes the buffer and highlight; cut; delete_selection; undo/redo restore
  the buffer; save-snippet then insert; toolbar disabled states (e.g. paste
  off with empty clipboard).
- **JS hook:** not unit-tested (consistent with existing hooks); real
  coverage is on the `handle_event`s it emits, tested server-side.
