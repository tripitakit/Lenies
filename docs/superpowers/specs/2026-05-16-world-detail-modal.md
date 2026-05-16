# World Detail Modal — Design Spec

**Date**: 2026-05-16
**Status**: Approved

## Goal

Add a full-screen modal that lets the user see the simulation world larger
than the dashboard's 512×512 panel allows, with a side panel listing the
currently active species and their populations. Clicking a species in that
list visually highlights its cells on the zoomed canvas.

## User-visible behaviour

- A new button **⛶ World detail** appears in the dashboard's controls
  panel.
- Clicking the button opens a modal overlay covering most of the viewport,
  identical in framing pattern to the codeome editor modal (`position:
  fixed; inset: 1.5rem;` plus a dimmed backdrop via box-shadow).
- The modal has two panes:
  - **Left** — a much larger world canvas. It keeps the 256×256 grid
    square: side length is `min(calc(100vh - 6rem), calc(100vw - 340px -
    6rem))` (CSS), so the canvas grows until it hits either the modal's
    vertical space or the width left over by the right pane.
  - **Right** — a fixed 340 px species list with header "Species — N
    attive", scrollable, one row per active species.
- The world keeps animating live; the species list re-sorts on every
  dashboard tick (same throttle as the existing species table).
- The species list rows show: colour swatch, truncated hash, population,
  average generation. Sort order: population descending.
- Click on a row → that species' Lenies on the canvas remain at full
  brightness, every other cell dims to ~30 % alpha. Click the same row
  again → highlight cleared. Selecting another row swaps the highlight.
- Closing the modal: a `×` button in the modal header (server-side
  `phx-click="close_world_detail"`). The dimmed backdrop is not clickable
  to dismiss (consistent with the codeome editor modal). Escape key
  shortcut is included as a quality-of-life extra.

## Architecture

```
DashboardLive
├── assigns
│   ├── world_detail_open?            : boolean
│   └── world_detail_highlight_hash   : binary | nil
├── handle_event "open_world_detail"  → set open?=true
├── handle_event "close_world_detail" → set open?=false, highlight=nil
├── handle_event "highlight_species_in_world"
│                                    → toggle highlight_hash
└── render
    └── live_component WorldDetailComponent
        (rendered only when world_detail_open? is true)

ControlsPanelComponent
└── + ⛶ World detail button
    → phx-click="open_world_detail" target=parent

WorldDetailComponent  (new file)
├── render
│   └── <aside id="world-detail"
│              class="panel codeome-editor-modal world-detail-modal">
│       ├── header (title + close ×)
│       └── grid 2 cols
│           ├── canvas#world-detail-canvas
│           │   phx-hook="WorldDetailCanvas"
│           │   data-highlight-hue={byte or 0}
│           └── <ul> species list rows

JS hooks (new)
└── WorldDetailCanvas
    – same render_frame pipeline as GridCanvas
    – reads data-highlight-hue
    – if 0  → render normally
    – if >0 → for each pixel: if speciesByte ≠ highlight-hue, multiply
                              alpha by 0.3 (dimmed)
```

The existing `Lenies.SpeciesColor.hue_byte/1` function maps a codeome hash
to a 1–255 byte; the same byte is what `GridRenderer` writes into the
`lenies` plane that the canvas hook decodes. Highlighting by hue byte is
therefore a one-line filter on the existing pipeline. Hash collisions on
the same hue byte mean visually-identical species get highlighted together
— acceptable because they are already drawn with the same colour and the
user cannot distinguish them visually either way.

## Data flow

1. The dashboard's tick loop sends `render_frame` to **every** subscribed
   canvas. Both the dashboard's small canvas and the modal's larger canvas
   receive the same payload; each renders independently. No new
   server-side encoding is needed — the existing `lenies` byte plane
   already carries the hue per cell.
2. The modal canvas reads `data-highlight-hue` from its own DOM element.
   When the user clicks a species row, `DashboardLive` updates
   `@world_detail_highlight_hash`; the component re-renders with the new
   `data-highlight-hue` attribute. The canvas hook's `updated()` reads
   the new value and re-renders the next frame with the dim filter
   applied. (The hook re-reads on every `render_frame` event so the dim
   is applied to every fresh frame, not just on attribute change.)
3. Closing the modal sets both `open?` and `highlight_hash` back to their
   initial values.

## File changes

- **New**: `lib/lenies_web/live/world_detail_component.ex`
- **New**: `assets/js/hooks/world_detail_canvas.js`
- **New**: `test/lenies_web/live/world_detail_component_test.exs`
- **Edit**: `lib/lenies_web/live/dashboard_live.ex` — new assigns,
  handle_events, conditional render of the component.
- **Edit**: `lib/lenies_web/live/controls_panel_component.ex` — new
  button.
- **Edit**: `test/lenies_web/live/dashboard_live_test.exs` — open/close
  flow, highlight toggle.
- **Edit**: `assets/js/app.js` — register `WorldDetailCanvas` in `Hooks`.
- **Edit**: `assets/css/app.css` — `.world-detail-modal`,
  `.world-detail-species-list`, `.world-detail-species-row[.selected]`.

## CSS

- `.world-detail-modal` extends `.codeome-editor-modal` (same fixed
  positioning, backdrop via box-shadow). Body uses CSS grid:
  `grid-template-columns: 1fr 340px; gap: 1rem;`.
- `.world-detail-canvas-pane` centers the canvas with `display: flex;
  justify-content: center; align-items: center;` so the square canvas is
  centered in the available width.
- `.world-detail-species-list` is a scrollable `<ul>` with a sticky
  header.
- `.world-detail-species-row` has a hover state and a `.selected` modifier
  with a 1 px cyan ring (`box-shadow: 0 0 0 1px var(--neon-cyan)`).

## Edge cases & error handling

- **Zero active species**: list shows "No active species". Canvas still
  renders (carcasses and resources visible). Highlight click is a no-op.
- **Selected species goes extinct while modal is open**: the row vanishes
  on the next tick; `@world_detail_highlight_hash` stays set so
  `data-highlight-hue` retains its value, but no cells match, so the
  whole world appears dimmed. Acceptable visual — the user can click any
  other row (or the now-vanished selection state on cleared) to recover.
  We add a server-side guard: when the species list is recomputed, if
  `world_detail_highlight_hash` is no longer in the top-N, clear it.
- **Modal open during page reconnect**: LiveView reconnect restores
  assigns; the modal re-opens with the highlight intact.
- **Hash collision on hue byte**: documented above, acceptable.

## Test plan

- `world_detail_component_test.exs`
  - renders the canvas with the right `data-grid-width`/`data-grid-height`
  - emits `data-highlight-hue="0"` when no species is selected
  - emits the correct hue byte when a species is selected
  - species list rows are sorted by population descending
  - empty species list shows the "No active species" message
- `dashboard_live_test.exs` (additions)
  - clicking `⛶ World detail` renders an element with
    `id="world-detail"`
  - clicking the `×` close button removes that element
  - clicking a species row sets the `data-highlight-hue` on the canvas
  - clicking the same row again clears the highlight
  - clicking a different row swaps the highlight
  - if the highlighted species drops out of the top-N, the highlight is
    cleared automatically on the next render

## Non-goals (YAGNI)

- Multi-species selection / additive highlighting.
- Filter or search box on the species list.
- Per-modal pause/play toggle (the dashboard's existing Pause button
  already covers this).
- Export / screenshot of the zoomed world.
- Mobile-specific layout. Desktop / wide-viewport is the target; small
  screens degrade gracefully because the modal fills the viewport with
  `inset: 1.5rem`.

## Out of scope for this spec

- Any change to the existing dashboard small canvas, the codeome editor,
  the world tick rate, or the species color subsystem.
