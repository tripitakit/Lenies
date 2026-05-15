# Custom Seeds + Blocks Palette (Phase D) — Design

## Goal

Let the user create a new codeome from a blank canvas via the visual-coding block editor, save it as a named seed with an optional manual color, and spawn it into the world from the existing Spawn dropdown. Saved seeds are persisted to disk so they survive app restarts.

## Background

Phase B added the inspector side panel; Phase C1 turned the disassembly into a block view; Phase C2 added in-place editing (insert / delete / replace / reorder) plus a per-mutation Spawn flow that creates Lenies with the edited codeome but does NOT persist anything. The editor currently only opens for an existing species — there is no way to start from a blank buffer, no way to save the result, and no way to choose a custom color.

The user's original Phase request: "Il Sistema deve consentire creazione e storage di nuovo codeome seed da zero e immissione della nuova specie nel mondo (con selezione colore specifico)". Phase D closes that loop and adds a Scratch-like blocks palette so opcodes can be drag-dropped into the codeome listing (instead of, or in addition to, the existing click-based `+` picker).

## Decisions

1. **Entry point**: a `+ New Seed` button above the existing Seed dropdown in `ControlsPanelComponent`. Clicking it asks `DashboardLive` to open the inspector in a new editor mode (`:new_seed`).

2. **Editor reuse**: the inspector (`SpeciesInspectorComponent`) is the only editor surface — no second component. It accepts a new `editor_mode` assign (`nil` for the existing read+edit-of-species flow, `:new_seed` for blank-canvas mode). When in `:new_seed` mode, header / stats / fetch logic adapts but the buffer + mutation handlers are identical.

3. **Blocks palette**: a new sub-panel inside the inspector, BELOW the codeome listing, visible whenever the inspector is in edit mode (both `:new_seed` and edit of an existing species). The palette is **sized to fit all opcodes without internal scroll** — the codeome listing shrinks to whatever vertical space is left.

4. **Drag-and-drop from palette to listing**: a second `Sortable` instance on the palette with `group: { name: "codeome", pull: "clone", put: false }`. Drop into the codeome listing fires an `edit_insert` event at the drop index. The existing click-based `+` button per-position and `↺` replace flow stay (they cover the cases drag is awkward for — insert at a specific index without dragging, and replace).

5. **Persistence**: a new `Lenies.Seeds.CustomStore` module — an `Agent` cached in-memory, backed by a single JSON file at `priv/user_seeds.json`. JSON because it is human-readable and easy to back up. Opcodes serialize as strings and round-trip via `String.to_existing_atom/1` (safe — the whitelist is preloaded by `Lenies.Codeome.Opcodes`).

6. **Color override**: the save form has an HTML5 `<input type="color">` defaulting to the hash-derived color the seed would get automatically. The user can leave it or change it. Override is stored on the seed record and applied via a new ETS-backed override layer in `Lenies.SpeciesColor` (a `:species_color_overrides` table created in `Lenies.Application`).

7. **Lifecycle**: Create + Spawn + Delete. No edit-in-place. To "edit" a saved seed, the user opens it as the starting buffer for the editor and saves with a new name. This simplifies state management (no "am I editing or cloning?" ambiguity) and keeps the data flow one-way.

## Non-goals (this phase)

- Edit-in-place of a saved custom seed (sostituito da "open-as-buffer + save with new name")
- Color override for *existing* species (built-in or emerged via mutation) — Phase E
- Persistence of color overrides across app restarts (Phase E concern)
- Import / export of seeds (deferred polish)
- Validation beyond what `CodeomeBuffer.validate/1` already provides

## Architecture

### Module structure

```
lib/lenies/seeds/custom_store.ex   (new — Agent + file I/O + JSON)
lib/lenies/species_color.ex        (extend — ETS-backed override layer)
lib/lenies/application.ex          (extend — start CustomStore + create ETS table)

lib/lenies_web/live/dashboard_live.ex             (extend — :editor_mode assign + handler)
lib/lenies_web/live/controls_panel_component.ex   (extend — "+ New Seed" + custom seeds in dropdown + delete)
lib/lenies_web/live/species_inspector_component.ex (extend — new_seed mode + palette + save form)

assets/js/hooks/codeome_sortable.js (extend — second Sortable on palette + onAdd on listing)
assets/css/app.css                  (extend — palette + save form styles)

priv/user_seeds.json                (new — created lazily on first save)
```

### `Lenies.Seeds.CustomStore`

API:
```elixir
@type seed :: %{
        id: String.t(),          # unique, slugified from name
        name: String.t(),
        color_hex: String.t(),   # "#RRGGBB" — always present, never nil
        energy_default: float(),
        opcodes: [atom()]
      }

@spec all() :: [seed()]
@spec get(id :: String.t()) :: nil | seed()
@spec save(seed()) :: :ok | {:error, :invalid_name | :invalid_color | :invalid_opcodes}
@spec delete(id :: String.t()) :: :ok
```

Behaviour:
- `start_link/1` registers as `Lenies.Seeds.CustomStore`, loads `priv/user_seeds.json` from disk, holds the list in `Agent` state.
- `save/1` validates the record, replaces any existing entry with the same `id` (last-write-wins), updates Agent state, atomically writes the full file to disk (write to a tempfile then `File.rename/2`).
- `delete/1` removes the entry, rewrites the file.
- `all/0` and `get/1` read from the Agent — fast, no disk touch.
- On startup, if `priv/user_seeds.json` doesn't exist, the Agent initialises with `[]`. Malformed JSON or invalid records are logged and skipped (we don't crash the app on a corrupt user file).

JSON file format:
```json
[
  {
    "id": "my-replicator-v1",
    "name": "My Replicator V1",
    "color_hex": "#ff8800",
    "energy_default": 10000.0,
    "opcodes": ["nop_1", "nop_1", "get_size", "push0", "store", ...]
  }
]
```

### `Lenies.SpeciesColor` extension

New ETS table `:species_color_overrides` created in `Lenies.Application.start/2`. New functions:

```elixir
@spec set_override(hash :: binary(), hex :: String.t()) :: :ok
@spec clear_override(hash :: binary()) :: :ok
@spec override(hash :: binary()) :: nil | String.t()
```

The existing `hex/1` now checks the override table first:

```elixir
def hex(hash) when is_binary(hash) do
  case override(hash) do
    nil -> hash |> hue_byte() |> byte_to_hex()
    explicit -> explicit
  end
end
```

The `hue_byte/1` function is unchanged — it's still used by the canvas wire-protocol for hash-derived colors. Override is applied client-side via a different rendering path (table swatch, chart polyline) which reads from `SpeciesColor.hex/1`. The canvas (which uses byte codes, not hex) does not respect overrides in Phase D — that's a Phase E concern.

When a Lenie is spawned from a custom seed with a `color_hex` set: `ControlsPanelComponent` first calls `SpeciesColor.set_override(codeome_hash, color_hex)` before invoking `World.spawn_lenie/2`. The override sticks for the session — it survives sterilize but not app restart (Phase E).

### `SpeciesInspectorComponent` — editor_mode :new_seed

New `editor_mode` assign (default `nil`). When `:new_seed`:
- Header: shows "New Seed" instead of hash, with a placeholder swatch (gray).
- Stats grid: omitted (population / generation are not meaningful for an unsaved seed).
- `selected_hash` is `nil`; the component renders normally because the only places that read `@selected_hash` are the header label (replaced) and the spawn flow (which doesn't run in `:new_seed` mode since the buffer is fresh).
- Edit mode is auto-engaged on mount (no Edit button needed).
- Cancel button exits new_seed mode and closes the inspector (no buffer to discard if not dirty; confirm prompt otherwise).
- New **Save** button in the toolbar — opens a small save-form (name + color picker + energy default) similar to the spawn-form pattern.
- The Spawn button stays — the user can spawn directly without saving, same as in C2.

### `SpeciesInspectorComponent` — Blocks palette

Rendered inside the inspector, below the codeome listing scroll container, only when `@edit_mode == true`. The codeome listing's `overflow-auto` container has `flex-1` so it shrinks when the palette claims space.

Markup (simplified):
```heex
<div class="codeome-palette" id="palette-grid" phx-hook="CodeomePalette">
  <%= for {category, ops} <- grouped_opcodes() do %>
    <div class="palette-category">
      <div class="palette-category-label">{category}</div>
      <div class="palette-category-chips">
        <%= for op <- ops do %>
          <div
            class={"palette-chip op op-" <> Atom.to_string(Disassembler.opcode_class(op))}
            data-opcode={Atom.to_string(op)}
          >
            {Atom.to_string(op) |> String.upcase()}
          </div>
        <% end %>
      </div>
    </div>
  <% end %>
</div>
```

Reuses the existing `grouped_opcodes/0` helper added in C2 Task 3.

The palette is sized via CSS to display ALL opcodes without internal scroll. With ~30 opcodes across 10 categories, two-column chip grid per category, each chip ~14×60px → total height ~240px. Locked via `flex-shrink: 0`.

### `CodeomeSortable` JS hook — extended for cross-list drag

The existing hook on `.codeome-blocks` adds the cross-list `group` config and `onAdd` handler. A second instance is set up on `#palette-grid` via a new hook `CodeomePalette` (separate hook for clean teardown logic, no shared state).

```javascript
// In codeome_sortable.js (existing hook, extended)
this.sortable = Sortable.create(this.el, {
  animation: 120,
  handle: ".codeome-drag-handle",
  ghostClass: "codeome-block-ghost",
  draggable: ".codeome-block-editable",
  group: { name: "codeome", pull: true, put: true },
  onEnd: (evt) => {
    // Existing reorder logic — only fires for intra-list drag
    if (evt.from === evt.to && evt.oldDraggableIndex !== evt.newDraggableIndex) {
      this.pushEventTo(this.el, "edit_reorder", {
        from: evt.oldDraggableIndex,
        to: evt.newDraggableIndex,
      });
    }
  },
  onAdd: (evt) => {
    // Block dropped from palette — extract opcode and request insert
    const opcode = evt.item.dataset.opcode;
    if (opcode) {
      this.pushEventTo(this.el, "edit_insert", {
        index: evt.newDraggableIndex,
        opcode: opcode,
      });
    }
    // Remove the cloned chip — server re-renders with the real block tile
    evt.item.remove();
  },
});
```

```javascript
// New file assets/js/hooks/codeome_palette.js
import Sortable from "../../vendor/sortable.js";

const CodeomePalette = {
  mounted() {
    this.sortable = Sortable.create(this.el, {
      group: { name: "codeome", pull: "clone", put: false },
      draggable: ".palette-chip",
      sort: false,
      animation: 120,
    });
  },

  destroyed() {
    if (this.sortable) this.sortable.destroy();
  },
};

export default CodeomePalette;
```

Both hooks registered in `assets/js/app.js`.

### `DashboardLive` — `:editor_mode` assign

New socket assign `editor_mode` (default `nil`). Two new `handle_info` clauses:

```elixir
def handle_info(:open_codeome_editor, socket) do
  {:noreply, assign(socket, :editor_mode, :new_seed)}
end

def handle_info({:editor_mode, mode}, socket) when mode in [nil, :new_seed] do
  {:noreply, assign(socket, :editor_mode, mode)}
end
```

The component closes new_seed mode by sending `{:editor_mode, nil}` after a successful save or cancel.

The render adapts: when `@editor_mode == :new_seed`, the inspector renders **even when `@selected_hash` is nil**:

```heex
<%= if @selected_hash || @editor_mode == :new_seed do %>
  <.live_component
    module={LeniesWeb.SpeciesInspectorComponent}
    id="species-inspector"
    selected_hash={@selected_hash}
    species_record={@selected_species_record}
    editor_mode={@editor_mode}
  />
<% end %>
```

The `cancel_edit` handler (or new `close_new_seed`) resets `editor_mode` to `nil` via a `send(self(), {:editor_mode, nil})` from the component.

### `ControlsPanelComponent` — entry point + custom-seed integration

Above the existing seed-spawn form, a new "+ New Seed" button:

```heex
<button
  type="button"
  phx-click="open_codeome_editor"
  class="text-xs px-2 py-1 border border-cyan-500/40 hover:bg-cyan-500/10"
>
  + New Seed
</button>
```

Handler:
```elixir
def handle_event("open_codeome_editor", _params, socket) do
  send(self(), :open_codeome_editor)
  {:noreply, socket}
end
```

The Seed dropdown's `for` iteration combines built-ins and custom seeds:

```heex
<select name="seed_id">
  <%= for s <- Lenies.Seeds.all() do %>
    <option value={Atom.to_string(s.id)}>{s.name}</option>
  <% end %>
  <%= for s <- Lenies.Seeds.CustomStore.all() do %>
    <option value={"custom:#{s.id}"}>★ {s.name}</option>
  <% end %>
</select>
```

The `custom:` prefix distinguishes ids. The spawn handler branches on the prefix:

```elixir
def handle_event("spawn_seed", %{"seed_id" => "custom:" <> id, "count" => count_str}, socket) do
  case Lenies.Seeds.CustomStore.get(id) do
    %{} = seed ->
      codeome = Lenies.Codeome.from_list(seed.opcodes)
      hash = Lenies.Codeome.hash(codeome)
      Lenies.SpeciesColor.set_override(hash, seed.color_hex)

      count = String.to_integer(count_str) |> max(1) |> min(50)
      dirs = [:n, :s, :e, :w]
      for _ <- 1..count do
        Lenies.World.spawn_lenie(codeome, energy: seed.energy_default, dir: Enum.random(dirs))
      end

    nil ->
      :ok
  end

  {:noreply, socket}
end
```

Delete UI: a small `⨯` icon next to each custom seed's `<option>` is not possible in plain HTML `<select>`. So delete lives in a small drawer below the dropdown — a collapsed list of custom seeds with delete buttons, toggled by a "Manage" link next to the New Seed button. Trade-off: one more click for delete, no UI clutter when not needed.

```heex
<%= if @show_custom_manage do %>
  <div class="text-[10px] border border-cyan-500/20 p-2 mt-1">
    <%= for s <- Lenies.Seeds.CustomStore.all() do %>
      <div class="flex items-center gap-2">
        <span class="inline-block w-2 h-2" style={"background:#{s.color_hex}"}></span>
        <span class="flex-1 truncate">{s.name}</span>
        <button
          type="button"
          phx-click="delete_custom_seed"
          phx-value-id={s.id}
          phx-target={@myself}
          class="px-1 hover:text-rose-300"
          title="Delete"
        >⨯</button>
      </div>
    <% end %>
  </div>
<% end %>
```

### Save form in the inspector

When the user clicks **Save** in `:new_seed` mode, a small inline form (similar to the spawn form pattern) opens:

```heex
<form phx-submit="submit_save_seed" phx-target={@myself} class="...">
  <input type="text" name="name" placeholder="seed name" required />
  <input type="color" name="color_hex" value={@suggested_color} />
  <input type="number" name="energy_default" value="10000" min="1" max="1000000" />
  <button type="submit">Save</button>
  <button type="button" phx-click="cancel_save_form" phx-target={@myself}>Cancel</button>
</form>
```

`@suggested_color` is the hash-derived color of the current buffer (computed via `Lenies.Codeome.hash(Codeome.from_list(@buffer))` → `SpeciesColor.hex/1`).

Handler:
```elixir
def handle_event(
      "submit_save_seed",
      %{"name" => name, "color_hex" => color, "energy_default" => energy_str},
      socket
    ) do
  case socket.assigns.validation do
    {:ok, _} ->
      seed = %{
        id: slug(name),
        name: name,
        color_hex: color,
        energy_default: parse_clamped(energy_str, 1, 1_000_000, 10_000) * 1.0,
        opcodes: socket.assigns.buffer
      }

      case Lenies.Seeds.CustomStore.save(seed) do
        :ok ->
          send(self(), {:editor_mode, nil})
          {:noreply, assign(socket, :show_save_form, false)}

        {:error, _reason} ->
          {:noreply, socket}
      end

    {:error, _} ->
      {:noreply, socket}
  end
end
```

`slug(name)` lowercases, replaces non-alphanum runs with `-`, strips leading/trailing `-`. Collisions silently overwrite (last-write-wins is the documented behaviour).

## Data flow

```
User clicks "+ New Seed"
  ↓
ControlsPanelComponent dispatches send(self(), :open_codeome_editor) to parent
  ↓
DashboardLive.handle_info(:open_codeome_editor, socket) → assigns :editor_mode = :new_seed
  ↓
Inspector renders with editor_mode=:new_seed, edit_mode auto-on, empty buffer, palette visible
  ↓
User drags blocks from palette OR uses + insert OR uses CodeomeBuffer mutations
  ↓
Validation runs after every mutation (existing C2 plumbing)
  ↓
User clicks Save (toolbar)
  ↓
Save form opens with suggested color + name field + energy default
  ↓
User submits → CustomStore.save/1 → JSON file rewritten atomically
  ↓
send(self(), {:editor_mode, nil}) → DashboardLive resets editor_mode → inspector closes
  ↓
Seed appears in ControlsPanelComponent dropdown with ★ prefix
```

Spawn from custom seed:
```
User selects "★ My Replicator V1" from dropdown, count=10, Spawn
  ↓
ControlsPanelComponent.handle_event("spawn_seed", %{seed_id: "custom:my-replicator-v1", count: "10"})
  ↓
CustomStore.get("my-replicator-v1") → %{opcodes, color_hex, energy_default, ...}
  ↓
codeome = Codeome.from_list(opcodes); hash = Codeome.hash(codeome)
  ↓
SpeciesColor.set_override(hash, color_hex) — ETS write
  ↓
Lenies.World.spawn_lenie/2 × 10
  ↓
World spawns the lenies; they appear in the canvas; table swatches use the override color
```

## Error handling

- **`priv/user_seeds.json` missing**: `CustomStore` starts with empty list, file is created on first save.
- **`priv/user_seeds.json` corrupt JSON**: log + start with empty list. The corrupt file is renamed to `.bak` for recovery. The user's seeds are gone but the app doesn't crash.
- **Record with unknown opcode atoms**: `String.to_existing_atom/1` raises. `CustomStore` wraps the per-record decode in a `try` and silently skips invalid records. Logged.
- **Empty / whitespace name on save**: `:invalid_name` error returned; form stays open. Implementation should also disable the Save button when the name input is empty (UX touch).
- **`color_hex` not matching `^#[0-9A-Fa-f]{6}$`**: `:invalid_color` error. HTML5 `<input type="color">` ensures correct format in modern browsers but server-side validation is defensive.
- **Seed delete while a Lenie of that hash is alive**: no problem — the override is independent of the seed record, lifetime is the app session. The Lenie keeps its color until the override is cleared.

## Performance

- `CustomStore.all/0` is in-memory; called on every dropdown render but cheap.
- File I/O on save/delete only. Atomic via tempfile + rename to avoid corruption on crash mid-write.
- ETS override lookup is O(1).
- Palette renders ~30 chips × `op-<class>` color → negligible.
- Drag operations: SortableJS handles list virtualization internally. ~30 palette chips + ~120 codeome blocks are well within smooth-drag territory.

## Testing

- `test/lenies/seeds/custom_store_test.exs` (new):
  - `save/1` then `get/1` round-trips a record.
  - `save/1` overwrites a record with the same id.
  - `delete/1` removes the record.
  - JSON file round-trip: stop and restart the Agent, the data survives.
  - Invalid input is rejected: empty name, bad color, unknown opcode.
- `test/lenies/species_color_test.exs` (extend):
  - `set_override/2` + `hex/1` returns the override.
  - `clear_override/1` removes it.
  - Multiple hashes can have independent overrides.
- `test/lenies_web/live/dashboard_live_test.exs` (extend):
  - Clicking "+ New Seed" opens the inspector with `editor_mode=:new_seed`.
  - The inspector renders without `selected_hash` when `editor_mode=:new_seed`.
- `test/lenies_web/live/species_inspector_component_test.exs` (extend):
  - In `:new_seed` mode the buffer starts empty and edit_mode is on.
  - Save form opens / closes.
  - `submit_save_seed` calls `CustomStore.save/1` and clears editor mode.
  - Palette renders all opcodes grouped by category.
- Manual smoke test for drag-from-palette: documented in the plan, no automated JS test.

## Backwards compatibility

- Snapshot save/restore continues to work — overrides are session-local and not part of the snapshot.
- The Seed dropdown gains custom entries, but the existing `:minimal_replicator | :carnivore | :random` ids stay atomic; the `"custom:"` prefix string is the discriminator.
- No changes to the codeome interpreter, World, or anything in the core simulation.

## Open questions

None at design time. Implementation may surface concerns around:
- Whether the cloned palette chip's DOM removal in `onAdd` races with LiveView's re-render of the codeome listing. Worst case: a brief flicker. Mitigation if needed: defer the `evt.item.remove()` with `requestAnimationFrame`.
- File system write permissions in production deployments — `priv/` is typically writable by the app user but worth confirming in a release context.

## Rollout

Single PR. Tests gate merge. The vendored SortableJS bundle is already in place from Phase C2, no new dependencies. JSON file `priv/user_seeds.json` is created on first save — no migration needed.
