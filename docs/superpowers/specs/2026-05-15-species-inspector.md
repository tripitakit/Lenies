# Species Inspector — Phase B

## Goal

Add an inline, read-only side panel to the dashboard that shows the disassembled codeome of a species when its row in the species table is clicked. The panel appears as a third column on the right of the top row, takes its color cue from the species color introduced in Phase A, and updates its population/generation stats on the same tick throttle as the species table.

## Background

The existing `LeniesWeb.SpeciesLive` (at `/species/:hash`) already shows a disassembled codeome via `LeniesWeb.Disassembler.disassemble/2`, with population, lineage, and per-Lenie links. It is a separate page reachable from the species-table hash link. Phase B keeps that page intact for users who want the full deep dive, and adds an *inline* equivalent that lives inside `DashboardLive` so the user can read the code of a species while still seeing the world canvas and chart updating live.

The decisions taken during brainstorming:

1. **Layout**: third column on the right of the top row, shown only when a species is selected.
2. **Content**: codeome listing with syntax-highlighted opcode categories, plus the essential stats (hash, population, average generation, total opcode count). No lineage table — that lives on the existing `/species/:hash` page.
3. **Trigger**: row click on the species table toggles selection. Same-row click deselects; different-row click swaps; an `[×]` button on the panel header closes.

## Non-goals (this phase)

- Codeome editing (Phase C)
- Visual block editor (Phase C)
- Custom seeds + color picker (Phase D)
- Manual color override (Phase E)
- Phylogenetic tree or lineage rendering (already deferred on `SpeciesLive`)

## Architecture

### New module `LeniesWeb.SpeciesInspectorComponent`

A stateful LiveComponent that owns:

- `selected_hash` — the species hash to inspect (mirrors the parent's assign of the same name).
- `cached_codeome_hash` — the hash whose codeome is currently in `codeome_lines`. Used to invalidate the cache when the parent switches selection.
- `codeome_lines` — output of `LeniesWeb.Disassembler.disassemble(codeome, nil)`, fetched once when the selected hash changes.
- `fetch_status` — `:ok | :no_sample | :error`. Drives the empty-state message when no live Lenie of that species exists.

The component is rendered conditionally by the parent: if `@selected_hash == nil`, the parent does not render the component at all (the third column collapses).

Population, average generation, and the swatch color are derived from a `species_record` map passed in by the parent (it always knows the current record for the selected hash — see the parent assign below).

### `DashboardLive` changes

Two new socket assigns:

- `selected_hash :: binary() | nil` — current selection, default `nil`.
- `selected_species_record :: map() | nil` — the matching record from `Lenies.Species.aggregate()` (or a synthetic "extinct" record). Computed alongside the throttled top-10 update.

New event handler:

```elixir
def handle_event("select_species", %{"hash" => hash}, socket) do
  new_hash =
    if socket.assigns.selected_hash == hash do
      nil  # toggle off
    else
      hash
    end

  {:noreply,
   socket
   |> assign(:selected_hash, new_hash)
   |> assign(:selected_species_record, find_record(new_hash))}
end
```

Where `find_record(nil)` returns `nil` and `find_record(hash)` returns the matching aggregated record (looking it up via `Lenies.Species.for_hash/1` if the hash isn't already in the top-N — see Data flow below).

Throttled tick handler is extended so that when the species list updates, `selected_species_record` is refreshed too:

```elixir
{species, species_total} = top_species(10)
selected = find_selected_record(socket.assigns.selected_hash, species)
```

### Template changes (`DashboardLive.render/1`)

Top row goes from two flex children (World + Tel/Species) to three:

```heex
<div class="flex gap-3 min-h-0">
  <div class="panel ... shrink-0"> World </div>
  <div class="flex-1 grid grid-rows-2 gap-3 min-h-0 min-w-0"> Tel + Species </div>
  <%= if @selected_hash do %>
    <.live_component
      module={LeniesWeb.SpeciesInspectorComponent}
      id="species-inspector"
      selected_hash={@selected_hash}
      species_record={@selected_species_record}
    />
  <% end %>
</div>
```

The Species panel table rows become clickable. The hash inside the row stops being a navigation link — it is rendered as plain text — and the entire row carries `phx-click="select_species"`. This avoids any propagation ambiguity between the row event and a child link.

```heex
<tr
  class={[
    "hover:bg-cyan-500/10 cursor-pointer",
    @selected_hash == sp.hash && "bg-cyan-500/20 ring-1 ring-cyan-400"
  ]}
  phx-click="select_species"
  phx-value-hash={sp.hash}
>
  <td class="py-0.5 flex items-center gap-1.5">
    <span class="inline-block w-2 h-2 shrink-0" style={"background:#{Lenies.SpeciesColor.hex(sp.hash)}"}></span>
    <span class="text-cyan-400">{String.slice(sp.hash, 0..7)}</span>
  </td>
  ...
</tr>
```

Users who want the full standalone `/species/:hash` page reach it from the inspector panel header via a small `↗` button (see the component render section below).

### Component render

```heex
<aside class="panel w-[320px] shrink-0 flex flex-col gap-2 p-3 min-h-0">
  <header class="flex items-center gap-2">
    <span
      class="inline-block w-3 h-3 shrink-0"
      style={"background:#{Lenies.SpeciesColor.hex(@selected_hash)}"}
    ></span>
    <h2 class="text-xs flex-1 truncate">
      <%= String.slice(@selected_hash, 0..15) %>…
    </h2>
    <.link
      navigate={~p"/species/#{@selected_hash}"}
      class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
      title="Open full species page"
    >↗</.link>
    <button
      phx-click="select_species"
      phx-value-hash={@selected_hash}
      class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
    >×</button>
  </header>

  <div class="grid grid-cols-3 gap-2 text-[11px]">
    <div class="border border-cyan-500/30 px-2 py-1">
      <div class="opacity-60">pop.</div>
      <div class="text-cyan-300 font-bold tabular-nums text-base">
        <%= population(@species_record) %>
      </div>
    </div>
    <div class="border border-violet-500/30 px-2 py-1">
      <div class="opacity-60">gen.</div>
      <div class="text-violet-300 font-bold tabular-nums text-base">
        <%= avg_generation(@species_record) %>
      </div>
    </div>
    <div class="border border-emerald-500/30 px-2 py-1">
      <div class="opacity-60">ops</div>
      <div class="text-emerald-300 font-bold tabular-nums text-base">
        <%= length(@codeome_lines) %>
      </div>
    </div>
  </div>

  <%= if @fetch_status == :no_sample do %>
    <p class="text-[10px] opacity-60">
      Nessun Lenie vivo di questa specie. Codeome non disponibile.
    </p>
  <% end %>

  <div class="flex-1 min-h-0 overflow-auto">
    <pre class="text-[10px] leading-tight font-mono">
      <%= for line <- @codeome_lines do %>
        <div class="flex gap-2">
          <span class="opacity-50 tabular-nums w-8 shrink-0">
            <%= String.pad_leading(Integer.to_string(line.index), 3, " ") %>
          </span>
          <span class={"op-" <> Atom.to_string(LeniesWeb.Disassembler.opcode_class(line.opcode))}>
            <%= Atom.to_string(line.opcode) %>
          </span>
        </div>
      <% end %>
    </pre>
  </div>
</aside>
```

The `op-<class>` CSS rules go in `assets/css/app.css` under the `.lenies-dashboard` scope so they only apply inside the dashboard.

### CSS additions

```css
.lenies-dashboard .op-template     { color: #64748b; }              /* gray  — nops */
.lenies-dashboard .op-stack        { color: #fbbf24; }              /* amber */
.lenies-dashboard .op-arith        { color: #f97316; }              /* orange */
.lenies-dashboard .op-control      { color: #a78bfa; }              /* violet */
.lenies-dashboard .op-sense        { color: #22d3ee; }              /* cyan */
.lenies-dashboard .op-action       { color: #34d399; }              /* emerald */
.lenies-dashboard .op-predation    { color: #f43f5e; }              /* rose */
.lenies-dashboard .op-self_inspect { color: #38bdf8; }              /* sky */
.lenies-dashboard .op-replication  { color: #e879f9; }              /* fuchsia */
.lenies-dashboard .op-memory       { color: #a3e635; }              /* lime */
.lenies-dashboard .op-unknown      { color: #94a3b8; }              /* slate */
```

(Eleven categories, matching the eleven `Disassembler.opcode_class/1` clauses.)

## Data flow

```
User clicks species row
  └─> phx-click="select_species" with phx-value-hash=<hash>
        └─> DashboardLive.handle_event("select_species", %{"hash" => h}, socket)
              ├─> new_hash = (current == h ? nil : h)
              ├─> selected_record = find_selected_record(new_hash, current_top_species)
              │     └─> if hash is in top_species, use that record
              │     └─> else Species.for_hash(hash) and aggregate to {pop, avg_gen}
              │     └─> if no records, return %{hash: h, population: 0, avg_generation: 0.0}
              └─> assign(:selected_hash, new_hash), assign(:selected_species_record, selected_record)

Component update (Phoenix LiveView calls update/2 with new assigns)
  └─> SpeciesInspectorComponent.update(%{selected_hash: h, species_record: r}, socket)
        ├─> if h != socket.assigns.cached_codeome_hash:
        │     ├─> fetch codeome via sample Lenie process (see fetch_codeome/1)
        │     ├─> cache lines + new hash
        │     └─> set fetch_status accordingly
        └─> assign all updated values

Throttled dashboard tick
  └─> updates @species, @species_total
        └─> recompute @selected_species_record (if @selected_hash != nil)
              └─> component.update/2 receives new species_record assign
                    └─> codeome NOT refetched (same hash, cache hit)
                    └─> stats re-rendered

User clicks the same row OR the [×] button
  └─> select_species with the current selected hash
        └─> handle_event toggles selected_hash to nil
        └─> parent stops rendering the component (column collapses)
```

### `fetch_codeome/1` (component helper)

Same approach as `SpeciesLive.fetch_sample_codeome/1`:

```elixir
defp fetch_codeome(hash) do
  case Lenies.Species.for_hash(hash) do
    [] ->
      {:no_sample, []}

    [{sample_id, _} | _] ->
      case Lenies.Registry.whereis(sample_id) do
        pid when is_pid(pid) ->
          try do
            case GenServer.call(pid, :get_codeome, 1_000) do
              {:ok, codeome} -> {:ok, LeniesWeb.Disassembler.disassemble(codeome, nil)}
              _ -> {:error, []}
            end
          catch
            :exit, _ -> {:error, []}
          end

        _ ->
          {:no_sample, []}
      end
  end
end
```

The fetch happens inside `update/2`, which runs in the parent LiveView's process — `GenServer.call` blocking it briefly is acceptable because the codeome is small (≤500 opcodes per `codeome_length_bounds`) and the call only happens when the user selects a new species.

## Error handling

- **Selected species goes extinct mid-inspection**: `selected_species_record` becomes a synthetic record with `population: 0`. The codeome stays cached so the user can still read it. A short notice appears under the stats. The panel does not auto-close.
- **Sample Lenie process dies during the `GenServer.call`**: caught by `catch :exit, _`. Component sets `fetch_status = :error` and shows the same "no sample available" message. Cached codeome (if any) is preserved.
- **Selected hash is invalid or unknown**: `Species.for_hash/1` returns `[]`, component enters the `:no_sample` state with empty codeome lines.
- **`Lenies.Registry` not started in tests**: the component falls back to `:no_sample` gracefully (the `case Lenies.Registry.whereis(id)` does not crash on a missing registry; if it can, wrap in `try/rescue`).

## Performance

- Codeome is fetched **once per selection change**, not every tick. The disassembly + cached lines are reused across throttled updates.
- Population/avg_generation derive from data the dashboard already computes for the species table; the only extra cost is one `Species.for_hash/1` call per tick when the selected species is not in the top-N (rare).
- Rendering 121 opcode lines as `pre` text is negligible. For codeomes near the upper bound (500 opcodes per `codeome_length_bounds`), the panel scrolls; LiveView re-render diff is bounded by Phoenix's per-tag tracking.

## Testing

Unit (component, no live socket required where possible):
- `test/lenies_web/live/species_inspector_component_test.exs`
  - Component renders empty/closed when assigns include `selected_hash: nil` (controlled at parent level — confirm by rendering Dashboard).
  - Component renders hash + stats when given a `species_record`.
  - Component re-fetches codeome when `selected_hash` changes between two `update/2` calls; does *not* re-fetch when only `species_record` changes (same hash).
  - Component shows the "no sample available" message when fetch returns `:no_sample`.

Integration (dashboard live test):
- `test/lenies_web/live/dashboard_live_test.exs` (extend)
  - Clicking a species row sends `select_species` and the panel becomes visible in the rendered HTML (assert on a stable CSS hook, e.g., `id="species-inspector"`).
  - Clicking the same row again hides the panel.
  - Clicking a different row keeps the panel visible but with the new hash visible in the markup.
  - The existing "navigate to /species/:hash" test (if any) must be updated to point at the new `↗` link in the inspector header rather than the table hash text, since the hash in the table is no longer a link.

The existing dashboard tests already start `Lenies.World` and seed lenies; the new tests reuse that setup and seed a couple of distinct codeome hashes via `:ets.insert(:lenies, …)`.

## Backwards compatibility

- The standalone `/species/:hash` page is untouched. The hash link inside table rows still navigates to it.
- No new ETS tables, no new world state, no new PubSub topics.
- Existing snapshots restore unchanged.

## Open questions

None.

## Rollout

Single PR. Tests gate merge. No feature flag.
