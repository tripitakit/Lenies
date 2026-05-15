# Codeome Block View (Phase C1) — Design

## Goal

Replace the text-only codeome listing in the inspector panel with a vertical list of compact "block tiles", one per opcode. Each tile carries the existing per-category color as a left-edge accent stripe, the opcode index, and the opcode name uppercased. Read-only. The data path stays identical to Phase B; only the HTML/CSS rendering changes.

## Background

Phase B introduced the species inspector side panel. Its codeome section currently renders the output of `LeniesWeb.Disassembler.disassemble/2` as a stack of `<div class="flex gap-2">` rows inside a `<div class="text-[10px] leading-tight font-mono">` wrapper. Each row is a 3-char padded index plus the opcode atom name in lowercase, colored via `class={"op op-<category>"}`.

This is functional but visually flat: nothing distinguishes a `nop_1` from a `get_size` other than text color. For a user starting to read a codeome and eventually edit it (Phase C2), a more block-like presentation makes the structure easier to scan. C1 lands the visual change while keeping the read-only contract; C2 will build edit operations on top.

## Decisions

1. **Compact-rows style**: one block per line, ~12-15 visible per panel viewport. Not a grid, not a tall-tile per-opcode card.
2. **Single source of color**: each block's accent stripe (3px left border) inherits from the existing `op-<category>` CSS rule via `border-left-color: currentColor`. No duplicated color tables.
3. **Opcode name uppercased** for visual weight, with `letter-spacing: 0.05em`. This nudges the visual style toward a "label" feel without changing the underlying data.
4. **No grouping logic** in C1: each opcode is a separate block. Anchor detection (4-consecutive-nop runs) and jump+template compound rendering are deferred to a future polish task.
5. **No interactivity in C1**: hover gives a faint background tint; click does nothing. Edit and selection are C2.

## Non-goals (this phase)

- Edit operations (insert / delete / reorder) — Phase C2
- Drag-and-drop — Phase C2
- Anchor / template detection and compound block rendering — future polish
- Tooltip with energy cost or descriptions — future polish
- Click-to-highlight jump target — future polish

## Architecture

No new modules. No new Elixir logic. The change is confined to:

- The codeome listing block inside `LeniesWeb.SpeciesInspectorComponent.render/1`.
- New CSS rules in `assets/css/app.css` under the `.lenies-dashboard` scope.

The component continues to receive `codeome_lines` (list of `%{index: int, opcode: atom, is_current: bool}` records) from its `update/2` callback and iterates them in the template. The shape of each line stays the same.

### Template change

Inside the existing `<div class="flex-1 min-h-0 overflow-auto">` scroll container, the `<div class="text-[10px] leading-tight font-mono">` listing is replaced with:

```heex
<div class="flex-1 min-h-0 overflow-auto">
  <div class="codeome-blocks">
    <%= for line <- @codeome_lines do %>
      <div class={"codeome-block op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
        <span class="codeome-block-idx">
          {String.pad_leading(Integer.to_string(line.index), 3, "0")}
        </span>
        <span class="codeome-block-name">
          {Atom.to_string(line.opcode) |> String.upcase()}
        </span>
      </div>
    <% end %>
  </div>
</div>
```

Two key differences from the current markup:

- The outer wrapper is `<div class="codeome-blocks">` instead of `<div class="text-[10px] leading-tight font-mono">`. The font/size now lives on the per-block class.
- Each opcode row carries `codeome-block` (style hook) plus the existing `op op-<category>` classes (color hook). The category color is reused not only for the text but also as the source for the accent stripe.

### CSS additions

Appended to `assets/css/app.css`, after the existing opcode-category color rules and before the closing `/* This file is for your main application CSS */` comment:

```css
/* ----- Lenies dashboard: codeome block view ----- */
.lenies-dashboard .codeome-blocks {
  display: flex;
  flex-direction: column;
  gap: 1px;
}

.lenies-dashboard .codeome-block {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 1px 6px;
  font-family: ui-monospace, "JetBrains Mono", "Fira Code", monospace;
  font-size: 10px;
  line-height: 1.3;
  border-left: 3px solid currentColor;
  background: rgba(15, 23, 42, 0.4);
  transition: background 80ms ease;
}

.lenies-dashboard .codeome-block:hover {
  background: rgba(34, 211, 238, 0.08);
}

.lenies-dashboard .codeome-block-idx {
  opacity: 0.4;
  width: 24px;
  flex-shrink: 0;
  text-align: right;
  color: #94a3b8;
}

.lenies-dashboard .codeome-block-name {
  font-weight: 600;
  letter-spacing: 0.05em;
}
```

Notes on the CSS:

- `border-left: 3px solid currentColor`. The `op-<category>` rules set `color: <hex>` on each block, so `currentColor` picks it up automatically — both the opcode name text and the accent stripe end up the same hue with no duplication.
- The index span overrides `color` to slate-gray so it does not inherit the category color (which would make pale categories invisible on the dark background).
- `font-size: 10px` matches the existing inspector typography exactly. `line-height: 1.3` and `padding: 1px 6px` keep the row height close to the old listing so the visible count per viewport (~12-15 blocks) stays similar.

## Data flow

Unchanged from Phase B. The component fetches and caches the codeome by hash; `update/2` assigns `codeome_lines`; the template renders one block per line. No new fetches, no new assigns, no new events.

## Error handling

Nothing to change. The previous template handled empty `codeome_lines` correctly (the comprehension produced nothing); the new template does too.

## Testing

The existing 7 component tests in `test/lenies_web/live/species_inspector_component_test.exs` continue to apply, with one adjustment.

The class-based assertions in the "with a live Lenie" test (`html =~ "op-template"` and `html =~ "op-self_inspect"`) still hold: those classes are emitted as part of the new `codeome-block op op-<category>` class string on each block.

The text-based assertions (`html =~ "nop_1"` and `html =~ "get_size"`) break under the new uppercased rendering — `"NOP_1"` does not contain `"nop_1"` as a case-sensitive substring. Update them to case-insensitive regexes: `html =~ ~r/nop_1/i` and `html =~ ~r/get_size/i`. This is rendering-agnostic and survives further visual changes.

Also add one new assertion to lock the new markup contract:

```elixir
test "renders codeome lines as block tiles" do
  ... existing setup ...
  html = render_component(SpeciesInspectorComponent, ... assigns ...)
  assert html =~ ~s(class="codeome-blocks")
  assert html =~ ~s(codeome-block op op-)
end
```

## Backwards compatibility

None to break — the component is internal to the dashboard, the inspector was just shipped in Phase B, and the only external interface is the assigns shape (unchanged).

## Performance

The render produces ~1 `<div>` + 2 `<span>` per opcode. For the largest expected codeome (`codeome_length_bounds` upper bound = 500), that's ~1500 DOM nodes. Phoenix LiveView's diff tracking handles this without trouble; the existing inspector already produced similar quantities under the text-listing form.

## Open questions

None.

## Rollout

Single PR. Tests gate merge. No feature flag.
