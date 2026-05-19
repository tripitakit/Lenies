# Plasmid Conjugation — Horizontal Gene Transfer

**Date**: 2026-05-19
**Status**: design

## Motivation

The Lenies simulation currently evolves only through **vertical** inheritance:
codeomes change via copy errors and background mutations, both confined to
parent → child lineages. Real microbial evolution is dominated by **horizontal
gene transfer** (HGT) — mechanisms that move DNA between cells outside the
parent-child line. Bacterial conjugation, in particular, transfers small
self-replicating DNA elements (plasmids) directly between adjacent cells,
allowing useful gene clusters to spread across lineages and even species
boundaries faster than mutation could ever match.

This spec adds a minimal but expressive analogue: each Lenie may carry an
optional **plasmid** — a short opcode buffer it can transfer to an adjacent
Lenie via the new `:conjugate` opcode. The plasmid integrates as appended
code in the recipient and is itself copied along, enabling viral spread
through a population. Vertical and horizontal evolution become coupled
without changing the existing replication skeleton.

## Goals

- Add a second axis of inheritance (horizontal) without rewriting the VM.
- Allow plasmids to themselves replicate and evolve, so "selfish DNA" /
  "viral plasmid" dynamics can emerge from selection rather than rules.
- Keep the cost model coherent with existing opcodes so that the energy
  balance constrains plasmid-heavy strategies naturally.
- Preserve the existing species table semantics — plasmids change the
  codeome on receipt, so the species hash naturally tracks the change.

## Non-goals

- **Multi-plasmid Lenies**. The state shape (`plasmids: []`) is
  forward-compatible with multiple plasmids per Lenie, but the MVP holds
  at most one. Lifting this is a future extension.
- **Selective integration sites / homologous recombination**. Plasmids
  always append to the end of the recipient's codeome; no sequence
  matching.
- **Conjugation handshake**. The recipient is passive — has no opcode to
  refuse a plasmid. Symmetric two-way handshake is a future extension.
- **Plasmid inspector / separate plasmid hash**. The species table groups
  by codeome hash only; plasmid buffers are inspectable per-Lenie through
  the existing species inspector but not aggregated.

## Design

### Plasmid struct

New module `Lenies.Plasmid`:

```elixir
defstruct opcodes: []
```

- `opcodes`: regular Elixir list of opcode atoms. Length ∈ [1, 64].

The MVP intentionally keeps the struct minimal. A `created_at_tick` or
`origin_lenie_id` field for forensic tracking can be added in a future
phase without breaking the MVP API.

A list field. MVP carries 0 or 1 element; multi-element support is a
later phase.

### Lenie state changes

`Lenies.Lenie` defstruct gets one new field:

```elixir
plasmids: []
```

The field is part of the snapshot written to `:lenies` ETS (so the
inspector can display it). It is also passed along in `Lenie.start_link`
opts when the parent spawns a child (vertical inheritance) and via
`receive_plasmid/2` GenServer call (horizontal acquisition).

### Two new opcodes

#### `:make_plasmid`

Creates or replaces the Lenie's plasmid from a contiguous range of its
own codeome.

- **Stack**: pops `length` (top), pops `start_addr` (second). Pushes `1`
  on success, `0` on validation failure.
- **Validation**: `length ∈ [1, 64]`. `start_addr` accepted any integer,
  interpreted modulo `codeome_size` (toroidal wrap, consistent with
  `Codeome.at/2`).
- **Effect on success**: extracts the range and stores it as a new
  `%Plasmid{opcodes: extracted_ops}`. Replaces any existing plasmid in
  `plasmids` (the list becomes `[new_plasmid]`).
- **Cost**: `2.0 + 0.05 × length` (mirror of `:allocate`'s structure).
- **Pure VM operation**: does not require a world action / cross-process
  message. Executes synchronously inside the Lenie process.

#### `:conjugate`

Transfers the Lenie's plasmid to the Lenie in the cell directly in front
of it.

- **Stack**: takes no args. Pushes `1` on success, `0` on failure.
- **Preconditions (checked in order)**:
  1. The Lenie has a plasmid (`plasmids != []`). If not, push 0.
  2. The cell in front contains a Lenie. Lookup `:cells` ETS for
     `lenie_id`. If absent, push 0.
  3. The recipient's `codeome_size + plasmid_size ≤ max_codeome_length`
     (default 1000). Checked via a `GenServer.call` to the recipient.
     If too large, push 0.
- **On success**:
  - Append plasmid opcodes to the recipient's codeome.
  - Replace (not append-to) the recipient's `plasmids` with the
    transferred plasmid.
  - Re-cache the recipient's codeome in `:species_codeomes` under the
    new hash.
  - Broadcast a flash event on PubSub topic `"world:fx"` so the
    dashboard can animate both cells.
  - Push 1 on the donor's stack.
- **Cost**: `4.0 + 0.05 × plasmid_size` on success; `4.0` (base only)
  on any failure path. Mirror of `:attack`'s "missed attack still
  costs 5" semantics.
- **Donor side effect**: the donor's own plasmid is **unchanged**
  (transfer is a copy, not a move). This is what allows plasmids to
  spread through a population — every recipient becomes a potential
  donor.

### Plasmid copy at vertical inheritance

When a Lenie divides, `World.spawn_child` passes the parent's plasmid
to the child:

```elixir
parent_plasmids = parent_lenie_state.plasmids
mutated_plasmids = Enum.map(parent_plasmids, &mutate_plasmid/1)
child_opts = [..., plasmids: mutated_plasmids]
```

`mutate_plasmid/1` calls `Lenies.Mutator.copy_mutate/1` on the plasmid's
opcode list using the same `copy_substitution_rate`,
`copy_insert_rate`, `copy_delete_rate` config values that apply to the
codeome. This keeps the mutation model uniform.

**Extra cost at divide**: when the parent has a plasmid, a one-time
tax of `0.5 × plasmid_size` is deducted from the parent's energy at the
moment `:divide` resolves. Mirror of `:write_child` (1.0 per opcode)
reduced to 0.5 because the copy is handled by the World process, not
explicit opcode-by-opcode writes. The tax is folded into the divide
cost so it appears in the existing energy accounting.

### Background mutation on plasmid

When `:background_mutate` fires (existing handler in `Lenie`), the
mutator is applied to **both** the codeome (existing behavior) and the
plasmid buffer (new). Same rate config, same `Lenies.Mutator` call.

The fix from commit `dee5ffc` (re-cache codeome on background mutation)
applies similarly: after mutating the plasmid, no cache update is
required because the plasmid buffer doesn't contribute to
`codeome_hash` (which is computed from the executed codeome only).

### Inter-process communication

`:conjugate` is the only opcode that needs cross-process state
modification. The donor cannot directly mutate the recipient's
`Lenies.Lenie` GenServer state, so it goes through a `GenServer.call`:

```elixir
@spec receive_plasmid(pid(), [atom()]) :: :ok | {:error, :too_large}
def receive_plasmid(pid, plasmid_opcodes) do
  GenServer.call(pid, {:receive_plasmid, plasmid_opcodes})
end

# In the recipient's handle_call:
def handle_call({:receive_plasmid, plasmid_opcodes}, _from, state) do
  new_size = Codeome.size(state.codeome) + length(plasmid_opcodes)
  {_min, max} = Application.get_env(:lenies, :codeome_length_bounds, {3, 1000})
  if new_size > max do
    {:reply, {:error, :too_large}, state}
  else
    new_codeome = Codeome.from_list(
      Codeome.to_list(state.codeome) ++ plasmid_opcodes
    )
    new_plasmid = %Plasmid{opcodes: plasmid_opcodes}
    new_state = %{state | codeome: new_codeome, plasmids: [new_plasmid]}
    cache_codeome_by_hash(new_codeome)
    {:reply, :ok, new_state}
  end
end
```

Latency: a `GenServer.call` between two BEAM processes on the same
node is ~µs. The donor's metabolize loop blocks for one round-trip,
which is negligible compared to the existing `World.action/1` calls
that already round-trip through the `Lenies.World` GenServer.

### UI: conjugation flash

A new PubSub topic `"world:fx"` broadcasts ephemeral visual events.
On a successful `:conjugate`, the donor broadcasts:

```elixir
Phoenix.PubSub.broadcast(Lenies.PubSub, "world:fx",
  {:conjugation, sender_pos, receiver_pos, world_tick})
```

The dashboard LiveView subscribes to `"world:fx"` and pushes events to
the browser via `push_event/3`. The `grid_canvas.js` hook handles
`fx_conjugation` events by adding both cells to a "flashing" set with
a wall-clock expiration time of `now + max(3000, 3 × tick_interval_ms)`,
guaranteeing 3s of visibility at any simulation speed. The canvas
render loop draws flashing cells with heightened saturation/luminosity
that fades over the duration.

The flashing set is purely client-side state; no extra ETS or
server-side bookkeeping needed.

### Hash and species table interaction

The `codeome_hash` continues to be computed only from `state.codeome`.
When a Lenie receives a plasmid, its codeome literally grows (append),
so the hash changes naturally and the recipient appears in the species
table as a new species (or joins an existing one if another Lenie has
already received the same plasmid sequence at the same offset).

The `plasmids` field is not hashed and not displayed in the species
table. The species inspector (existing) can be extended in a follow-up
to show "plasmid carried" per Lenie, but the MVP intentionally leaves
that out — plasmid presence is observable indirectly via the codeome
growth in the inspector's disassembly view.

### Max codeome length

The existing `codeome_length_bounds: {3, 500}` in `config/runtime.exs` is
bumped to `{3, 1000}` to give plasmid accumulation room to play out.
Still tunable.

The `:conjugate` precondition reads the upper bound from this config
(via `Application.get_env(:lenies, :codeome_length_bounds)`) and checks
that `current_size + plasmid_size ≤ upper_bound`. The bound continues
to be enforced separately in `Codeome.from_list/1`.

## Cost summary

| Operation | Cost |
|---|---|
| `:make_plasmid` | `2.0 + 0.05 × length` |
| `:conjugate` (success) | `4.0 + 0.05 × plasmid_size` |
| `:conjugate` (failure) | `4.0` (fixed base only) |
| Plasmid copy at `:divide` | extra `0.5 × plasmid_size` added to parent's divide cost |
| Background mutation on plasmid | no extra energy (existing `:background_mutate` cost unchanged) |

All values live in `Lenies.Codeome.Costs` and are easy to tune later.

## Files changed

**New:**
- `lib/lenies/plasmid.ex` — `%Plasmid{}` struct + helpers
- `test/lenies/plasmid_test.exs`
- `test/lenies/conjugation_test.exs` — integration tests for the full
  conjugation flow

**Modified:**
- `lib/lenies/lenie.ex` — add `plasmids` field, `handle_call` for
  `:receive_plasmid`, background mutation extension, divide-time tax
  (passes `plasmid_copy_cost` to the world's divide action)
- `lib/lenies/world.ex` — accept `plasmids` in `spawn_lenie` /
  `spawn_child` opts, pass through to child Lenie, copy-mutate
  plasmid alongside codeome, charge plasmid copy tax at divide
- `lib/lenies/interpreter.ex` — dispatch entries for `:make_plasmid`
  and `:conjugate`
- `lib/lenies/codeome.ex` or new opcode-list module — add the two
  opcodes to the whitelist
- `lib/lenies/codeome/costs.ex` — add costs for the two opcodes
- `lib/lenies_web/live/dashboard_live.ex` — subscribe to `"world:fx"`,
  push events to the client
- `assets/js/hooks/grid_canvas.js` — handle `fx_conjugation`, render
  flashing cells
- `config/runtime.exs` — bump `max_codeome_length` to 1000

## Testing

| Test | Verifies |
|---|---|
| `Plasmid` struct + mutator | Copy-mutate with rate 0 is identity; with rate 1 produces a different list. |
| `:make_plasmid` valid args | Plasmid created, push 1, opcodes match the slice. |
| `:make_plasmid` invalid `length` (0, 65, negative) | Push 0, no plasmid created. |
| `:make_plasmid` replaces existing plasmid | After two `:make_plasmid` calls, only the second one is stored. |
| `:conjugate` with no plasmid | Push 0, fixed cost paid. |
| `:conjugate` with no front Lenie | Push 0, fixed cost paid. |
| `:conjugate` success integration | Spawn donor with plasmid + recipient adjacent. After donor executes `:conjugate`: recipient's codeome grows by plasmid_size; recipient's `plasmids` = donor's plasmid; donor's plasmid unchanged. |
| `:conjugate` max_codeome_length | Recipient codeome at 990, plasmid 20: conjugation fails, push 0, no state change. |
| Vertical inheritance | Spawn Lenie with plasmid, force divide, child has the same plasmid (or mutated copy if rates > 0). |
| Background mutation on plasmid | With substitution rate 1.0, after one background mutate cycle, the plasmid opcodes have changed. |
| Flash broadcast on conjugation | Subscriber on `"world:fx"` receives `{:conjugation, ...}` on successful `:conjugate`. |
| Energy cost: make_plasmid | Lenie energy decreases by exactly `2.0 + 0.05 × length` after `:make_plasmid`. |
| Energy cost: conjugate failure | Lenie energy decreases by exactly `4.0` after `:conjugate` with no front Lenie. |
| Energy cost: conjugate success | Donor energy decreases by `4.0 + 0.05 × plasmid_size`. |
| Energy cost: divide tax | Parent with plasmid_size 32 pays extra 16.0 at divide vs parent without plasmid. |

## Risk

- **Conjugation as DoS**: a malicious or runaway plasmid could spread
  through the entire population in seconds (since every recipient
  becomes a donor next tick). The 4.0 fixed cost is the natural brake;
  if it proves insufficient in observed runs, raise it to 6-8 or add a
  per-Lenie conjugation cooldown.
- **GenServer.call ordering**: if the recipient is paused (e.g., world
  paused), `:receive_plasmid` blocks until resume. Acceptable
  (donor blocks on its own metabolize loop, but the world tick is also
  paused so no progress is lost).
- **GenServer.call deadlock**: a Lenie's `:conjugate` calls into another
  Lenie's `handle_call`. If they ever called back into each other this
  would deadlock. `:receive_plasmid` is internal-only and never calls
  back; safe.
- **Snapshot save/restore**: `:lenies` ETS records will include the
  `plasmids` field after this change. Old snapshot files (saved before
  this feature) won't have it. Restore code should default to empty
  list when loading old snapshots.

## Out of scope (Phase 2)

- Multiple plasmids per Lenie (state shape already supports this).
- Plasmid loss probability at divide (config-tunable random loss).
- Plasmid hash + dedicated "Plasmids" tab in the dashboard showing
  which plasmids are circulating in the population.
- Receiver-side opcode (`:absorb_plasmid` / refuse / accept).
- Plasmid mutation rates independent from codeome mutation rates.
- Separate `plasmid_substitution_rate` config knob.
