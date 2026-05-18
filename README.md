# Lenies — Digital Evolution Sandbox

Lenies is a Phoenix LiveView application that runs a small artificial world
where digital organisms — Lenies — live, eat, reproduce, mutate, fight, die,
and gradually evolve under selection pressure. Each Lenie is a BEAM process
animated by its own tiny program (its *codeome*), and the whole population
shares a single 256×256 toroidal grid full of regenerating resources,
decaying carcasses, and the occasional cosmic-ray-style mutation.

The point isn't to ship a finished simulation — it's to give you a window
into one. You can watch the population drift in real time, click into any
species to disassemble its code, freeze the world, edit a codeome by
drag-and-drop, and spawn your own creatures into the soup to see whether
they thrive, get eaten, or quietly starve.

> 📘 **Want to write your own codeomes?** Start with the [Lenies Programming Manual](docs/manual/README.md) — a chapter-by-chapter guide that takes you from your first six-opcode walker to a tuned self-replicator.

---

## Table of contents

- [What Lenies looks like](#what-lenies-looks-like)
- [Quick start](#quick-start)
- [How it works, in three paragraphs](#how-it-works-in-three-paragraphs)
- [Touring the dashboard](#touring-the-dashboard)
- [Editing and creating seeds](#editing-and-creating-seeds)
- [Built-in seeds](#built-in-seeds)
- [Where things live](#where-things-live)
- [Further reading](#further-reading)

---

## What Lenies looks like

Open the dashboard and you'll see a dark sci-fi console with the world
map filling the full body height on the left — a square canvas pulsing
with coloured pixels, each one a live Lenie coloured by its species.
The right column stacks two rows: at the top a sparkline of recent
population history with a table beneath listing **every** active
species sorted by population; at the bottom a control panel for
pausing, sterilising, spawning seeds, plus a live tuning section for
every knob in the simulation.

You can scroll-zoom and click-drag-pan on the map; double-click any
Lenie cell and the codeome editor opens with that species pre-loaded.
Hovering a Lenie cell switches the cursor to a hand pointer as a hint
that the cell is editable. Clicking a species row in the table opens
the inspector to its right — a disassembly of the codeome with
population and average generation — and dims every other species on
the map so the selected one stands out.

---

## Quick start

Requirements: Erlang/OTP 26+, Elixir 1.18+ (1.19 known to work).

```bash
mix deps.get
mix compile
iex -S mix phx.server
```

Open <http://localhost:4000>. The simulation starts immediately with a
hand-tuned replicator seeding the population.

---

## How it works, in three paragraphs

**The world** is a 2D grid that wraps at every edge (so a Lenie walking
north long enough comes back from the south). Each cell holds either
nothing, a pile of resource, a carcass, or one Lenie. Radiation drips new
resource into cells every tick, concentrated on a handful of permanent
hotspots and sprinkled uniformly elsewhere; carcasses decay over time and
are also edible. Energy is conserved: it enters the system only through
radiation, leaves only when Lenies starve, and is passed around through
eating, fighting, and reproduction.

**A Lenie** is a BEAM process whose only state is a stack-based virtual
machine and an energy counter. Its program — the *codeome* — is a sequence
of opcodes drawn from a small whitelist. The same sequence is both the
genome (copied with errors into children during replication) and the
running code (executed in batches by an interpreter). Lenies die when
their energy hits zero; species emerge as clusters of identical or
near-identical codeomes, identified by a stable hash. The Programming
Manual covers all of this from the ground up.

**Selection** falls out of these mechanics without any explicit fitness
function. Codeomes that waste energy, fail to forage, or crash on common
mutations die out; codeomes that replicate cleanly and tolerate copy
errors slowly spread. Predators (Lenies whose codeomes invoke `:attack`)
appear, and herbivores evolve defences. There's no winner — just a small
ecosystem you can poke at.

---

## Touring the dashboard

**On the world map (left, full-height):**

- **Scroll** zooms in and out, anchored on the cursor so the cell under
  the mouse stays put across the zoom.
- **Click and drag** pans the view (only meaningful once zoomed past 1×;
  at 1× the whole grid is on screen).
- **Single click** on a cell recenters the view there.
- **Double click** on a cell with a Lenie opens the codeome editor for
  that species (cursor turns into a pointer over occupied cells to hint
  at this). Empty cells are a no-op.
- Three checkboxes under the map toggle the **Lenies / Resources /
  Carcasses** layers independently.

**On the right column, top row:**

- The sparkline tracks the population of the top species over the last
  few minutes; one coloured line per species in the current top 10.
- The table beneath lists **every** active species (full count, scrolls
  vertically when there are many). Click a row to open the species
  inspector and highlight that species on the map — every other species
  is dimmed to 30 % alpha.

**On the right column, bottom row:**

- **Pause / Resume** stops and restarts the environmental tick. The
  world freezes; the canvas stops updating.
- **Sterilize** kills every Lenie and resets the world to an empty
  grid. A confirm button appears to prevent accidents.
- **+ New Seed** opens the codeome editor with an empty buffer.
- **Manage** toggles the list of user-saved seeds so you can delete
  them.
- **Spawn** picks a seed from the dropdown (built-in or user-saved)
  and drops N copies into random free cells with a chosen starting
  energy.
- **Snapshot** saves and reloads the entire world state from disk.
- Under that, the **Tuning Live** section exposes runtime sliders for
  every world parameter — radiation, eat amount, copy-error rates,
  attack damage, the BG-mutation rate per 1000 ticks, and more.
  Changes apply immediately to all live Lenies.

The species inspector (slides in when you click a row) shows the
species' colour swatch, the codeome disassembled into coloured opcode
blocks (one per category), and Edit / Spawn buttons. Clicking the row
again closes it; selecting a different row swaps the highlight.

---

## Editing and creating seeds

The codeome editor is a full-screen page with three panes. On the far
left, a collapsible **Programming Manual** for in-editor reference. In
the middle, a palette of all 36 opcodes grouped by category (drag a
chip onto the listing to insert; double-click a chip to append at end;
or paste a space/comma-separated text list into the input above and
the editor tokenises it). On the right, the current codeome rendered
as a vertical stack of coloured blocks — one block per opcode, in
execution order. Drag the `≡` handle to reorder, click the `⨯` to
delete.

Above the listing, an **Energy / pass** mini-panel recomputes on every
opcode add / remove / reorder. It shows:

- `cost` — exact sum of per-opcode static costs for one linear pass
  through the buffer (template-jump lengths read from the run of nops
  following each jump; `:allocate` priced at the current buffer length
  as a typical-replicator proxy).
- `max gain` — strict upper bound assuming every `:eat` and `:attack`
  hits, using the live `eat_amount` and `attack_damage` tuning values.
- `net = max_gain - cost` colour-coded green / red.

A live validation banner tells you whether the current buffer is
acceptable: too short, too long, or with too few non-template opcodes
will each block you from spawning or saving. When the buffer is valid
you can **Spawn** directly into the running world or **Save** as a
named user seed (with a colour and a default starting energy). Saved
seeds persist across restarts and appear with a star prefix in the
spawn dropdown.

The editor opens both from the **+ New Seed** button (empty buffer),
from the **Edit** button on the species inspector (pre-loaded with that
species' current codeome), and from a **double click on a Lenie cell**
on the dashboard map. Editing a species edits a *copy* — the running
Lenies of that species are untouched until you spawn your edited
version back into the world.

For everything about *what* to put in those blocks — the VM, the opcodes,
template addressing, replication, the energy budget, and a worked tour
through seven hand-crafted codeomes of growing complexity — see the
[Programming Manual](docs/manual/README.md).

---

## Built-in seeds

Three seeds come pre-loaded in the spawn dropdown:

- **Minimal Replicator** — a hand-written 121-opcode self-replicator with a
  128-step forage cycle between divisions. Robust enough to maintain a
  steady population on the default world. Source:
  [lib/lenies/codeomes/minimal_replicator.ex](lib/lenies/codeomes/minimal_replicator.ex).
  The Programming Manual dissects it line by line in
  [chapter 9](docs/manual/09-minimal-replicator.md).
- **Carnivore** — the Minimal Replicator with `:attack` injected before
  `:eat`. Demonstrates predation; thrives in dense populations, starves
  in sparse ones. Source:
  [lib/lenies/codeomes/carnivore.ex](lib/lenies/codeomes/carnivore.ex).
- **Random** — a random codeome of length 30..120 sampled uniformly from
  the whitelist. Almost never replicates; useful as a baseline for how
  fragile a "naive" creature is.

---

## Where things live

User-saved seeds are persisted to `priv/user_seeds.json` and loaded at
boot by [Lenies.Seeds.CustomStore](lib/lenies/seeds/custom_store.ex).
Saves are atomic (write to `.tmp`, then `rename`). Corrupt JSON is
renamed to `.bak` and the store starts fresh, so a malformed manual edit
won't brick the app.

World snapshots saved through the dashboard land under the path you give
the Snapshot form — typically `/tmp/lenies-snapshot/` — as a small tree
of `.tab` files.

Repository layout:

```
lib/lenies/                  — domain (world, lenie, interpreter, codeome, mutator)
  codeome/opcodes.ex         — the 36-opcode whitelist and its encoding
  codeome/costs.ex           — energy cost per opcode
  codeomes/                  — built-in hand-written seeds
  interpreter.ex             — the stack VM
  interpreter/state.ex       — execution state struct
  interpreter/template.ex    — template addressing
  seeds.ex                   — built-in seed catalog
  seeds/custom_store.ex      — user-saved seeds, JSON-backed
  world.ex                   — the environment GenServer
  world/                     — cells, tables, hotspots, radiation, child slots
lib/lenies_web/
  codeome_buffer.ex          — pure ops + validation for the editor
  disassembler.ex            — codeome → human-readable lines
  live/                      — LiveView pages and components
assets/                      — JS hooks and CSS
config/runtime.exs           — all tunable parameters live here
priv/user_seeds.json         — persisted user seeds (created on first save)
docs/manual/                 — the Programming Manual
docs/superpowers/specs/      — design specs for the major subsystems
```

---

## Further reading

- 📘 [Programming Manual](docs/manual/README.md) — from zero to writing
  your own sustainable replicator. Twelve chapters, ~4 200 lines of
  English text and worked examples.
- [Lenies design spec](docs/superpowers/specs/2026-05-11-lenies-design.md) —
  the original architectural notes, including the world model, mutation
  rates, and selection mechanics.
- All subsystem specs and implementation plans live in
  [docs/superpowers/](docs/superpowers/) — every feature in the dashboard
  was brainstormed, specced, planned, and shipped with a paper trail.
