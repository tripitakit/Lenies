# Lenies Programming Manual — Design Spec

**Date**: 2026-05-16
**Status**: Approved

## Goal

Write a comprehensive, programmer-friendly programming manual for Lenies
codeomes that takes a reader from zero (knows general programming
concepts but nothing about this VM, template addressing, or Lenies) to
"master" (can hand-write a sustainable replicator, factor code into
subroutines, and confidently extend any existing codeome with new
behaviour).

## Language

All prose, headings, code comments, diagrams, and Try-it boxes are in
**English**. The project is being migrated to all-English at the end
of the documentation work, so the manual assumes English source code
throughout — including the codeome listings it references in chapter
09 (the MinimalReplicator / Carnivore dissection).

## Audience and tone

- Reader knows what a stack, a loop, and a condition are.
- Reader does **not** know Elixir, Tierra-style template addressing, the
  Lenies VM, the codeome editor UI, or this project's conventions.
- No assumed knowledge of assembly. Every VM concept (instruction
  pointer, opcode dispatch, energy budget) is introduced from scratch
  the first time it appears.
- Style: didactic, conversational, never patronising. Analogies to
  common languages where helpful (Python `if/else`, C arrays for slots).

## Format

Multi-file book under `docs/manual/`. One `README.md` index page plus 11
chapter files numbered `00-10`. Each chapter is self-contained and
stands on its own, but reads best in order.

Listings use the project's existing codeome convention:

```elixir
[
  # ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──
  :nop_1, :nop_1, :nop_1, :nop_1,
  # ── pos 4..6: get own size N, store in slot[0] ──
  :get_size, :push0, :store,
  ...
]
```

Diagrams are ASCII. No binary images. Tables for opcode reference use
the `( before -- after )` stack-effect notation already used in the
project README.

Each chapter ends with a **Try it** box: 2–3 lines telling the reader
exactly which buttons to click in the codeome editor (drag chip X, then
Y, save as "name", spawn 1, watch the canvas).

## File layout

```
docs/manual/
├── README.md              — Index, how to read this manual, prerequisites
├── 00-introduction.md     — What is a Lenie, what is a codeome, the world it lives in
├── 01-vm-anatomy.md       — The execution state: ip, stack, slots, dir, energy, age, pos, call stack
├── 02-opcode-reference.md — All 36 opcodes with stack effect, cost, semantics
├── 03-first-codeome.md    — Walker (6 op): the simplest legal codeome
├── 04-loops-and-templates.md — Template addressing, jmp_t/jz_t/jnz_t. Forager (16 op)
├── 05-memory-and-arithmetic.md — Slots, constants, counters. Counter-walker (22 op), Turning forager (32 op)
├── 06-procedures.md       — call_t / ret, factoring code into subroutines. Subroutine forager (36 op)
├── 07-replication.md      — allocate / write_child / divide. Mini-replicator (~70 op), Sustainable replicator (~95 op)
├── 08-energy-economy.md   — Break-even math, copy-error tolerance, dimensioning forage cycles
├── 09-minimal-replicator.md — Annotated dissection of the built-in MinimalReplicator (121 op) and Carnivore
└── 10-cookbook.md         — Six recurring patterns/idioms with code snippets
```

## Chapter-by-chapter content

### README.md
Index linking each chapter. A short paragraph on "how to read this
manual" (linear vs. lookup), prerequisites (basic programming
concepts), and a "running the simulator locally" pointer to the
project's main README. ~80 lines.

### 00-introduction.md
- A Lenie is a process whose body and behaviour are determined by a
  byte-code program (its codeome).
- The world: 256×256 toroidal grid, resources, carcasses, radiation.
- One codeome = one program = one species (after hashing).
- Energy in, energy out: every opcode costs, every `:eat` pays.
- High-level view of the VM (stack-based, no registers in the
  traditional sense, four memory slots, a hardware-direction).
- ~150 lines.

### 01-vm-anatomy.md
- Detailed walk through `Lenies.Interpreter.State`: ip, stack (max 16,
  defensive pop returns 0), slots (4, wraps mod 4), dir (cardinal),
  energy (float, death at ≤ 0), age (per batch), pos, call_stack
  (max 32).
- Codeome as a **ring**: ip wraps modulo size, negative indices wrap.
- Execution loop: `step/2` dispatches one opcode, charges cost, advances
  ip. Three outcomes: `:cont`, `:wait_world`, `:halt`.
- Defensive semantics: unknown opcode → nop, pop on empty → 0, mod-by-0
  → 0, slot index wraps mod 4.
- Diagrams: stack push/pop ASCII art, ip walking the ring.
- ~250 lines.

### 02-opcode-reference.md
- All 36 opcodes grouped by the same 10 categories as the README:
  template, stack, arithmetic, control flow, sense-local, sense-world,
  orientation, action-world, predation, self-inspection, replication,
  memory.
- For each opcode: name, stack effect `( before -- after )`, cost
  formula, plain-English description, edge-case notes, 1-line example
  use. Where useful, cross-reference to the chapter that uses it for
  the first time.
- A "world-yielding" table at the end listing the opcodes that cause
  `wait_world` and what world action they emit.
- ~350 lines.

### Note on opcode counts

The counts in chapter headings below (Walker 6 op, Forager 16 op, …)
are **target sizes** rather than commitments. Templates and anchors
push the actual op-count up or down by a handful depending on layout
choices (2-bit vs 4-bit templates, separator insertion, etc). Each
chapter's code listing will be the *exact* working codeome with its
actual op-count reflected in the heading. The progressive ordering
(each example is bigger than the last) is the invariant.

### 03-first-codeome.md
**Walker (~7 ops)** — moves north, eats if it can, loops forever.

```elixir
[
  :nop_0,        # 0  LOOP_HEAD anchor
  :sense_front,  # 1  (we ignore the result, but pay the cost — a useful pattern)
  :drop,         # 2
  :eat,          # 3
  :move,         # 4
  :jmp_t, :nop_1 # 5..6  jmp to nop_1's complement, i.e. nop_0 at position 0
]
```

Walks the reader through every line, explains the anchor/template
mechanic informally (saves the deep dive for chapter 04). Highlights
the validation gate: minimum 5 ops, minimum 10 non-nops — this codeome
is below threshold, padding strategies are introduced (cheap `:push0`s
in dead code) so it can be saved as a custom seed.

**Note**: the canonical walker shown above is below the project's
`min_viable_codeome_opcodes` threshold of 10 non-nops. The chapter
shows the padded variant first (immediately usable in the editor) and
the bare-bones variant as a "conceptual" listing.

~250 lines.

### 04-loops-and-templates.md
Deep dive into template addressing:

- Templates are the consecutive run of `:nop_0`/`:nop_1` following a
  jump opcode, capped at `template_max_len = 8`.
- The jump searches for the **bit-flipped complement** of that
  template, forward first (radius 256), then backward.
- If found, ip lands immediately **after** the matched complement; if
  not, fall through past the template.
- Anchors are named by their bit pattern (e.g. `[n1, n1, n1, n1]` for
  LOOP_HEAD).
- Why separators (`:push0` between adjacent anchors) matter: the
  template extractor is greedy.

**Forager (16 ops)** — uses `:jz_t` to branch on the front-cell sense
value. If empty, jumps to a "TURN" anchor; otherwise eats and moves.
Full annotated listing.

Stack-effect tracing for conditional jumps: pop happens before search,
even if condition fails (this is a subtle point worth a paragraph).

~400 lines.

### 05-memory-and-arithmetic.md
Two examples in one chapter because slots and counters are the same
mental model (load/store, increment, compare-to-zero).

**Counter-walker (22 ops)** — walks N=8 steps then turns right, forever.
Introduces:
- `:store` pops slot index THEN value (mind the order).
- `:load` pops slot index, pushes value.
- Constant-building idiom: `push1; dup; add; dup; add; dup; add` →
  push 8.
- Decrement-and-test loop: `load; push1; sub; store; load; jnz_t →
  back`.

**Turning forager (32 ops)** — extends the forager from chapter 04
with a periodic random turn. Introduces:
- `:pushN` for randomness (uniform 0..255).
- `:mod 2` for fair coin.
- Branching with `:jz_t` on the coin to choose `turn_left` vs
  `turn_right`.

Each opcode count is exact; the chapter ends with a "save it, spawn 5,
watch the colour swatch" Try-it.

~450 lines.

### 06-procedures.md
The VM has no `def` keyword, but `call_t` + `ret` give you the
equivalent of a subroutine. Chapter explains:

- `call_t` reads its own template, pushes the return-ip onto the call
  stack, jumps to the complement.
- `ret` pops the call stack and resumes.
- Naming convention: anchors named after the procedure they enter
  (`EAT_THEN_MOVE`, `RANDOM_TURN`).
- Call stack is 32 deep — deep recursion is possible but expensive.
- Costs: `call_t` and `ret` are `0.2 + 0.05 × template_len`. A short
  procedure with template_len=4 costs `0.4` to enter, `0.2` to leave
  — comparable to inline duplication once you call it twice.

**Subroutine forager (36 ops)** — refactor of chapter 04's forager: the
`drop; eat; move` sequence is moved into an EAT_THEN_MOVE procedure
called from two places (the eat branch and the turn-then-move branch).
Code shrinks from 16 to 14 in the caller, +6 in the procedure, total
~36 with anchors and templates. The chapter is explicit that you don't
always want a procedure — calling has overhead. Rule of thumb: factor
out if called ≥ 2 times.

~400 lines.

### 07-replication.md
The big chapter. The three replication opcodes form a protocol:

1. `allocate` — ask the world for a child slot of size N in the front
   cell. Pop N from stack. The world records this for the next
   `write_child`. Reply via stack is `:ok` (a 1) or `:no_target` (a 0).
2. `write_child` — pop opcode_int, pop child_addr. Writes the opcode
   into the pending buffer at `child_addr mod N`. Copy errors happen
   here probabilistically.
3. `divide` — commit: spawn the child Lenie, give it half the parent's
   remaining energy.

**Mini-replicator (~70 ops)** — naive, one-shot:
1. Get own size.
2. Allocate.
3. Loop: read_self at counter, write_child at counter, increment,
   loop while counter ≠ N.
4. Divide.
5. After divide, fall through to a `halt-equivalent` (an infinite
   no-op loop that drains energy). This is intentional — shows why
   you need step 6.

**Sustainable replicator (~95 ops)** — adds a forage cycle between
divisions:
6. After divide, turn (random L/R to dodge the blocking child).
7. Build counter K=64 with `push1; dup; add` × 6.
8. Forage loop: `sense_front; drop; eat; move; counter -= 1; jnz_t
   back`.
9. Jump back to step 1.

This is the same skeleton as `Lenies.Codeomes.MinimalReplicator` but
without the niceties (no jz_t on allocate failure → less mutation-
robust). Chapter 09 will dissect MinimalReplicator and explain those
robustness additions.

~600 lines.

### 08-energy-economy.md
Pure analysis chapter. No new codeomes; instead, math:

- Per-cycle cost of the sustainable replicator from chapter 07.
- Per-cycle gain from `K` forage iterations.
- Break-even condition for `eat_amount` and per-cell resource density.
- Why the MinimalReplicator picks K=128 specifically (cost amortisation
  over the 121-op copy).
- Copy-error robustness: rates of `:write_child` substitution / insert
  / delete, expected drift per generation, why short programs evolve
  slower (and why naïve replicators die out in mutation regimes).
- A short formula box deriving steady-state energy `E_new = E_old/2 +
  K · (gain − cost)`.

~250 lines.

### 09-minimal-replicator.md
Section-by-section dissection of the actual
`Lenies.Codeomes.MinimalReplicator` from
`lib/lenies/codeomes/minimal_replicator.ex`. The moduledoc there is
already a tutorial — this chapter expands it line-by-line and connects
each block to the relevant earlier chapter (e.g. "the random-turn
block is the pattern you learned in chapter 05").

Then a short addendum dissecting `Carnivore` — same body with `:attack`
injected before `:eat`. Discusses predation cost/benefit and why
carnivores are not strictly dominant.

~400 lines.

### 10-cookbook.md
Six patterns, each ~50 lines: title, when to use, code snippet,
discussion.

1. **Constant builder** — `push1; dup; add; …` doubling chain. Build
   any power of 2 in `log2(N)` ops at cost `~0.1 · log2(N)`.
2. **Random branch 50/50** — `pushN; push1; push1; add; mod` (= `mod
   2`), then `jz_t`.
3. **Defensive front sense** — `sense_front; drop` to pay the cost
   without consuming the value, deliberately discarding the
   information when you only need the `wait_world` side effect.
4. **Slot-based counter loop** — store init, decrement-test-jump, exit
   when zero. The canonical pattern from chapter 05, restated as a
   reusable snippet.
5. **Anchor + separator placement** — when two anchors are adjacent
   across the ring wrap, insert a `:push0` separator to stop the
   template extractor from over-reading.
6. **Skeleton copy loop** — bare-bones replication pattern from
   chapter 07, presented as a fillable template (`# YOUR FORAGE GOES
   HERE`) so the reader can use it as a starting point for their own
   replicator.

~350 lines.

## Validation gates the manual will explain

The codeome editor enforces three constraints, and the manual repeats
them at every example:
- Length in `5..500` opcodes.
- At least 10 non-nop opcodes.
- Every opcode in the 36-entry whitelist.

The walker in chapter 03 is below the non-nop threshold; the chapter
shows how to pad it.

## Out of scope

- Internal Elixir API or how to add new opcodes (the manual is for
  *users* of the existing opcode set, not maintainers of the VM).
- Evolutionary biology theory (mutations, drift, species formation
  beyond what's needed to write working code).
- World-tuning parameters (radiation rate, decay, hotspots) — these
  are environment knobs, not programmer knobs.
- Detailed scientific references / further reading (the `README.md` of
  the project links the design spec).

## File-size budget

Total ~3300 lines of Markdown across 12 files, with single chapters
between 80 (README index) and 600 (replication chapter) lines. Every
chapter is self-contained: skimming chapter 06 should make sense to a
reader who hasn't read 04, with a one-line back-reference to the
prior chapter where helpful.

## Test plan

Documentation has no automated tests, but the manual must be
**executable** in spirit: every code listing must be a real codeome
that you can paste into the editor and spawn. Verification:

1. Manually paste each numbered codeome (walker, forager, counter-
   walker, turning forager, subroutine forager, mini-replicator,
   sustainable replicator) into the editor's "+ New Seed" and spawn
   1 with 10 000 energy on an empty world. Each must behave as the
   manual describes (does not crash on validation, does not
   immediately die, exhibits the documented behaviour for ≥ 30
   seconds).
2. For each opcode listed in the reference chapter, cross-check
   `lib/lenies/codeome/opcodes.ex` (whitelist), `lib/lenies/codeome/
   costs.ex` (cost), and `lib/lenies/interpreter.ex` (semantics).
   Any mismatch is a bug in the manual.
3. The MinimalReplicator dissection in chapter 09 must match the
   actual file byte-for-byte (positions, anchors, separators); the
   manual references positions, so any drift in the source means the
   chapter is stale.
