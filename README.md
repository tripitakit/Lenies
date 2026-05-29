# Lenies — Digital Evolution Sandbox

Lenies is a Phoenix LiveView application that runs a small artificial world
where digital organisms — Lenies — live, eat, reproduce, mutate, fight, die,
and gradually evolve under selection pressure. Each Lenie is a BEAM process
animated by its own tiny program (its *codeome*).

The world is **shared**: a single 256×256 toroidal grid called the **Arena**
is the publicly-viewable homepage where any visitor can watch the ecosystem
drift in real time, and logged-in users can seed their own creatures into it
— **one alive lineage per player at a time**. Codeomes thrive, get eaten, or
quietly starve; the strongest patterns colonise the grid until something
better displaces them.

The point isn't to ship a finished game. It's to give you a window into
evolution as a participatory ecosystem. Watch the Arena, log in to plant your
own Lenie, craft codeomes in your private Sandbox, save them to your
collection, see whether they survive.

> 📘 **Want to write your own codeomes?** Start with the [Lenies Programming Manual](docs/manual/README.md) — a chapter-by-chapter guide that takes you from your first six-opcode walker to a tuned self-replicator.

---

## Table of contents

- [Two surfaces: Arena and Sandbox](#two-surfaces-arena-and-sandbox)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [The Arena](#the-arena)
- [The Sandbox](#the-sandbox)
- [The codeome editor](#the-codeome-editor)
- [Further reading](#further-reading)
- [A note on the name](#a-note-on-the-name)

---

## Two surfaces: Arena and Sandbox

Lenies has two complementary places where the simulation runs:

**The Arena — `/`** is the shared public ecosystem. Anyone can land on the URL
and watch the world drift; no account is required. A presence counter shows
how many people are currently watching. If you have an account, you can seed
**one Lenie at a time** from your personal collection. Your lineage — that
seeded Lenie plus all of its descendants — propagates through replication; you
cannot seed another until your last descendant dies naturally, OR you trigger
**Apoptosis** to self-terminate your lineage and start fresh.

**The Sandbox — `/sandbox`** is your private laboratory, behind login. Same
world model as the Arena, but exclusively yours: full control surface (tuning
sliders, pause/resume, sterilize, manual snapshot save/restore), spawn from
the full library (built-ins + your collection), N copies at a time, and the
codeome editor under `/sandbox/editor/new`. The Sandbox auto-snapshots on
disconnect and resumes from where you left off when you come back — it feels
like a workspace you keep around between sessions.

The natural flow is **write in the Sandbox → save a codeome to your collection
→ seed it into the Arena → watch your creature compete in public**.

---

## Quick start

Requirements: Erlang/OTP 28+, Elixir 1.19+, Postgres 12+.

```bash
mix setup        # deps.get + ecto.setup (create + migrate DB) + assets.build
iex -S mix phx.server
```

Open <http://localhost:4000> — you land on the public Arena. To play (write
codeomes, seed in the Arena), click **Register** in the top-right, confirm
via the dev mailbox at `/dev/mailbox`, then visit `/sandbox`.

The Arena starts empty until someone (you, another user) seeds something into
it. Your Sandbox starts empty too — open the editor at `/sandbox/editor/new`
or spawn one of the five built-in seeds (Minimal Replicator, Carnivore,
Defender, Hunter, Forager) from the dashboard's Spawn dropdown to get going.

---

## How it works

**The world** is a 2D grid that wraps at every edge (so a Lenie walking north
long enough comes back from the south). Each cell holds either nothing, a pile
of resource, detritus, or one Lenie. Radiation drips new resource into cells
every tick, concentrated on a handful of permanent hotspots and sprinkled
uniformly elsewhere; detritus decays over time and is also edible. Energy is
conserved: it enters the system only through radiation, leaves only when
Lenies starve, and is passed around through eating, fighting, and reproduction.

**A Lenie** is a BEAM process whose only state is a stack-based virtual
machine and an energy counter. Its program — the *codeome* — is a sequence of
opcodes drawn from a small whitelist. The same sequence is both the genome
(copied with errors into children during replication) and the running code
(executed in batches by an interpreter). Lenies die when their energy hits
zero; species emerge as clusters of identical or near-identical codeomes,
identified by a stable hash. The Programming Manual covers all of this from
the ground up.

**Selection** falls out of these mechanics without any explicit fitness
function. Codeomes that waste energy, fail to forage, or crash on common
mutations die out; codeomes that replicate cleanly and tolerate copy errors
slowly spread. Predators (Lenies whose codeomes invoke `:attack`) appear, and
herbivores evolve defences. There's no zero-sum scoreboard — just an ecosystem
you contribute to and watch.

---

## The Arena

At `/`. Anonymous and authenticated viewers see the same canvas on the left,
the same species data on the right:

- **The world canvas** — full-height, one coloured pixel per live Lenie,
  coloured by species. Scroll to zoom (anchored on the cursor), click-drag to
  pan, click a species row to highlight only that species on the map.
- **Sparkline + species table** — top-right, top-10 species over the last few
  minutes, plus the full active list scrolling beneath. Clicking a row opens
  an inline species inspector (read-only — editing happens in the Sandbox).
- **Presence count** — "N watching", updated live as viewers come and go.

The bottom-right control panel adapts to who you are:

- **Anonymous viewer**: a *"Log in to seed your Lenie in the Arena"* prompt
  with a link to the registration / login pages.
- **Logged in, empty collection**: a *"Save a codeome in your Sandbox first"*
  hint with a link to the editor.
- **Logged in, lineage = 0**: a dropdown of your saved codeomes + a **"Seed
  your Lenie"** button. Click and one Lenie spawns into the Arena, tagged with
  your `seeder_user_id`.
- **Logged in, lineage > 0**: *"Your lineage: N Lenies alive"* + an **"Apoptosis (N)"**
  destructive button (with a two-step confirm). Pressing it triggers a
  controlled die-off of all your descendants, freeing you to seed again.

The lineage tag propagates through replication: every child Lenie inherits
its parent's `seeder_user_id`. The Arena counts your living lineage by
scanning its `:lenies` ETS table with an `:ets.select` match spec; you can
seed again only when the count drops to zero (or you trigger Apoptosis).

The Arena lives only while at least one viewer is connected. When the last
viewer disconnects, a 30-second grace timer starts; if no one returns, the
Arena auto-snapshots to disk and stops. The next visitor restarts it and the
snapshot restores state — so the public ecosystem persists across visits
even when nobody's watching at 3 a.m.

---

## The Sandbox

At `/sandbox`. Behind login. Same world model as the Arena, but it's your
private lab — full control surface, spawn freely, tune anything, snapshot at
will. Intended for iteration: build a codeome in the editor, spawn it here,
watch it succeed or fail, iterate. When you're confident, seed it in the
Arena.

**On the world map (left, full-height):**

- **Scroll** zooms in and out, anchored on the cursor so the cell under the
  mouse stays put across the zoom.
- **Click and drag** pans the view (only meaningful once zoomed past 1×; at
  1× the whole grid is on screen).
- **Single click** on a cell recenters the view there.
- **Double click** on a cell with a Lenie opens the codeome editor for that
  species (cursor turns into a pointer over occupied cells to hint at this).
  Empty cells are a no-op.
- Three checkboxes under the map toggle the **Lenies / Resources /
  Detritus** layers independently.

**On the right column, top row:**

- The sparkline tracks the population of the top species over the last few
  minutes; one coloured line per species in the current top 10.
- The table beneath lists **every** active species (full count, scrolls
  vertically when there are many). Click a row to open the species inspector
  and highlight that species on the map — every other species is dimmed to
  30 % alpha.

**On the right column, bottom row:**

- **Pause / Resume** stops and restarts the environmental tick. The world
  freezes; the canvas stops updating.
- **Sterilize** kills every Lenie and resets the world to an empty grid. A
  confirm button appears to prevent accidents.
- **+ New Seed** opens the codeome editor with an empty buffer.
- **Manage** toggles the list of your saved codeomes so you can delete them.
- **Spawn** picks a seed from the dropdown (built-in or your own) and drops N
  copies into random free cells with a chosen starting energy.
- **Snapshot** saves and reloads the entire world state from disk, keyed by a
  name you choose.
- Under that, the **Tuning Live** section exposes runtime sliders for every
  per-world parameter — radiation, eat amount, copy-error rates, attack
  damage, the BG-mutation rate per 1000 ticks, and more. Changes apply
  immediately to all live Lenies in *your* Sandbox only; the Arena and other
  users' Sandboxes are unaffected.

The species inspector (slides in when you click a row) shows the species'
colour swatch, the codeome disassembled into coloured opcode blocks (one per
category), and Edit / Spawn buttons. Editing a species edits a *copy* — the
running Lenies of that species are untouched until you spawn your edited
version back into the world.

Auto-snapshot: when you close your last Sandbox tab, a 30-second grace timer
starts; if you don't reconnect, your Sandbox auto-snapshots to disk and
stops. When you come back, it auto-restores — so your work between sessions
persists without you having to think about it. Manual snapshots (via the
Snapshot form) coexist for named save points.

---

## The codeome editor

At `/sandbox/editor/new` (empty buffer) or `/sandbox/editor/edit/:hash`
(pre-loaded with an existing species' codeome).

A full-screen page with three panes. On the far left, a collapsible
**Programming Manual** for in-editor reference. In the middle, a palette of
all 36 opcodes grouped by category (drag a chip onto the listing to insert;
double-click a chip to append at end; or paste a space/comma-separated text
list into the input above and the editor tokenises it). On the right, the
current codeome rendered as a vertical stack of coloured blocks — one block
per opcode, in execution order. Drag the `≡` handle to reorder, click the
`⨯` to delete.

Above the listing, an **Energy / pass** mini-panel recomputes on every opcode
add / remove / reorder. It shows:

- `cost` — exact sum of per-opcode static costs for one linear pass through
  the buffer (template-jump lengths read from the run of nops following each
  jump; `:allocate` priced at the current buffer length as a typical-replicator
  proxy).
- `max gain` — strict upper bound assuming every `:eat` and `:attack` hits,
  using your Sandbox's live `eat_amount` and `attack_damage` tuning values.
- `net = max_gain - cost` colour-coded green / red.

A live validation banner tells you whether the current buffer is acceptable:
too short, too long, or with too few non-template opcodes will each block you
from spawning or saving. When the buffer is valid you can **Spawn** directly
into your Sandbox or **Save** as a named entry in your **personal collection**
(with a colour and a default starting energy). Saved codeomes persist in
Postgres scoped to your user; they appear with a star prefix in the spawn
dropdown of your Sandbox AND in the seed dropdown of the Arena.

The editor opens from the **+ New Seed** button (empty buffer), from the
**Edit** button on the species inspector (pre-loaded), and from a **double
click on a Lenie cell** on the Sandbox map.

For everything about *what* to put in those blocks — the VM, the opcodes,
template addressing, replication, the energy budget, and a worked tour through
seven hand-crafted codeomes of growing complexity — see the [Programming Manual](docs/manual/README.md).

---

## Further reading

- 📘 [Programming Manual](docs/manual/README.md) — from zero to writing your
  own sustainable replicator. Twelve chapters, ~4,200 lines of English text
  and worked examples. Includes a chapter-by-chapter dissection of the
  **Minimal Replicator** and notes on each of the five built-in seeds
  (Minimal Replicator, Carnivore, Defender, Hunter, Forager) available in
  your Sandbox.
- Built-in seed sources in [`lib/lenies/codeomes/`](lib/lenies/codeomes/) —
  readable Elixir modules; useful as concrete examples once you've read the
  manual's first few chapters.

---

## A note on the name

"Lenies" is a tribute to Peter Watts' *Rifters* trilogy (*Starfish*, *Maelstrom*,
*βehemoth*). In the books, the post-collapse internet — the **Maelstrom** —
is infested by self-replicating digital wildlife that evolves in the noise
between functioning systems. A particularly persistent strain learns to
propagate by riding the cultural meme of the trilogy's protagonist,
**Lenie Clarke**, and ends up nicknamed after her. The bytecode organisms in
this project are a much smaller, much friendlier homage: stack-machine
creatures eating and replicating inside a 256×256 toroidal grid instead of a
planetary network, but driven by the same minimal-replicator logic.
