# Codeome Editor Page with Manual Pane — Design Spec

**Date**: 2026-05-17
**Status**: Approved

## Goal

Promote the codeome editor from a modal overlay to a dedicated LiveView
page, and add a third pane to its left that renders the Lenies
Programming Manual chapter-by-chapter for in-editor study and quick
reference. The manual pane is visible by default and collapsible.

## Why both at once

The modal layout (`position: fixed; inset: 1.5rem`) is already cramped
at two panes (palette + listing). Adding a third pane inside the modal
would compound the constraint. Promoting the editor to a full viewport
removes the constraint and naturally accommodates the new pane, in a
single coherent refactor instead of two sequential ones.

## User-visible behaviour

- **+ New Seed** in the controls panel and **Edit** in the species
  inspector navigate to a dedicated editor page (`live_navigate`). The
  modal overlay is gone.
- The editor page fills the viewport with a three-column layout:
  - **Left**: manual pane (~380 px wide), with a chapter selector
    (`<select>`) at the top and the rendered HTML of the selected
    chapter below, scrollable. Collapsible via a `◀ Manual` button.
  - **Centre**: opcode palette (~360 px wide), same drag-source as the
    current modal.
  - **Right**: codeome listing (`flex: 1`), same drop-target,
    drag-reorder, and delete affordances as the current modal.
- A header bar at the top contains: a back link (`← Dashboard`), the
  title (`New Seed` or `Species: <hash>`), the action buttons (`Cancel`,
  `Spawn`, `Save` when applicable), the `●dirty` indicator, and the
  validation banner (`✓ valid (N ops, M non-nop)` or `⚠ ...`).
- Default chapter on first open: **Chapter 2 — Opcode Reference**.
  Subsequent visits remember the last viewed chapter (localStorage).
- Default collapse state: **expanded (visible)**. The collapsed state
  persists in localStorage across page loads.
- When collapsed, the manual pane disappears and a thin 24 px ribbon
  remains on the viewport's left edge with a `▶ Manual` button to
  re-expand.

## Architecture

### New routes

- `live "/editor/new", EditorLive, :new` — mounts the editor with an
  empty buffer in `:new_seed` mode.
- `live "/editor/edit/:hash", EditorLive, :edit` — mounts the editor
  with the codeome of the species identified by `:hash` (loaded from a
  representative live Lenie via `Lenies.Species.for_hash/1`).

### New modules

**`Lenies.Manual`** — supervised `Agent` started under
`Lenies.Application`'s supervision tree. At boot it:

1. Reads each `.md` file under `docs/manual/`. Path resolution tries,
   in order: (a) `Application.app_dir(:lenies, "priv/manual")` — the
   release-friendly location; (b) `Path.expand("docs/manual",
   File.cwd!())` — the dev fallback. A `mix.exs` hook copies the manual
   into `priv/manual` at compile time so both paths are populated. The
   Agent simply uses whichever exists.
2. Parses each one with `Earmark.as_html!/2`.
3. Extracts the chapter title from the first `# ` heading in the source.
4. Stores the result as `%{filename => %{title: title, html: html}}` in
   the Agent state.

Public API:

```elixir
@spec list_chapters() :: [%{filename: String.t(), title: String.t()}]
@spec get(String.t()) :: %{title: String.t(), html: String.t()} | nil
```

Errors per file are logged and the failing chapter is skipped (the
editor still works without it). At least one chapter must load
successfully for the manual pane to render — otherwise the pane shows
a "manual unavailable" placeholder and the editor still works.

**`LeniesWeb.EditorLive`** — full-page LiveView. Owns:

- All `enter_edit` / `cancel_edit` / buffer-mutation / save / spawn
  state that currently lives in `SpeciesInspectorComponent`.
- Assigns: `:mode` (`:new_seed | :edit`), `:selected_hash`,
  `:buffer`, `:dirty`, `:validation`, `:show_spawn_form`,
  `:show_save_form`, `:current_chapter` (filename string),
  `:manual_collapsed?`.
- `handle_event("select_chapter", %{"chapter" => filename}, socket)` —
  update `:current_chapter`, push `localStorage.lastChapter`.
- `handle_event("toggle_manual", _, socket)` — flip `:manual_collapsed?`,
  push `localStorage.manualCollapsed`.

**`LeniesWeb.ManualPaneComponent`** — stateful live_component, single
`<aside>` root. Props: `chapter` (filename), `collapsed?` (bool).
Renders the chapter `<select>` and the chapter HTML, or the collapsed
ribbon when `collapsed?` is true. Click on the dropdown fires
`select_chapter` event; click on the collapse button fires
`toggle_manual` event. Both are bubbled to `EditorLive` (no
`phx-target`).

### Refactored modules

**`LeniesWeb.SpeciesInspectorComponent`** — loses all `edit_mode` /
`buffer` / palette / save / spawn machinery. Reduced to a read-only
inspector panel:

- Renders the species header (hash, color swatch, link to species
  page).
- Renders the disassembled codeome as colored opcode blocks.
- Renders stats (population, avg generation, ops count).
- An `Edit` button that does `<.link navigate={~p"/editor/edit/#{@selected_hash}"}>`.
- Drops: `enter_edit`, `cancel_edit`, all edit-buffer handlers, the
  picker (already gone), the spawn/save forms.

**`LeniesWeb.ControlsPanelComponent`** — the `+ New Seed` button
becomes `<.link navigate={~p"/editor/new"}>` instead of bubbling
`:open_codeome_editor` to the dashboard.

**`LeniesWeb.DashboardLive`** — removes `editor_mode`,
`world_detail_open?`'s editor-related branches, and the
`{:editor_mode, _}` / `:open_codeome_editor` info handlers. The
`<.live_component module={LeniesWeb.SpeciesInspectorComponent}...>`
call no longer needs `editor_mode` as a prop.

### JS hooks

Unchanged. `CodeomePalette` and `CodeomeSortable` are attached by their
DOM IDs (`#palette-grid`, `#codeome-blocks-...`). The fact that they
now live in `EditorLive` rather than `SpeciesInspectorComponent` is
transparent to the hooks. **New hook**: `RememberManualState` —
on `mounted()` reads `localStorage.manualCollapsed` and
`localStorage.lastChapter`, dispatches `pushEvent` to set the
corresponding assigns; on receiving the `set-collapsed` / `set-chapter`
events from the server, writes them back to localStorage.

## Layout (CSS)

```css
.codeome-editor-page {
  display: grid;
  grid-template-rows: auto 1fr;
  height: 100vh;
  overflow: hidden;
}

.editor-grid {
  display: grid;
  grid-template-columns: 380px 360px 1fr;
  gap: 1rem;
  padding: 1rem;
  min-height: 0;
}

.editor-grid.manual-collapsed {
  grid-template-columns: 24px 360px 1fr;
}

/* manual pane */
.manual-pane { ... }
.manual-chapter-select { /* full-width select */ }
.manual-content { overflow-y: auto; /* typography rules */ }
.manual-collapse-btn { /* small icon button at the pane's bottom-right */ }

/* when collapsed: the pane becomes a 24 px ribbon with one button */
.manual-ribbon { /* vertical "▶ Manual" button */ }
```

All previous `.codeome-editor-modal*` rules are removed. The
backdrop-via-box-shadow trick goes too.

## Manual content rendering

- Earmark options: defaults are fine. Code fences (` ```elixir `)
  render as `<pre><code class="elixir">...</code></pre>` — styled by
  CSS only, no JS syntax highlighter.
- Internal cross-chapter links (e.g. `[chapter 4](04-loops-and-templates.md)`)
  are intercepted by a JS hook on the manual pane: on click of any
  `<a>` whose `href` ends in `.md`, `event.preventDefault()` and
  `pushEvent("select_chapter", %{chapter: href})`. No Earmark
  customisation needed — the raw HTML keeps its `<a href="04-loops-and-templates.md">`
  anchors and the hook does the routing.
- Internal anchors within a chapter (`[section](#section)`) work
  natively via the browser's default anchor scroll.

## Test plan

### `Lenies.Manual`

- Boots cleanly and loads all 12 chapters.
- Each chapter has a non-empty `title` and a non-empty `html`.
- `list_chapters/0` returns 12 entries in numerical filename order.
- `get(unknown_filename)` returns `nil`.

### `LeniesWeb.EditorLive`

- Mounts on `/editor/new` with `:new_seed` mode, empty buffer.
- Mounts on `/editor/edit/HASH-X` with the buffer pre-loaded from the
  representative Lenie of HASH-X (insert one in ETS as fixture).
- Mounts on `/editor/edit/UNKNOWN-HASH` with an empty buffer and a
  flash or banner indicating the species was not found.
- The editor page contains `id="codeome-editor"` aside, `#palette-grid`
  canvas equivalent, and `id="codeome-blocks-..."`.
- The `Cancel` button on `/editor/edit/...` navigates back to
  `/species/HASH-X`. The `Cancel` button on `/editor/new` navigates
  back to `/`.
- `Save` (in `:new_seed` mode only) persists a custom seed and
  navigates back to `/`.
- `Spawn` calls `Lenies.World.spawn_lenie/2` and navigates back to `/`.
- Selecting a chapter from the dropdown updates `data-current-chapter`
  on the manual pane.
- Toggling `▶ Manual` / `◀ Manual` toggles the `.manual-collapsed`
  class on the grid.

### `LeniesWeb.ManualPaneComponent`

- Renders the `<select>` with 12 options.
- Renders the HTML of the selected chapter.
- When `collapsed?: true`, only the ribbon + `▶ Manual` button render
  (no chapter content, no dropdown).

### Existing tests to update

- `dashboard_live_test.exs`: the `+ New Seed` button now navigates;
  test the navigation target instead of asserting on `id="species-inspector"`.
- `species_inspector_component_test.exs`: drop all edit-mode tests
  (the inspector is read-only now). Keep header / stats / disassembly
  tests.
- `controls_panel_component_test.exs`: `+ New Seed` becomes a link;
  update selector.

## Definition of done

1. `/editor/new` and `/editor/edit/:hash` both mount successfully.
2. The 3-column layout renders at viewport size; manual pane shows
   Chapter 2 (Opcode Reference) by default; chapter dropdown works.
3. Drag-drop from palette to listing works (no regression from the
   current modal).
4. Save, spawn, cancel all work and navigate sensibly.
5. Collapse / expand persists across page reloads (localStorage).
6. `mix test` passes (test count likely changes — net delta should be
   small: dropped edit-mode component tests + added EditorLive tests).
7. `mix compile --warning-as-errors` clean.
8. `mix precommit` clean.
9. No visible regression in the dashboard, species inspector
   (read-only), or world detail modal.

## Non-goals (YAGNI)

- No syntax highlighting in manual code blocks.
- No full-text search inside the manual.
- No deep-linking to a manual chapter via URL query (e.g.
  `/editor/new?chapter=05`).
- No live-reload of the manual when `.md` files change on disk
  (requires app restart).
- No fancy diff / preview against the original codeome in `:edit` mode.
- No keyboard shortcuts beyond what the editor already has.

## Out of scope

- The Lenie inspector page (`/lenie/:id`), the species page
  (`/species/:hash`), the world detail modal — all unchanged.
- The Programming Manual content itself — unchanged. Only its
  rendering location is new.

## File map (new and modified)

- **New** `lib/lenies/manual.ex` (Agent that loads + serves chapters)
- **New** `lib/lenies_web/live/editor_live.ex` (the page)
- **New** `lib/lenies_web/live/manual_pane_component.ex` (live_component)
- **New** `assets/js/hooks/remember_manual_state.js` (localStorage)
- **New** `test/lenies/manual_test.exs`
- **New** `test/lenies_web/live/editor_live_test.exs`
- **New** `test/lenies_web/live/manual_pane_component_test.exs`
- **Modify** `mix.exs` (add `:earmark` dep)
- **Modify** `lib/lenies/application.ex` (start `Lenies.Manual` in supervision tree)
- **Modify** `lib/lenies_web/router.ex` (two new live routes)
- **Modify** `lib/lenies_web/live/species_inspector_component.ex` (strip edit-mode)
- **Modify** `lib/lenies_web/live/controls_panel_component.ex` (link not bubble for `+ New Seed`)
- **Modify** `lib/lenies_web/live/dashboard_live.ex` (drop editor_mode plumbing)
- **Modify** `assets/css/app.css` (drop `.codeome-editor-modal*`; add `.codeome-editor-page` + manual pane + grid)
- **Modify** `assets/js/app.js` (register `RememberManualState` hook)
- **Modify** existing affected tests (dashboard, species inspector, controls panel)
