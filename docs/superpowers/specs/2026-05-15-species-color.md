# Species Color — Phase A

## Goal

Render every Lenie on the dashboard canvas with a color derived from its `codeome_hash`. The same color must appear (a) on the species table swatch, (b) on the per-species polyline in the telemetry chart, and (c) on the carcass left behind when that species dies. Mapping must be deterministic and stable forever for a given hash, so that a species keeps its identity across ranking changes, restarts, and snapshots.

## Background

Today the canvas treats lenies as a binary occupancy layer (1 byte/cell, value `0` or `1`), composed in JS as a flat blue overlay. Carcasses are a separate 0..50 amount rendered as a red overlay. The species table swatch is colored by *position in the top-10* (`species_color(idx)` helper), which means the swatch color changes as a species moves up or down the ranking — out of sync with everything else.

We want one source of truth (the codeome hash) that drives color everywhere, and a richer canvas that distinguishes species visually.

## Decisions

1. **Color strategy**: deterministic from `codeome_hash` via `:erlang.phash2(hash, 256)`. No server-side state, no storage, no UI for color management in this phase. (Manual override is deferred to a future phase D.)

2. **Palette resolution**: 255 distinct HSL hues plus the reserved value 0 (= no species). Fixed saturation 70%, lightness 55%. Hue degrees = `(hue_byte - 1) / 255 * 360`, where `hue_byte = :erlang.phash2(hash, 255) + 1`. Both the Elixir hex formatter and the JS canvas use this exact formula so colors agree.

3. **Carcasses retain species color**: when a Lenie dies, its species hue is recorded on the cell alongside the carcass amount. The carcass overlay on the canvas tints the cell with the dead species' color. When the carcass decays to 0, the hue is cleared.

4. **Canvas rendering priority**: living Lenies > colored carcass > resource > empty.

## Non-goals (this phase)

- Right-side codeome inspection panel (Phase B)
- Visual block editor (Phase C)
- User-defined seeds with custom color picker (Phase D)
- Manual override of a specific species' color (Phase E)
- Performance optimization of the encoding pipeline beyond what fits the current 5-tick throttle

## Architecture

### New module `Lenies.SpeciesColor`

Single shared module that maps a codeome hash to:
- a **byte** for canvas transport (`1..255`, with `0` reserved for "no species")
- a **hex string** for HTML/SVG use (table swatch, chart polylines)

Both outputs derive from the same formula on the Elixir side so colors match exactly. The JS side uses an equivalent formula on the byte received from the canvas payload.

```elixir
defmodule Lenies.SpeciesColor do
  @saturation 0.70
  @lightness 0.55

  @doc "Hue byte 1..255 for a species hash. 0 is reserved (no species)."
  @spec hue_byte(binary()) :: 1..255
  def hue_byte(hash) when is_binary(hash) do
    :erlang.phash2(hash, 255) + 1
  end

  @doc "CSS hex color (#RRGGBB) for a species hash."
  @spec hex(binary()) :: String.t()
  def hex(hash) when is_binary(hash) do
    hue_byte(hash) |> byte_to_hex()
  end

  @doc "Convert a hue byte 1..255 to a hex color string using the shared S/L."
  @spec byte_to_hex(1..255) :: String.t()
  def byte_to_hex(byte) when byte in 1..255 do
    hue_deg = (byte - 1) / 255 * 360
    hsl_to_hex(hue_deg, @saturation, @lightness)
  end

  # Standard HSL → RGB conversion (see CSS Color Module Level 4 §6.4 or any
  # graphics reference). Returns "#RRGGBB" with each component clamped 0..255.
  defp hsl_to_hex(h, s, l) do
    {r, g, b} = hsl_to_rgb(h, s, l)
    "#" <> byte_hex(r) <> byte_hex(g) <> byte_hex(b)
  end

  defp hsl_to_rgb(h, s, l) do
    c = (1 - abs(2 * l - 1)) * s
    h_prime = h / 60
    x = c * (1 - abs(:math.fmod(h_prime, 2) - 1))
    {r1, g1, b1} =
      cond do
        h_prime < 1 -> {c, x, 0}
        h_prime < 2 -> {x, c, 0}
        h_prime < 3 -> {0, c, x}
        h_prime < 4 -> {0, x, c}
        h_prime < 5 -> {x, 0, c}
        true        -> {c, 0, x}
      end
    m = l - c / 2
    {round((r1 + m) * 255), round((g1 + m) * 255), round((b1 + m) * 255)}
  end

  defp byte_hex(b) do
    b |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()
  end
end
```

### Cell struct change

Add `carcass_hue` field, defaulting to `0`:

```elixir
defstruct lenie_id: nil,
          resource: 0,
          carcass: 0,
          carcass_hue: 0     # NEW: 0 = no species color, 1..255 = species hue byte
```

### World — death and decay

The death message gains a `codeome_hash` field so the World does not need to look it up after the Lenie process has terminated.

In `Lenies.Lenie.terminate/2`:
- Pass the hash directly to `World.lenie_died(id, pos, energy, codeome_hash)`. The hash is `Lenies.Codeome.hash(state.codeome)` and is always available because the Lenie process holds the codeome in state.

In `World.handle_cast({:lenie_died, id, pos, energy, hash}, state)`:
- Compute `hue = SpeciesColor.hue_byte(hash)`.
- When updating the cell to add carcass value, also set `carcass_hue: hue`.

This avoids the race where a Lenie dies before its first snapshot has been written to `:lenies`. The old 4-tuple message variant is removed; no external consumer uses it.

On `apply_carcass_decay/0`:
- The clearing logic lives in `Cell.decay_carcass/2`: when the new carcass amount drops to `0`, also set `carcass_hue: 0`. Otherwise leave the hue alone. Centralizing the rule in the Cell module keeps the World tick code unchanged and the invariant testable in isolation.
- Edge case: if two lenies of *different* species die on the same cell before decay clears it, the latest death wins and overwrites `carcass_hue`. We accept this as a minor visual artifact — the more recent death is the one most likely to be visible.

### GridRenderer — 4 layers

Extend `encode_layers/1` to emit a fourth layer:

```elixir
{lenies_bin, resource_bin, carcass_bin, carcass_hue_bin} = encode_layers({w, h})
```

Where:
- `lenies` (1 byte/cell): now stores the *hue byte* of the species occupying the cell (`0` if empty), not a binary flag.
- `resource`: unchanged (0..100 clamped).
- `carcass`: unchanged (0..50 clamped intensity).
- `carcass_hue` (1 byte/cell, **NEW**): the hue byte stored on the cell when the carcass was deposited. `0` if there is no carcass color (either no carcass, or a legacy carcass from before this change).

Encoding cost: +85 KB base64 per frame for the extra layer (one byte per cell, base64 inflated). At the current 5-tick throttle, ~1.7 KB/s extra. Negligible on localhost.

The `encode_payload/1` map gains a `carcass_hue: base64_string` field.

### JS hook `GridCanvas`

Decode the new layer. For each cell, compose the output pixel in priority order:

```
species_byte = lenies_layer[i]
res          = resource_layer[i]
carc         = carcass_layer[i]
carc_hue     = carcass_hue_layer[i]

if species_byte > 0 and show_lenies:
   color = hsl(byteToDeg(species_byte), 70%, 55%); alpha = 255
elif carc > 0 and show_carcass:
   if carc_hue > 0:
     color = hsl(byteToDeg(carc_hue), 70%, 55%); alpha = carc * 4 (clamped 0..255)
   else:
     color = (255, 60, 60); alpha = carc * 4    # legacy generic red
elif res > 0 and show_resource:
   color = (0, res * 2 clamped, 0); alpha = 192
else:
   color = (0, 0, 0); alpha = 192
```

`byteToDeg(b) = (b - 1) / 255 * 360`. HSL→RGB uses the standard conversion with S=0.70, L=0.55, matching the server-side formula.

The JS hook re-reads `data-show-lenies`, `data-show-resource`, `data-show-carcass` attributes for the toggle behavior, as today.

### Dashboard

Replace the index-based `species_color(idx)` helper with a single call to `Lenies.SpeciesColor.hex(sp.hash)` everywhere:
- table row swatch (`<span style={"background:#{SpeciesColor.hex(sp.hash)}"}>`)
- telemetry chart polyline `stroke={SpeciesColor.hex(sp.hash)}`

The `@species_palette` module attribute and `species_color/1` private function are removed.

## Data flow

```
Lenie process dies (Lenie.terminate/2)
   └─> hash = Codeome.hash(state.codeome)
   └─> World.lenie_died(state.id, state.interp.pos, state.interp.energy, hash)
         └─> World.handle_cast({:lenie_died, id, pos, energy, hash})
               ├─> hue = SpeciesColor.hue_byte(hash)
               ├─> :ets.insert(:cells, {pos, %{cell | lenie_id: nil,
               │                                       carcass: cell.carcass + dead_value,
               │                                       carcass_hue: hue}})
               └─> :ets.delete(:lenies, id)

World tick (every interval)
   └─> apply_carcass_decay()
         └─> for each cell with carcass > 0:
                Cell.decay_carcass(cell, rate)
                   = %{cell | carcass: new_amount,
                              carcass_hue: if new_amount == 0, do: 0, else: cell.carcass_hue}

Dashboard render tick (every Nth tick)
   └─> GridRenderer.encode_payload(grid)
         ├─> hash_by_id = :ets.tab2list(:lenies) |> Map.new(&{elem(&1, 0), elem(&1, 1).codeome_hash})
         └─> for each cell:
                lenies_byte =
                  cond do
                    cell.lenie_id == nil -> 0
                    hash = hash_by_id[cell.lenie_id] -> SpeciesColor.hue_byte(hash)
                    true -> 0   # snapshot not yet written; render as no-species briefly
                  end
                carcass_hue_byte = cell.carcass_hue
                ... pack four binaries ...
         └─> push_event("render_frame", %{lenies, resource, carcass, carcass_hue, w, h})

JS hook GridCanvas
   └─> handleEvent("render_frame", payload):
         decode 4 layers → for each cell compose pixel per priority rules → blit to canvas
```

## Error handling

- **Missing hash on a living lenie**: shouldn't happen (every record in `:lenies` has `codeome_hash`), but if the lookup returns `nil` for some reason, encode `0` (empty cell) rather than crash. Log nothing — this is a rendering layer.
- **Empty cell with non-zero carcass_hue**: tolerated. JS only reads `carcass_hue` when `carcass > 0`, and decay clears the hue when amount reaches zero, so this state shouldn't persist.
- **Cell missing the new `carcass_hue` field** (e.g., after restoring from an old snapshot): treat absent or `0` as no-color, falls back to generic red. Snapshot/restore code does not need a migration — extra default field on the struct handles it.

## Performance

- **Encoding**: `encode_layers/1` now does one extra ETS lookup per occupied cell (`lookup_hash(lenie_id)`). Worst case 65,536 lookups per frame. Mitigate with a single `:ets.tab2list(:lenies) |> Map.new()` before the cell loop, building an `id => hash` map once per frame. This is O(L) where L = live lenie count, which is bounded by the population cap.
- **Bandwidth**: +85 KB base64 per frame for `carcass_hue` layer. At 5-tick throttle (default), <2 KB/s additional. Acceptable.
- **JS render**: same loop, same arithmetic complexity. Adds one branch per pixel for the carcass-hue check.

## Testing

Unit:
- `test/lenies/species_color_test.exs` (new)
  - `hue_byte/1` deterministic across calls with the same hash
  - `hue_byte/1` always returns `1..255`, never `0`
  - `hex/1` deterministic and returns a `#RRGGBB` string of length 7
  - Distinct hashes produce different hue bytes most of the time (sanity check on `phash2` distribution; assert at least 20 distinct hue bytes across 30 random hashes)
- `test/lenies/world/cell_test.exs` (if it exists, otherwise add to world_test.exs)
  - Default `carcass_hue` is `0`
- `test/lenies/world_test.exs` (extend)
  - Killing a Lenie sets the cell's `carcass_hue` to the killed Lenie's species hue byte
  - Decay clears `carcass_hue` when `carcass` reaches `0`; preserves it while `carcass > 0`
- `test/lenies_web/grid_renderer_test.exs` (extend)
  - `encode_layers/1` returns a 4-tuple of binaries, each `w*h` bytes long
  - A cell with `lenie_id` set produces non-zero in the lenies layer at the right index
  - A cell with `carcass > 0` and `carcass_hue > 0` produces non-zero in both layers
  - `encode_payload/1` map includes the `carcass_hue` base64 field

Integration:
- Existing dashboard live tests continue to pass after `species_color/1` removal — the swatch DOM moves from `bg-cyan-400`-style class to inline `style="background:#…"`, so any test asserting on the swatch markup needs updating.

## Backwards compatibility

- Snapshots: `Lenies.Snapshot.save_to_disk/1` uses `:ets.tab2file` on the `:cells` table. Restoring an old snapshot that was saved before this change will read cells without `carcass_hue`. Elixir's struct default handles this: the struct is reconstructed with the field set to its default `0`. No migration step required.
- HTTP API / external consumers: none currently. The PubSub `world:tick` payload is internal to the dashboard.

## Open questions

None. Phase B (inspection panel) will introduce a click handler on table rows; Phase A does not block on it.

## Rollout

Single PR. Tests gate the merge. No feature flag — the rendering change is purely visual and the data-structure addition has a default value.
