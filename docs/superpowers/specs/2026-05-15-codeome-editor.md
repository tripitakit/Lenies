# Codeome Editor (Phase C2) — Design

## Goal

Add an "Edit" mode to the species inspector that lets the user mutate a working copy of the selected species' codeome — insert opcodes (via inline category picker), delete, replace, reorder via drag-and-drop — and then spawn N copies of the mutated codeome into the world to see how it behaves. The buffer is ephemeral: no persistence (that lives in Phase D); closing the inspector or switching species discards it after confirmation.

## Background

Phase C1 turned the inspector's codeome listing into a block view (one tile per opcode, accent-stripe by category). C2 builds on that surface: the same blocks become editable when the user enters edit mode, and a new toolbar handles the spawn output. No new world-side machinery — spawning re-uses `Lenies.World.spawn_lenie/2`.

The user already wanted "creazione e storage di nuovo codeome seed da zero e immissione della nuova specie nel mondo (con selezione colore specifico)". C2 covers the *editing* side and the *immissione* side, but **not** persistence or color picking — those need their own data model and UI surface and are explicitly Phase D.

## Decisions

1. **Buffer in the component**. `LeniesWeb.SpeciesInspectorComponent` gains `:edit_mode`, `:buffer`, `:dirty` socket assigns. The buffer is a plain `[atom]` list of opcodes. No GenServer, no ETS table.

2. **Pure operations module**. All buffer mutations (`insert/3`, `delete/2`, `replace/3`, `move/3`, `validate/1`) live in a new `LeniesWeb.CodeomeBuffer` module with no side effects. The component delegates; tests target the pure module.

3. **Inline category picker for insertion**. Between adjacent blocks an `+` affordance appears on hover. Clicking opens a dropdown grouped by opcode category (template, stack, arithmetic, control, sense, action, predation, self-inspect, replication, memory). Click an opcode → inserted at that position.

4. **Drag-and-drop via SortableJS**. Vendored to `assets/vendor/sortable.js`. New `assets/js/hooks/codeome_sortable.js` instantiates `Sortable` on the blocks container while edit mode is active; teardown on exit. `onEnd` pushes `edit_reorder` to the component with the `from` and `to` indices.

5. **Live validation**. After every mutation, validate against `Lenies.Config.codeome_length_bounds/0` (5..500) and `min_viable_codeome_opcodes` (10 non-nops). Status renders under the toolbar; spawn button disabled when invalid.

6. **Spawn flow re-uses existing infra**. A small form (count + energy) calls `Lenies.World.spawn_lenie(Lenies.Codeome.from_list(@buffer), energy: e, dir: random)` once per copy. Same defaults as the seed spawn flow: energy 10_000, count 1..50, random direction, random free cell.

7. **Confirm on discard**. Switching species, cancelling edit mode, or closing the inspector while `:dirty` triggers a native `window.confirm("Discard changes?")` from a JS hook. The user can stay or proceed.

## Non-goals (this phase)

- Persistence of edited codeomes as named seeds — Phase D
- Manual color picker for the spawned species — Phase D
- "Create from scratch" with no starting codeome — Phase D (only meaningful when there's a place to save the result)
- Multiple concurrent draft buffers (one per species hash) — out of scope, single buffer only
- Anchor detection / compound block rendering of jump+template — future polish
- Undo / redo — out of scope
- Copy-paste between species — out of scope

## Architecture

### New module `LeniesWeb.CodeomeBuffer`

A pure module that owns the buffer transformations and validation. The component delegates here; the module never touches sockets, ETS, or processes.

```elixir
defmodule LeniesWeb.CodeomeBuffer do
  @moduledoc """
  Pure operations on a list-of-opcode-atoms buffer used by the codeome editor.

  Each operation returns a new buffer; nothing in-place. The component owns
  the assign, this module owns the transformations.
  """

  @type buffer :: [atom()]

  @spec from_codeome(Lenies.Codeome.t()) :: buffer()
  def from_codeome(codeome), do: Lenies.Codeome.to_list(codeome)

  @spec to_codeome(buffer()) :: Lenies.Codeome.t()
  def to_codeome(buffer), do: Lenies.Codeome.from_list(buffer)

  @spec insert(buffer(), non_neg_integer(), atom()) :: buffer()
  def insert(buffer, index, opcode) when is_atom(opcode) and index >= 0 do
    index = min(index, length(buffer))
    {before, rest} = Enum.split(buffer, index)
    before ++ [opcode] ++ rest
  end

  @spec delete(buffer(), non_neg_integer()) :: buffer()
  def delete(buffer, index) when index >= 0 do
    case Enum.split(buffer, index) do
      {before, [_removed | rest]} -> before ++ rest
      {_, []} -> buffer
    end
  end

  @spec replace(buffer(), non_neg_integer(), atom()) :: buffer()
  def replace(buffer, index, opcode) when is_atom(opcode) and index >= 0 do
    case Enum.split(buffer, index) do
      {before, [_old | rest]} -> before ++ [opcode] ++ rest
      {_, []} -> buffer
    end
  end

  @spec move(buffer(), non_neg_integer(), non_neg_integer()) :: buffer()
  def move(buffer, from, to) when from >= 0 and to >= 0 do
    cond do
      from == to or from >= length(buffer) ->
        buffer

      true ->
        {item, without} =
          buffer
          |> List.pop_at(from)

        clamped_to = min(to, length(without))
        List.insert_at(without, clamped_to, item)
    end
  end

  @type validation_error ::
          {:too_short, min: pos_integer(), got: non_neg_integer()}
          | {:too_long, max: pos_integer(), got: non_neg_integer()}
          | {:insufficient_non_nops, min: pos_integer(), got: non_neg_integer()}

  @spec validate(buffer()) ::
          {:ok, %{len: non_neg_integer(), non_nops: non_neg_integer()}}
          | {:error, [validation_error()]}
  def validate(buffer) do
    {min_len, max_len} = Lenies.Config.codeome_length_bounds()
    min_non_nops = Application.get_env(:lenies, :min_viable_codeome_opcodes, 10)
    len = length(buffer)
    non_nops = Enum.count(buffer, &(&1 not in [:nop_0, :nop_1]))

    errs =
      [
        len < min_len && {:too_short, min: min_len, got: len},
        len > max_len && {:too_long, max: max_len, got: len},
        non_nops < min_non_nops &&
          {:insufficient_non_nops, min: min_non_nops, got: non_nops}
      ]
      |> Enum.filter(& &1)

    if errs == [], do: {:ok, %{len: len, non_nops: non_nops}}, else: {:error, errs}
  end
end
```

### Component additions to `LeniesWeb.SpeciesInspectorComponent`

New assigns:
- `:edit_mode` — boolean, default `false`.
- `:buffer` — `[atom]`, default `[]`.
- `:dirty` — boolean, default `false`.
- `:show_spawn_form` — boolean, default `false`.
- `:validation` — `{:ok, info_map}` or `{:error, [errors]}`, default `{:ok, %{len: 0, non_nops: 0}}`.

New event handlers (`handle_event/3`):
- `"enter_edit"` — initialize `:buffer` from the cached codeome lines (or from a fresh fetch when codeome_lines is empty), set `:edit_mode: true`, `:dirty: false`, recompute `:validation`.
- `"cancel_edit"` — if `:dirty`, the user's confirm runs on the client side first (see the JS hook). Server-side handler just resets `:edit_mode: false`, clears `:buffer`, `:dirty`, `:show_spawn_form`.
- `"edit_insert"` with `%{"index" => i, "opcode" => op}` — `CodeomeBuffer.insert/3`, recompute `:dirty` and `:validation`.
- `"edit_delete"` with `%{"index" => i}` — `CodeomeBuffer.delete/2`, recompute.
- `"edit_replace"` with `%{"index" => i, "opcode" => op}` — `CodeomeBuffer.replace/3`, recompute.
- `"edit_reorder"` with `%{"from" => f, "to" => t}` — `CodeomeBuffer.move/3`, recompute. Pushed by the SortableJS hook on drop.
- `"open_spawn_form"` — `:show_spawn_form: true`.
- `"cancel_spawn_form"` — `:show_spawn_form: false`.
- `"submit_spawn"` with `%{"count" => c, "energy" => e}` — validate inputs, call `Lenies.World.spawn_lenie/2` N times with the buffer-built codeome and a random direction per spawn.

A `:dirty` flag becomes `true` whenever the buffer diverges from `Lenies.Codeome.to_list(original)`. Tracking is by identity: compare lists after every mutation.

### JS hooks

Two new bits of client-side glue:

```javascript
// assets/js/hooks/codeome_sortable.js
import Sortable from "../../vendor/sortable.js";

const CodeomeSortable = {
  mounted() {
    this.sortable = new Sortable(this.el, {
      animation: 120,
      handle: ".drag-handle",
      ghostClass: "codeome-block-ghost",
      onEnd: ({ oldIndex, newIndex }) => {
        if (oldIndex !== newIndex) {
          this.pushEventTo(this.el, "edit_reorder", {
            from: oldIndex,
            to: newIndex,
          });
        }
      },
    });
  },

  destroyed() {
    if (this.sortable) this.sortable.destroy();
  },
};

export default CodeomeSortable;
```

```javascript
// assets/js/hooks/confirm_action.js
// Wraps a button/link so phx-click only fires after window.confirm()
// when the data-confirm-when-dirty attribute is set on a "dirty" element.
const ConfirmAction = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      const message = this.el.dataset.confirm;
      if (message && !window.confirm(message)) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    });
  },
};

export default ConfirmAction;
```

The Cancel button, the `×` (close inspector), and the species table rows (when there's a dirty buffer) wire up `phx-hook="ConfirmAction" data-confirm={dirty? "Scarta le modifiche al codeome?" : nil}` so the discard prompt fires only when the buffer is dirty.

`assets/js/app.js` adds the two hooks to the `Hooks` map.

### Vendored SortableJS

Place the minified UMD bundle at `assets/vendor/sortable.js` and import it relatively from the hook. The other vendor scripts (`topbar.js`, `heroicons.js`) follow the same pattern, so this fits.

### Template layout in edit mode

The existing read-mode markup (C1 block tiles) is preserved verbatim when `@edit_mode` is `false`. In edit mode:

```
┌ inspector header (unchanged) ─────────────────────┐
│ ▦ hash…  ↗  ×                                     │
├───────────────────────────────────────────────────┤
│ [Edit / Cancel]  [Spawn ▾]                        │
│ ─ stats ──────────────────────────────────────────│
│ pop 12  gen 2.25  ops 121  ●dirty                 │
│ ─ validity ───────────────────────────────────────│
│ ✓ valid (121 ops, 89 non-nop)                     │
├───────────────────────────────────────────────────┤
│  ≡  ⨯  ↺   000  NOP_1                             │
│  ≡  ⨯  ↺   001  NOP_1                             │
│                  + insert ▾                       │  ← hover-only
│  ≡  ⨯  ↺   002  NOP_1                             │
│  …                                                │
├───────────────────────────────────────────────────┤
│ (when spawn form is open)                         │
│ Count [10] Energy [10000]  [Cancel] [Spawn]       │
└───────────────────────────────────────────────────┘
```

Drag handle = `≡`. Delete = `⨯`. Replace = `↺` (opens the same category picker as insert, but with `edit_replace` instead of `edit_insert`).

The picker dropdown sits inside the same panel — absolutely positioned over the blocks list — to avoid stealing layout space.

### Picker dropdown structure

Grouped by category, one section per group. Within each group, two columns of opcode chips. Click → fires `edit_insert` or `edit_replace`, closes the dropdown.

Categories and their opcodes are derived from `LeniesWeb.Disassembler.opcode_class/1` — list them by iterating the existing whitelist `Lenies.Codeome.Opcodes.all/0` and grouping by class.

The picker is rendered as part of the component, with its own `:picker_open` socket assign (`nil` or `%{index: i, mode: :insert | :replace}`). A click outside closes it. Click on a non-picker block closes the picker first.

## Data flow

```
User clicks [Edit]
  → handle_event("enter_edit") on component
  → :buffer initialized from current codeome opcodes
  → :edit_mode true
  → CodeomeSortable hook activates on the blocks container

User drags block from index 5 to index 12
  → Sortable fires onEnd
  → pushEventTo(this.el, "edit_reorder", {from: 5, to: 12})
  → handle_event("edit_reorder", ...)
  → CodeomeBuffer.move/3
  → recompute validation + dirty
  → re-render

User clicks + between blocks 7 and 8
  → component opens picker @ {index: 8, mode: :insert}
  → user clicks "push1"
  → handle_event("edit_insert", %{"index" => 8, "opcode" => "push1"})
  → CodeomeBuffer.insert/3
  → recompute, close picker

User clicks [Spawn]
  → :show_spawn_form true
User enters count=10, clicks [Spawn]
  → handle_event("submit_spawn", %{"count" => "10", "energy" => "10000"})
  → Codeome.from_list(buffer)
  → for _ <- 1..count, do: World.spawn_lenie(codeome, energy: e, dir: random)
  → :show_spawn_form false (but :edit_mode stays true, buffer survives)

User clicks another species while dirty
  → ConfirmAction JS hook fires window.confirm
  → If proceeded: select_species event fires (existing handler), the component
    update/2 sees a new selected_hash and resets buffer/edit_mode
  → If cancelled: nothing happens, edit mode stays
```

## Error handling

- **Empty codeome_lines when entering edit**: `enter_edit` falls back to fetching the codeome directly from `Lenies.Species.for_hash/1` and a Lenie process, the same path as Phase B. If fetch returns `:no_sample`, edit mode does not engage and a small notice appears in the toolbar.
- **Buffer mutates to invalid state**: validation runs after each mutation. `:validation: {:error, errors}` disables the Spawn button. Mutations themselves are never blocked — the user is free to traverse intermediate invalid states while editing.
- **Spawn with invalid count or energy**: `submit_spawn` clamps `count` to `1..50` and `energy` to `1..1_000_000` like the existing seed form. Non-integer input rejected silently (caught by `Integer.parse/1`).
- **`Lenies.World` not running** (e.g., test environment without start_link): wrap `spawn_lenie` calls in `try/rescue` and surface `:spawn_error` in the toolbar.
- **Sortable hook fails to load**: blocks still render; drag silently no-ops. Delete and insert remain functional via the action buttons.

## Performance

- The buffer is a flat list of atoms (~120 entries for the current `MinimalReplicator`, max 500 by config). Insert/delete/move are O(n) list operations — fine at this scale.
- `validate/1` is O(n) (one pass). Runs after each mutation, so worst case ~500 atom comparisons per keystroke. Negligible.
- The picker iterates `Opcodes.all/0` once on render (~30 entries grouped). No performance concern.
- SortableJS is well-optimized for short lists; 500 items would still drag smoothly.

## Testing

### `test/lenies_web/codeome_buffer_test.exs` (new)

```elixir
defmodule LeniesWeb.CodeomeBufferTest do
  use ExUnit.Case, async: true

  alias LeniesWeb.CodeomeBuffer

  describe "insert/3" do
    test "inserts at the given index, shifting later items right" do
      assert CodeomeBuffer.insert([:a, :b, :c], 1, :z) == [:a, :z, :b, :c]
    end

    test "inserts at the start with index 0" do
      assert CodeomeBuffer.insert([:a, :b], 0, :z) == [:z, :a, :b]
    end

    test "inserts at the end when index >= length" do
      assert CodeomeBuffer.insert([:a, :b], 99, :z) == [:a, :b, :z]
    end
  end

  describe "delete/2" do
    test "removes the item at the index" do
      assert CodeomeBuffer.delete([:a, :b, :c], 1) == [:a, :c]
    end

    test "is a no-op when index is past the end" do
      assert CodeomeBuffer.delete([:a, :b], 99) == [:a, :b]
    end
  end

  describe "replace/3" do
    test "replaces the item at the index" do
      assert CodeomeBuffer.replace([:a, :b, :c], 1, :z) == [:a, :z, :c]
    end

    test "is a no-op past the end" do
      assert CodeomeBuffer.replace([:a, :b], 99, :z) == [:a, :b]
    end
  end

  describe "move/3" do
    test "moves later" do
      assert CodeomeBuffer.move([:a, :b, :c, :d], 0, 2) == [:b, :c, :a, :d]
    end

    test "moves earlier" do
      assert CodeomeBuffer.move([:a, :b, :c, :d], 3, 1) == [:a, :d, :b, :c]
    end

    test "is a no-op when from == to" do
      assert CodeomeBuffer.move([:a, :b, :c], 1, 1) == [:a, :b, :c]
    end

    test "is a no-op when from is out of range" do
      assert CodeomeBuffer.move([:a, :b], 99, 0) == [:a, :b]
    end

    test "clamps to to length when too large" do
      assert CodeomeBuffer.move([:a, :b, :c], 0, 99) == [:b, :c, :a]
    end
  end

  describe "validate/1" do
    setup do
      Application.put_env(:lenies, :codeome_length_bounds, {5, 500})
      Application.put_env(:lenies, :min_viable_codeome_opcodes, 10)
      :ok
    end

    test "ok when length and non_nops both satisfied" do
      buffer = List.duplicate(:nop_0, 5) ++ List.duplicate(:push0, 10)
      assert {:ok, %{len: 15, non_nops: 10}} = CodeomeBuffer.validate(buffer)
    end

    test "errors when too short" do
      assert {:error, errs} = CodeomeBuffer.validate([:push0, :push0])
      assert {:too_short, min: 5, got: 2} in errs
    end

    test "errors when insufficient non-nops" do
      buffer = List.duplicate(:nop_0, 20)
      assert {:error, errs} = CodeomeBuffer.validate(buffer)
      assert {:insufficient_non_nops, min: 10, got: 0} in errs
    end

    test "errors when too long" do
      buffer = List.duplicate(:push0, 501)
      assert {:error, errs} = CodeomeBuffer.validate(buffer)
      assert {:too_long, max: 500, got: 501} in errs
    end
  end

  describe "from_codeome / to_codeome roundtrip" do
    test "round-trips" do
      original = Lenies.Codeome.from_list([:push0, :push1, :store])
      buffer = CodeomeBuffer.from_codeome(original)
      back = CodeomeBuffer.to_codeome(buffer)
      assert Lenies.Codeome.to_list(back) == Lenies.Codeome.to_list(original)
    end
  end
end
```

### Component test additions (`test/lenies_web/live/species_inspector_component_test.exs`)

Existing tests stay. New describe block covers edit mode:

```elixir
  describe "edit mode" do
    test "enter_edit populates the buffer from cached codeome lines"
    test "edit_insert mutates the buffer and marks dirty"
    test "edit_delete mutates the buffer"
    test "edit_replace mutates the buffer"
    test "edit_reorder mutates the buffer"
    test "validation toggles spawn-disabled state"
    test "cancel_edit clears the buffer and resets dirty"
    test "submit_spawn calls World.spawn_lenie/2 N times"
    test "spawn form is closed by default, opens on open_spawn_form"
  end
```

Each test renders the component with the relevant assigns or pushes events via `Phoenix.LiveViewTest.render_component/2` and the `pushEventTo`-equivalent helpers. The spawn-flow test spins up `Lenies.World` in setup (Mox is not a project dep) and asserts that the population grew by N after `submit_spawn`. The existing inspector tests already follow this pattern in the "with a live Lenie" describe block — reuse the same setup.

### Hook smoke tests

JS hooks are not unit-tested. A manual browser smoke check at the end of the implementation:
1. Select a species, click Edit → blocks become editable, drag handles appear.
2. Drag a block — list reorders, no flicker.
3. Click + between blocks → picker opens → click an opcode → block inserts at that position.
4. Click ⨯ on a block → block removed.
5. Click ↺ on a block → picker opens → click an opcode → block replaced.
6. Make buffer invalid (delete enough opcodes) → spawn button disables.
7. Make it valid → spawn button enables.
8. Click Spawn → form opens → enter count, click Spawn → N Lenies appear in the world.
9. Click Cancel while dirty → confirm prompt → confirm → buffer cleared, edit mode off.
10. Switch species while dirty → confirm → switch.

## Backwards compatibility

Component assigns gain new fields with safe defaults. The parent (`DashboardLive`) does not need any change — selection still works the same way. No public API changes.

## Open questions

None at design time. Implementation may surface concerns around:
- Whether `data-id` on each block (needed by SortableJS for stable reorders under LiveView morphdom) needs `phx-update="ignore"` on the parent. The plan task should validate this experimentally.
- Whether the picker dropdown is best implemented as a true `<dialog>`, an absolute-positioned div, or a `<menu>`. Implementer chooses based on browser support.

## Rollout

Single PR. Tests gate merge. The new `assets/vendor/sortable.js` adds ~40KB to the bundle; acceptable.
