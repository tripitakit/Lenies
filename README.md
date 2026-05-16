# Lenies — Digital Evolution Sandbox

Lenies is a small Phoenix LiveView application that runs a population of
self-replicating digital organisms on a toroidal 2D grid. Each organism (a
*Lenie*) is a BEAM process whose body and behaviour are entirely determined by
its **codeome** — a sequence of opcodes that is at once its genome and its
running program, executed by a tiny stack-based virtual machine. The world
applies resource regeneration, radiation, copy errors and background mutations,
so the population mutates, diversifies into species (clustered by codeome
hash), and is selected on energy balance.

The dashboard lets you watch the grid live, inspect species, edit existing
seeds or compose new ones from scratch with a drag-and-drop block editor.

> 📘 **Want to write your own codeomes?** See the [Lenies Programming Manual](docs/manual/README.md).

---

## Table of contents

0. [Programming manual](docs/manual/README.md) — write your own codeomes from scratch
1. [Quick start](#quick-start)
2. [The world model](#the-world-model)
3. [The Lenie organism](#the-lenie-organism)
4. [Virtual machine manual](#virtual-machine-manual)
5. [Codeome instruction set](#codeome-instruction-set)
6. [Template addressing](#template-addressing)
7. [Editing seeds and creating new seeds](#editing-seeds-and-creating-new-seeds)
8. [Validation rules and limits](#validation-rules-and-limits)
9. [Persistence](#persistence)
10. [Built-in seeds](#built-in-seeds)
11. [Worked example](#worked-example-a-tiny-walker)
12. [Repository layout](#repository-layout)

---

## Quick start

Requirements: Erlang/OTP 26+, Elixir 1.18+ (1.19 known to work).

```bash
mix deps.get
mix compile
iex -S mix phx.server
```

Open <http://localhost:4000>.

You will see three columns:

- **Left** — the 256×256 world canvas with toggleable layers (Lenies,
  resources, carcasses), the population/resource/carcass counters, and the
  per-species population sparkline.
- **Center** — the species table (top species by population). Click a row to
  open the inspector.
- **Right** — the controls panel: pause/resume the tick, sterilize the world,
  spawn from a built-in or saved seed, save/load snapshots, and the
  **+ New Seed** button that opens the empty codeome editor.

Clicking a species opens the inspector with the disassembled codeome and an
**Edit** button. Clicking **+ New Seed** opens the same editor with an empty
buffer. The editor is a full-screen overlay with the opcode palette on the
left (drag chips onto the listing on the right) and the codeome listing on the
right (drag to reorder, click `+` between blocks to insert, `↺` to replace,
`⨯` to delete).

---

## The world model

The world is a single `GenServer` (`Lenies.World`) owning a few ETS tables and
ticking on a fixed interval. The defaults below are in
[config/runtime.exs](config/runtime.exs); they are also exposed via
[Lenies.Config](lib/lenies/config.ex).

| Parameter | Default | Meaning |
|---|---|---|
| `grid_size` | `{256, 256}` | Toroidal grid (wraps on every edge). |
| `tick_interval_ms` | `100` | Time between environmental ticks. |
| `population_cap` | `50 000` | Hard cap; spawns above this are refused. |
| `cell_resource_cap` | `100` | Max resource a single cell can hold. |
| `radiation_per_tick` | `1000` | Resource units injected per tick. |
| `radiation_uniform_ratio` | `0.7` | Fraction sprinkled uniformly; the rest is concentrated on hotspots. |
| `hotspot_count` | `8` | Persistent high-radiation cells. |
| `carcass_decay` | `0.01` | Fraction of carcass biomass lost per tick. |
| `eat_amount` | `20` | Resource pulled by one successful `:eat`. |
| `interpreter_steps_per_batch` | `10` | Opcodes executed per Lenie per metabolic tick. |
| `copy_substitution_rate` | `0.005` | Per-opcode substitution probability during `:write_child`. |
| `copy_insert_rate` | `0.0005` | Per-opcode insertion probability during `:write_child`. |
| `copy_delete_rate` | `0.0005` | Per-opcode deletion probability during `:write_child`. |
| `background_mutation_interval_ticks` | `1000` | Background substitution rate on living codeomes. |

Cells contain a resource value, an optional carcass biomass, and either a
Lenie or nothing. The world is closed: energy comes in only through radiation
and is recovered from carcasses via `:eat`.

**Two sources of mutation**

- *Copy errors* during `:write_child` (substitute / insert / delete /
  faithful), see [Lenies.Mutator](lib/lenies/mutator.ex).
- *Background mutation*: rarely, a random opcode of a random living Lenie is
  rewritten in place.

---

## The Lenie organism

Each living Lenie is a `Lenies.Lenie` GenServer:

- It is registered in a `Registry` with its UUID id.
- Its `max_heap_size` is bounded — a process that allocates too much is
  killed automatically (this is one of the implicit selection pressures).
- It executes on a metabolic timer: every `lenie_metabolize_delay_ms`
  (50 ms by default) the interpreter is asked to run up to K =
  `interpreter_steps_per_batch` opcodes (default 10).
- Whenever the interpreter needs the world (`:move`, `:eat`, `:sense_front`,
  `:attack`, `:defend`, `:allocate`, `:write_child`, `:divide`), the batch
  yields and the Lenie issues a synchronous `GenServer.call` to the world,
  applies the result, then resumes.
- A Lenie dies when its energy falls to 0 (`:starvation`), when its codeome
  is empty, or when the BEAM kills it for heap overflow.
- On death, the world frees the cell and, depending on the energy at death,
  may deposit a carcass that other Lenies can later `:eat`.

Species are clusters of Lenies with the same `codeome_hash`, computed by
`Lenies.Codeome.hash/1` (a `:erlang.phash2` of the opcode tuple). The
dashboard table is the list of top species; clicking a row fetches a
representative live Lenie of that hash and disassembles its codeome for the
inspector.

---

## Virtual machine manual

The VM is a small stack machine specialised for self-modifying, fault-tolerant
code. The reference implementation is
[Lenies.Interpreter](lib/lenies/interpreter.ex), with state in
[Lenies.Interpreter.State](lib/lenies/interpreter/state.ex).

### Execution model

- The codeome is a **ring**: the instruction pointer always wraps modulo
  `size(codeome)`. Negative indices wrap correctly too.
- Execution proceeds one opcode at a time. For each opcode the interpreter
  charges an energy cost, applies the side effect (stack/slots/IP/dir), then
  either continues (`{:cont, state}`), yields to the world
  (`{:wait_world, action, state}`), or halts the Lenie
  (`{:halt, reason, state}`).
- Energy ≤ 0 after charging an opcode causes `{:halt, :starvation, state}`.
- Unknown opcodes are silently treated as `:nop_0`. **Mutations never produce
  syntax errors**; the worst they can do is consume energy.

### State

The interpreter state is the following struct (all integers are signed but
treated as bounded; the stack holds plain integers, the slots map carries
four named slots):

| Field | Type | Notes |
|---|---|---|
| `ip` | non-negative integer | Instruction pointer; advances by 1 by default, wraps. |
| `stack` | list of integers, max 16 | Top = head. Push beyond 16 drops the oldest item. |
| `slots` | `%{0..3 => integer}` | Four named memory slots, default 0. |
| `dir` | `:n | :e | :s | :w` | Facing direction; `:turn_left`/`:turn_right` rotate it. |
| `energy` | float | Decreases on every opcode. Death at ≤ 0. |
| `age` | non-negative integer | Incremented once per K-instruction batch. |
| `pos` | `{x, y}` | Grid position; updated by `:move`. |
| `call_stack` | list of return IPs, max 32 | Used by `:call_t` / `:ret`. |

### Defensive semantics

These rules are essential for selecting on programs that *evolve* rather than
crash:

- `pop` on an empty stack returns `0`, not an error.
- `:mod` with `0` divisor returns `0`.
- Slot indices wrap modulo 4 (so any integer maps to a valid slot).
- Memory addresses in `:store`, `:load`, `:read_self` wrap modulo the
  appropriate dimension.
- Jumps that fail to find a template complement fall through to the next
  instruction instead of erroring.
- `:ret` on an empty call stack falls through.

### World-yielding instructions

Six categories of opcode yield to the world (interpreter returns
`:wait_world`):

- `:sense_front` — pushes a description of the cell in front.
- `:move` — moves into the front cell if free.
- `:eat` — consumes up to `eat_amount` resource from the current cell.
- `:attack`, `:defend` — predation between Lenies.
- `:allocate`, `:write_child`, `:divide` — replication.

The Lenie process is the only thing that talks to the world; the interpreter
itself is pure.

---

## Codeome instruction set

The full whitelist is in
[Lenies.Codeome.Opcodes](lib/lenies/codeome/opcodes.ex). Costs are in
[Lenies.Codeome.Costs](lib/lenies/codeome/costs.ex). Stack notation below uses
the convention **`( before -- after )`** with the **top of the stack on the
right**.

### Template / no-op (cost 0.1)

| Opcode | Stack | Description |
|---|---|---|
| `nop_0` | `( -- )` | Bit-0 of a template; otherwise has no effect on state. |
| `nop_1` | `( -- )` | Bit-1 of a template; otherwise has no effect on state. |

Sequences of `nop_0`/`nop_1` that immediately follow a jump opcode are read
as a **template**; the jump then searches the codeome for the **bit-flipped
complement**. This is how branches work — see [Template addressing](#template-addressing).

### Stack (cost 0.1)

| Opcode | Stack | Description |
|---|---|---|
| `push0` | `( -- 0 )` | Push integer 0. |
| `push1` | `( -- 1 )` | Push integer 1. |
| `pushN` | `( -- r )` | Push a uniform random integer in `0..255`. |
| `dup`   | `( a -- a a )` | Duplicate top. |
| `drop`  | `( a -- )` | Discard top. |
| `swap`  | `( b a -- a b )` | Swap the two top values. |

### Arithmetic (cost 0.2)

All arithmetic is over plain Elixir integers (unbounded). `:sub` and `:mod`
take the top as the divisor / subtrahend.

| Opcode | Stack | Description |
|---|---|---|
| `add` | `( b a -- b+a )` | |
| `sub` | `( b a -- b-a )` | |
| `mul` | `( b a -- b*a )` | |
| `mod` | `( b a -- b mod a )` | When `a = 0`, pushes `0` (no crash). |

### Control flow (cost 0.2 + 0.05 × template_len)

| Opcode | Stack | Description |
|---|---|---|
| `jmp_t`  | `( -- )` | Unconditional jump to the complement of the template that follows. |
| `jz_t`   | `( c -- )` | Jump if `c = 0`. |
| `jnz_t`  | `( c -- )` | Jump if `c ≠ 0`. |
| `call_t` | `( -- )` | Push return IP (= position after the template), then jump. |
| `ret`    | `( -- )` | Pop the call stack and jump to the saved return IP; if empty, fall through. |

The template is read **starting at the instruction after the jump opcode**
and consists of the longest run of `nop_0`/`nop_1` up to `template_max_len`
(default 8). If the search finds no complement within
`template_search_radius` (default 256) in either direction, the jump becomes
a no-op (the IP advances past the template).

### Sense — local (cost 0.5)

These do not yield to the world; they push self-state.

| Opcode | Stack | Description |
|---|---|---|
| `sense_self`   | `( -- 1 )` | Trivially pushes 1; useful as a constant. |
| `sense_energy` | `( -- e )` | Push truncated current energy. |
| `sense_age`    | `( -- a )` | Push age (number of completed batches). |
| `sense_size`   | `( -- n )` | Push codeome length. |

### Sense — world (cost 0.5)

| Opcode | Stack | Description |
|---|---|---|
| `sense_front` | `( -- k )` | Yields to the world; pushes a small integer encoding the cell in front (empty / resource / lenie / carcass — see the world action handler). |

### Orientation (cost 0.5)

| Opcode | Stack | Description |
|---|---|---|
| `turn_left`  | `( -- )` | Rotate `dir` 90° CCW. |
| `turn_right` | `( -- )` | Rotate `dir` 90° CW. |

### Action — world (cost 2.0)

| Opcode | Stack | Description |
|---|---|---|
| `move` | `( -- )` | Move into the front cell if it is empty; otherwise no-op. |
| `eat`  | `( -- )` | Consume up to `eat_amount` resource (default 20) from the current cell; the energy gained is added to `energy`. |

### Predation

| Opcode | Cost | Description |
|---|---|---|
| `attack` | 5.0 | Strike whatever is in the front cell. If it is a Lenie, transfer `attack_damage` (default 10) energy from victim to attacker; the defender may have a defensive window active (see `:defend`). If empty or a carcass, the action wastes the cost. |
| `defend` | 2.0 | Mark the Lenie defended for `defense_window_ticks` (default 5). An attacker who hits a defended Lenie during that window also pays `defense_attacker_penalty` (default 5). |

### Self-inspection (cost 0.3)

| Opcode | Stack | Description |
|---|---|---|
| `get_ip`   | `( -- ip )` | Push current instruction pointer. |
| `get_size` | `( -- n )` | Push codeome length. |
| `read_self`| `( a -- op_int )` | Pop address `a`; push the integer encoding of the opcode at `a` (wraps mod size). The encoding is the index of the opcode in the whitelist; `:write_child` accepts this same encoding. |

### Replication

These three opcodes are how a Lenie produces offspring. The protocol is:

1. `:allocate` — reserve a child slot in front of you of a given size.
2. `:write_child` — copy opcodes (one at a time) into that child slot.
3. `:divide` — commit: spawn a new Lenie with the assembled codeome, split
   the remaining energy with the child.

| Opcode | Cost | Stack | Description |
|---|---|---|---|
| `allocate`    | `5.0 + 0.05 × n` | `( n -- )` | Pop `n`; ask the world to allocate a child buffer of size `n` in the front cell. The world replies with `:ok` (next `:write_child` is valid) or `:no_target` (next `:write_child` is a no-op). |
| `write_child` | 1.0 | `( addr op_int -- )` | Pop `op_int` (a `:read_self`-style encoding) and `addr`; write into the pending child buffer at index `addr mod n`. Unknown encodings decode to `:nop_0`. |
| `divide`      | 10.0 | `( -- )` | Spawn the child from the buffer. The child appears in the front cell with `energy/2` of the parent (after cost). If `:allocate` failed or no buffer is pending, `:divide` is a no-op. |

Because copy errors (`copy_substitution_rate` etc.) are applied **per
`:write_child` call**, a viable replicator must be tolerant of point
mutations on each opcode copied.

### Local memory (cost 0.5)

| Opcode | Stack | Description |
|---|---|---|
| `store` | `( v s -- )` | Pop slot index `s` (mod 4), pop value `v`, write `slots[s] = v`. |
| `load`  | `( s -- v )` | Pop slot index `s`; push `slots[s]`. |

---

## Template addressing

Lenies uses *Tierra-style* template addressing for control flow. There are no
absolute labels — the codeome searches itself for matching patterns at run
time. This makes mutations to a single `nop` either *neutral* (template
matches a different position with the same complement) or *selective*
(re-routes a branch), without ever producing a syntax error.

**How a jump resolves**

1. The interpreter reads the bytes **immediately after** the jump opcode and
   collects the longest run of `nop_0`/`nop_1` (up to
   `template_max_len = 8`). This is the *template*.
2. It then computes the *complement* by flipping every bit:
   `:nop_0 ↔ :nop_1`.
3. It searches the codeome for the complement: first forward up to
   `template_search_radius = 256`, then backward by the same amount.
4. If found, the IP jumps to the position **immediately after** the matched
   complement. If not, the IP just skips past the template.

**Practical consequences**

- A jump *opcode* alone is not enough — it needs a template. Otherwise it
  jumps with `template_len = 0`, which always falls through.
- To name a target, prepend it with an *anchor*: a run of `nop_*` whose bits
  are the complement of the jump's template.
- Templates are extracted **greedily** up to `template_max_len`. If two
  template runs are immediately adjacent in the source, you must place a
  non-nop **separator** between them (any cheap opcode such as `:push0`
  works; place it in unreachable code if you can).
- The cost of a jump grows with the template length:
  `0.2 + 0.05 × template_len`. Most hand-written seeds use templates of
  length 4.

Worked example: a `jmp_t` followed by `[:nop_0, :nop_1, :nop_0, :nop_0]`
searches for `[:nop_1, :nop_0, :nop_1, :nop_1]`. The reference
[Lenies.Codeomes.MinimalReplicator](lib/lenies/codeomes/minimal_replicator.ex)
spells out six anchors (`LOOP_HEAD`, `COPY_LOOP_HEAD`, `ABORT_TARGET`,
`TURN_LEFT_ANCHOR`, `SKIP_TURN_ANCHOR`, `FORAGE_LOOP_HEAD`) and is a good
reference for how anchors and separators are laid out in practice.

---

## Editing seeds and creating new seeds

The codeome editor is reachable two ways:

- **+ New Seed** in the controls panel — opens an empty buffer.
- Click a species row → **Edit** in the inspector — opens with the species'
  current codeome pre-loaded.

The editor is a full-screen overlay with two panes:

### Left pane — opcode palette

All 36 opcodes are visible at once, grouped by category and colour-coded the
same way the listing colours individual blocks. **Drag** a palette chip into
the listing on the right to insert the opcode at the drop position. The
palette never scrolls — every opcode is one drag away.

### Right pane — codeome listing

Each opcode in the buffer is shown as a coloured block with its position and
mnemonic. You can:

- **Drag the `≡` handle** to reorder a block.
- Click `+` between blocks (or above/below the list) to open a *picker* and
  insert an opcode at that index.
- Hover a block to reveal `↺` (replace via picker) and `⨯` (delete).

### Header / toolbar

- A `●dirty` indicator appears as soon as you modify the buffer.
- Live **validation**: `✓ valid (N ops, M non-nop)` if the buffer satisfies
  the bounds; `⚠` with a list of errors otherwise.
- **Cancel** — discard edits and close the editor.
- **Spawn** — instantly spawn `count` Lenies with the current buffer and a
  given initial energy. Available only when the buffer is valid.
- **Save** (new-seed mode only) — persist the buffer as a named user seed
  with a colour swatch and a default energy. The new seed then appears in
  the **Seed** dropdown in the controls panel (and survives restarts — see
  [Persistence](#persistence)).

### Suggested workflow for a new seed

1. Click **+ New Seed**.
2. Drop in the constants and `:store` calls you need to set up your slots
   (for example: `push1`, `dup`, `add`, …, `push0`, `store` to write a small
   integer into `slot[0]`).
3. Add an anchor for the loop entry — a run of `nop_*` of length 4 — and
   remember the bit pattern.
4. Drop in the body of the loop.
5. End with a `jmp_t` whose template is the *complement* of the entry
   anchor.
6. If the loop entry anchor sits immediately at the start of the codeome and
   the loop ends just before the wrap, add a `push0` separator at the wrap
   so that the closing `jmp_t`'s template does not greedily run into the
   entry anchor across the ring.
7. Watch the validation banner: at minimum you need 10 non-nop opcodes and a
   buffer length in `5..500`.
8. **Spawn 1** with a generous energy (10 000+) on an empty world to see it
   run alone; if it survives, save it.

### Editing an existing seed

The Edit button loads the current codeome of a live representative of the
species. Edits do not affect already-running Lenies — they are working on
their own private copy. Use **Spawn** to drop new instances of your edited
program into the world, or save it as a new seed to keep it around.

---

## Validation rules and limits

The editor enforces three constraints (`LeniesWeb.CodeomeBuffer.validate/1`):

| Rule | Default |
|---|---|
| `codeome_length_bounds` | `{5, 500}` opcodes |
| `min_viable_codeome_opcodes` | `10` non-nop opcodes |
| Every opcode must be in the whitelist | 36 entries |

A buffer that fails any of these cannot be spawned or saved. The minimum on
non-nops exists to prevent a buffer that is all-template (which would do
nothing useful) from being treated as a viable seed.

Other hard limits worth knowing:

- Stack depth: **16** values. Pushing beyond drops the oldest.
- Call stack: **32** frames.
- Memory slots: **4**.
- Template length: **0..8** opcodes.
- Template search radius: **256** opcodes in each direction.
- Per-Lenie process heap is capped (`lenie_max_heap_size`, default 1 M).

---

## Persistence

User-saved seeds live in `priv/user_seeds.json` and are managed by
[Lenies.Seeds.CustomStore](lib/lenies/seeds/custom_store.ex). The Agent that
backs the store loads the file at boot and writes it atomically (write to
`.tmp`, then `rename`) on every save/delete. Corrupt JSON is renamed to
`.bak` and the store starts fresh.

The on-disk shape is a JSON array of objects:

```json
{
  "id": "my-replicator-v1",
  "name": "my replicator v1",
  "color_hex": "#7c3aed",
  "energy_default": 10000.0,
  "opcodes": ["nop_1", "nop_1", "nop_1", "nop_1", "get_size", "..."]
}
```

`opcodes` is the same atom list the editor manipulates; only whitelisted
names are accepted on load.

---

## Built-in seeds

- **Minimal Replicator** —
  [lib/lenies/codeomes/minimal_replicator.ex](lib/lenies/codeomes/minimal_replicator.ex).
  A hand-written 121-opcode replicator with a 128-step forage cycle between
  divisions; a good reference for templates, anchors, separators, and the
  allocate/write_child/divide protocol.
- **Carnivore** —
  [lib/lenies/codeomes/carnivore.ex](lib/lenies/codeomes/carnivore.ex).
  Same body as the minimal replicator, with `:attack` injected before each
  `:eat`. Demonstrates predation.
- **Random (likely sterile)** — a random codeome of length 30..120 drawn
  uniformly from the whitelist. Almost never replicates; useful as a baseline.

---

## Worked example — a tiny walker

The shortest interesting codeome is a one-direction walker:

```
0  nop_0           ; anchor for the loop (bit pattern [0])
1  sense_front     ; yields to the world; pushes cell info
2  drop            ; we don't use it
3  eat             ; try to consume resource
4  move            ; advance
5  jmp_t           ; jump back to the anchor
6  nop_1           ; template — complement of nop_0 → matches position 0
```

This is below the 10-non-nop validation threshold, so the editor will mark
it `⚠ insufficient_non_nops`. Pad it with a few `push0`/`drop` pairs (cheap
no-ops at 0.1 energy each) or with extra `sense_*` calls until validation
passes, and you have your first viable seed. It cannot replicate — it will
just walk north and eat — but it is a complete program you can spawn and
watch.

To turn it into a replicator, add the `allocate → write_child × N → divide`
loop from the [Minimal Replicator](lib/lenies/codeomes/minimal_replicator.ex)
moduledoc, which documents the cost balance (`E_new ≈ E_old/2 + 1080`
steady-state with default `eat_amount`).

---

## Repository layout

```
lib/lenies/                  — domain (world, lenie, interpreter, codeome, mutator)
  codeome/opcodes.ex         — whitelist and encoding
  codeome/costs.ex           — energy cost per opcode
  codeomes/                  — built-in hand-written seeds
  interpreter.ex             — the VM
  interpreter/state.ex       — execution state struct
  interpreter/template.ex    — template addressing
  seeds.ex                   — built-in seed catalog
  seeds/custom_store.ex      — user-saved seeds (JSON-backed Agent)
  world.ex                   — environment GenServer
  world/                     — cells, tables, hotspots, radiation, child slots
lib/lenies_web/
  codeome_buffer.ex          — pure operations + validation for the editor
  disassembler.ex            — codeome → human-readable lines
  live/dashboard_live.ex     — the main page
  live/species_inspector_component.ex — the editor / inspector panel
  live/controls_panel_component.ex    — pause/spawn/snapshot/seed controls
assets/                      — JS hooks (CodeomeSortable, CodeomePalette) + CSS
config/runtime.exs           — all tunable parameters live here
priv/user_seeds.json         — persisted user seeds (created on first save)
docs/superpowers/specs/      — design specs for the major subsystems
```

For a deeper architectural walk-through, see
[docs/superpowers/specs/2026-05-11-lenies-design.md](docs/superpowers/specs/2026-05-11-lenies-design.md).
