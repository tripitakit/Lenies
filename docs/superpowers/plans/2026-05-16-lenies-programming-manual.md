# Lenies Programming Manual Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write a multi-file English programming manual that takes a reader from zero to "master" of writing Lenies codeomes — VM model, full opcode reference, a didactic pyramid of seven hand-crafted codeomes of increasing complexity, an analytical chapter on energy economy, a dissection of the built-in MinimalReplicator and Carnivore, and a cookbook of recurring idioms.

**Architecture:** One Markdown file per chapter under `docs/manual/`, plus an index `README.md`. No code production; only documentation. Every code listing must be a valid, paste-into-editor codeome — verification is by manual smoke test, not automated.

**Tech Stack:** Markdown (CommonMark / GitHub-flavoured). Code listings in fenced ` ```elixir ` blocks. ASCII diagrams. No images, no JS.

**Spec:** `docs/superpowers/specs/2026-05-16-lenies-programming-manual.md` — full chapter-by-chapter requirements live there. Each task below references the spec section it implements.

---

## File map

All new, all under `docs/manual/`:

```
docs/manual/
├── README.md              — Index + how to read this manual
├── 00-introduction.md     — What a Lenie is; the world; high-level VM
├── 01-vm-anatomy.md       — Execution state in detail; the ring; semantics
├── 02-opcode-reference.md — All 36 opcodes, grouped by category
├── 03-first-codeome.md    — Walker
├── 04-loops-and-templates.md — Template addressing; Forager
├── 05-memory-and-arithmetic.md — Slots; Counter-walker; Turning forager
├── 06-procedures.md       — call_t/ret; Subroutine forager
├── 07-replication.md      — allocate/write_child/divide; Mini-replicator; Sustainable replicator
├── 08-energy-economy.md   — Break-even math; copy-error tolerance
├── 09-minimal-replicator.md — Dissection of the built-in MinimalReplicator + Carnivore
└── 10-cookbook.md         — Six recurring patterns
```

---

## Pre-task: create the manual directory

- [ ] **Step P.1: Create the directory**

```bash
mkdir -p /home/patrick/projects/playground/Lenies/docs/manual
```

(Each chapter task below creates one file in this directory. The directory itself has no `.gitkeep`; the first chapter file committed will register it.)

---

## Task 1: 00-introduction.md

**Files:**
- Create: `docs/manual/00-introduction.md`

**Spec reference:** Section `00-introduction.md` of the design spec.

- [ ] **Step 1.1: Write the chapter**

Create `docs/manual/00-introduction.md`. Target ~150 lines. Required contents (in this order):

1. **What is a Lenie?** A digital organism whose body and behaviour are entirely determined by its codeome (a sequence of opcodes). Each Lenie is a BEAM process registered in a Registry; this is invisible to the codeome writer but useful context for "why does my Lenie sometimes get killed unexpectedly" (max heap size).
2. **What is a codeome?** A list of atoms from a whitelist of 36 opcodes. It is BOTH the program (executed by the VM) AND the genome (mutated and copied during replication). The same sequence always hashes to the same species ID via `:erlang.phash2`.
3. **The world.** 256×256 toroidal grid (wraps at the edges). Cells hold either nothing, a resource amount, a carcass, or a Lenie. Radiation injects resources every tick. Carcasses decay.
4. **Energy in, energy out.** Every opcode costs a fraction of energy. The only way to gain energy is `:eat` on a cell that has resource or carcass. Death at energy ≤ 0.
5. **The VM in one paragraph.** Stack-based (16-deep, wrap drop), 4 named memory slots, instruction pointer that wraps mod codeome size (so a codeome is a ring), 4 cardinal directions, no labels in source (template addressing instead).
6. **What this manual will teach you.** Brief outline of the seven hand-crafted codeomes the reader will build, and the dissection of MinimalReplicator at the end.
7. **Prerequisites.** General programming concepts (stack, loop, condition). No Elixir, no assembly, no Tierra background assumed.

Write in plain English, conversational tone. Refer the reader to the top-level project README for setup instructions. Do NOT include opcode tables here — that is chapter 02's job. End the chapter with a one-line pointer: "→ Next: Chapter 1, The VM Anatomy."

- [ ] **Step 1.2: Verify line count and links**

```bash
wc -l docs/manual/00-introduction.md
grep -n "^#" docs/manual/00-introduction.md
```

Expected: file exists, between 100 and 200 lines, has a top-level `# ` heading and 2–5 `## ` subheadings.

- [ ] **Step 1.3: Commit**

```bash
git add docs/manual/00-introduction.md
git commit -m "docs(manual): 00 — introduction to Lenies and the world"
```

---

## Task 2: 01-vm-anatomy.md

**Files:**
- Create: `docs/manual/01-vm-anatomy.md`

**Spec reference:** Section `01-vm-anatomy.md` of the design spec.

- [ ] **Step 2.1: Read the source of truth**

Before writing, read the canonical interpreter state struct so the description is accurate:

```bash
cat /home/patrick/projects/playground/Lenies/lib/lenies/interpreter/state.ex
cat /home/patrick/projects/playground/Lenies/lib/lenies/interpreter.ex | head -60
```

- [ ] **Step 2.2: Write the chapter**

Target ~250 lines. Required contents (in this order):

1. **The execution state.** Table of fields with type and meaning:
   - `ip` — non-negative integer; wraps mod codeome size
   - `stack` — list of integers, top is head, max 16 (pushing beyond drops oldest)
   - `slots` — map `%{0 => 0, 1 => 0, 2 => 0, 3 => 0}`; index wraps mod 4
   - `dir` — `:n | :e | :s | :w`
   - `energy` — float, death at ≤ 0
   - `age` — incremented once per K-instruction batch
   - `pos` — `{x, y}`
   - `call_stack` — list of return ips, max 32

   For each field, one paragraph on what it means and how it changes.

2. **The codeome as a ring.** ASCII diagram (a 12-cell ring, ip arrow at one position). Explain wrap, negative indices, and why this matters for template search across the wrap boundary.

3. **The execution loop.** Pseudocode of `step/2`:
   ```
   if codeome is empty:    halt(:empty_codeome)
   op = codeome[ip]
   dispatch op:
     stack/arithmetic     -> mutate stack, charge cost, ip++, return :cont
     control flow         -> mutate ip and call_stack, charge cost, return :cont
     sense_local/self     -> push self-state, charge cost, ip++, return :cont
     sense_world/action   -> charge cost, ip++, return :wait_world (world call needed)
     unknown              -> treat as :nop_0
   if energy ≤ 0 after charge: halt(:starvation)
   ```

4. **Three outcomes.** `:cont`, `:wait_world`, `:halt`. What each means and which opcodes produce each. Table.

5. **Defensive semantics.** A bulleted list with one line each:
   - Empty stack pop returns 0.
   - mod 0 returns 0.
   - Slot index wraps mod 4.
   - Unknown opcode → nop_0.
   - Failed template search → fall through past the template.
   - ret on empty call stack → fall through.

   Stress that mutations therefore never produce syntax errors; the worst they can do is waste energy.

6. **Stack push/pop diagrams.** ASCII art for `push 5`, then `push 7`, then `swap`, then `pop`. Four little box-stacks side by side, top labelled `← top`.

7. **One-line forward pointer:** "→ Chapter 2 enumerates every opcode in the VM."

- [ ] **Step 2.3: Verify**

```bash
wc -l docs/manual/01-vm-anatomy.md
```

Expected: 200–300 lines.

- [ ] **Step 2.4: Commit**

```bash
git add docs/manual/01-vm-anatomy.md
git commit -m "docs(manual): 01 — VM anatomy and execution model"
```

---

## Task 3: 02-opcode-reference.md

**Files:**
- Create: `docs/manual/02-opcode-reference.md`

**Spec reference:** Section `02-opcode-reference.md` of the design spec.

- [ ] **Step 3.1: Read the source-of-truth files**

```bash
cat /home/patrick/projects/playground/Lenies/lib/lenies/codeome/opcodes.ex
cat /home/patrick/projects/playground/Lenies/lib/lenies/codeome/costs.ex
cat /home/patrick/projects/playground/Lenies/lib/lenies_web/disassembler.ex | head -55
```

This gives the authoritative whitelist, costs, and category mapping.

- [ ] **Step 3.2: Write the chapter**

Target ~350 lines. Required contents:

1. **Notation primer.** A short paragraph explaining the stack-effect notation `( before -- after )`, with one or two simple examples (e.g. `push0   ( -- 0 )`, `add ( b a -- b+a )`).

2. **The 10 categories.** A table with category name, count, brief purpose, jump to subsection:

   | Category | Count | Purpose |
   |---|---|---|
   | Template / no-op | 2 | Encode anchors and template values |
   | Stack | 6 | Manipulate values |
   | Arithmetic | 4 | Integer math |
   | Control flow | 5 | Branching, calls, returns |
   | Sense (local) | 4 | Read self-state |
   | Sense (world) | 1 | Query a cell |
   | Orientation | 2 | Rotate dir |
   | Action (world) | 2 | Move, eat |
   | Predation | 2 | Attack, defend |
   | Self-inspection | 3 | Read own codeome |
   | Replication | 3 | Allocate / write / divide |
   | Memory | 2 | Slot store / load |

   (= 36 total; verify the count when writing.)

3. **For each opcode**, in category order, a short subsection. Heading is the opcode name in code font. Inside: stack-effect line, cost line, one-paragraph description, edge-case notes (if any).

   Example entry shape:

   ```markdown
   ### `push1`

   **Stack:** `( -- 1 )`
   **Cost:** 0.1
   **Description:** Push the integer 1 onto the stack. Together with `dup` and `add`, used to build any power-of-2 constant in `log2(N)` operations — see the cookbook for the idiom.
   ```

   Be terse. The reference chapter is for lookup, not narrative. Cross-references to later chapters are encouraged (e.g. "see chapter 06 for `call_t`'s use in subroutines").

4. **World-yielding table at the end.** A small table listing the opcodes that produce `:wait_world` and which `World.action/1` form they emit. Use the exact action shapes from `lib/lenies/world.ex` lines 35–41 (`{:sense_front, pos, dir}`, `{:move, pos, dir}`, `{:eat, pos}`, `{:attack, pos, dir}`, `:defend`, `{:allocate, n, pos, dir}`, `{:write_child, opcode_int, addr}`, `{:divide, energy, pos, dir}`).

5. **One-line forward pointer:** "→ Chapter 3 puts the first few opcodes to work."

- [ ] **Step 3.3: Cross-check every cost and stack effect**

For every opcode entry, the cost in the chapter must match `lib/lenies/codeome/costs.ex`. Read costs.ex once before writing; if anything in the chapter draft disagrees, fix the chapter (the source is authoritative).

- [ ] **Step 3.4: Verify**

```bash
wc -l docs/manual/02-opcode-reference.md
grep -cE "^### `" docs/manual/02-opcode-reference.md
```

Expected: 300–400 lines; exactly 36 opcode subsection headings.

- [ ] **Step 3.5: Commit**

```bash
git add docs/manual/02-opcode-reference.md
git commit -m "docs(manual): 02 — full opcode reference"
```

---

## Task 4: 03-first-codeome.md (Walker)

**Files:**
- Create: `docs/manual/03-first-codeome.md`

**Spec reference:** Section `03-first-codeome.md` of the design spec.

- [ ] **Step 4.1: Construct the canonical Walker codeome**

The Walker walks north, eats, and loops forever via `jmp_t` back to a single-nop anchor. Use a 1-bit template (single `:nop_1` as the template, complemented to `:nop_0` for the anchor). Skeleton (8 ops):

```elixir
[
  :nop_0,        # 0 — LOOP_HEAD anchor (bit 0)
  :sense_front,  # 1
  :drop,         # 2
  :eat,          # 3
  :move,         # 4
  :jmp_t,        # 5
  :nop_1         # 6 — template (bit 1); search complement (nop_0) finds pos 0
]
```

Plus you need a SEPARATOR between the template at pos 6 and the anchor at pos 0 across the wrap. Because the template extractor reads up to 8 nops greedily, having nop_1 at 6 adjacent to nop_0 at 0 across the ring gives `[nop_1, nop_0]` as the extracted template (2 bits), and its complement is `[nop_0, nop_1]` — which doesn't match anything reliably. **So the canonical Walker is actually:**

```elixir
[
  :nop_0,        # 0 — LOOP_HEAD anchor (1-bit pattern: [0])
  :sense_front,  # 1
  :drop,         # 2
  :eat,          # 3
  :move,         # 4
  :jmp_t,        # 5
  :nop_1,        # 6 — template (1-bit: [1])
  :push0         # 7 — separator across the wrap (also pads the non-nop count)
]
```

Verify by manual VM trace: starting at ip=0, executing nop_0 advances to ip=1 (no effect). 1..4 run normally. At ip=5, `jmp_t` reads positions 6+ for the template until it hits a non-nop: it reads `nop_1`, stops at the `push0` at pos 7. Template = `[nop_1]` (1 bit). Complement = `[nop_0]`. Search forward from pos 6 wrapping: pos 7 (`push0` — no match), pos 0 (`nop_0` — match!). Target ip = 0 + 1 = 1, i.e. just after the matched complement nop_0. So we land back at `sense_front`. The `nop_0` anchor at pos 0 is conceptually the loop head but execution actually re-enters at pos 1 (which is fine — the anchor's job is to be findable, not to be executed). Cost of `jmp_t` with template_len=1: `0.2 + 0.05 = 0.25`. Length 8, non-nops 6 — STILL below the 10-non-nop validation gate.

**Therefore the Walker presented in this chapter is shown twice**:

(a) **Conceptual** — the 8-op listing above, used to teach the loop structure.

(b) **Editor-usable / padded** — pad to ≥ 10 non-nops by adding cheap no-effect ops in dead code (after the jmp_t template). Working padding: add four `:push0; :drop` pairs after pos 7 (still unreachable because the jmp lands before them):

```elixir
[
  :nop_0,        # 0 LOOP_HEAD
  :sense_front,  # 1
  :drop,         # 2
  :eat,          # 3
  :move,         # 4
  :jmp_t,        # 5
  :nop_1,        # 6
  :push0,        # 7 — separator + padding (dead code)
  :push0, :drop, :push0, :drop, :push0, :drop, :push0, :drop  # 8..15 — padding
]
```

Length 16, non-nops 14 — passes validation. Verify in the editor before declaring the chapter complete.

- [ ] **Step 4.2: Write the chapter**

Target ~250 lines. Required contents:

1. **The goal**: build the smallest codeome that does anything useful (move + eat in a loop).
2. **The conceptual listing** (8 ops) with line-by-line commentary. Each comment explains exactly what the opcode does and why it's there.
3. **An informal explanation of the loop mechanic.** "We don't write `goto loop:` like in BASIC. The VM searches the codeome for a matching pattern. Chapter 4 explains this in depth; for now, accept that `jmp_t` followed by `nop_1` means: jump to wherever the code has a `nop_0`."
4. **A short stack-trace** (3 or 4 ticks of execution) shown as an ASCII table: column per cycle, rows for ip, stack, energy, dir. The stack stays empty here; the trace mostly shows ip and energy.
5. **The validation gate.** Reproduce the bounds (length 5..500, ≥ 10 non-nops). Show why the conceptual 8-op version FAILS validation. Introduce the **padding strategy**: cheap ops in dead code after the jump target. Show the 16-op padded version.
6. **Try it.** Step-by-step:
   1. Click "+ New Seed".
   2. Drag opcodes from the palette in the exact order of the padded listing.
   3. Verify the dirty indicator says `(16 ops, 14 non-nop)`.
   4. Save as `walker-v1` with the default colour.
   5. From the controls panel, select your saved seed and spawn 1 with 10 000 energy.
   6. Watch the canvas — a coloured dot should walk north and disappear when it dies or reaches the edge (toroidal wrap means it'll come back).
7. **One-line forward pointer:** "→ Chapter 4 explains how `jmp_t` actually finds its target."

- [ ] **Step 4.3: Verify the codeome works**

Manually paste the padded listing into the in-app editor (dev server on http://localhost:4001), validate, spawn 1 with 10 000 energy, watch for at least 30 seconds. The Lenie should be visibly moving north and not crashing on validation.

- [ ] **Step 4.4: Commit**

```bash
git add docs/manual/03-first-codeome.md
git commit -m "docs(manual): 03 — the Walker, first working codeome"
```

---

## Task 5: 04-loops-and-templates.md (Forager)

**Files:**
- Create: `docs/manual/04-loops-and-templates.md`

**Spec reference:** Section `04-loops-and-templates.md` of the design spec.

- [ ] **Step 5.1: Read the template-addressing implementation**

```bash
cat /home/patrick/projects/playground/Lenies/lib/lenies/interpreter/template.ex
```

Note specifically: `template_max_len = 8` (default), `template_search_radius = 256`, and the "search forward then backward" semantics.

- [ ] **Step 5.2: Construct the Forager codeome**

The Forager senses the front cell, branches on the result, eats+moves if the cell has resource, otherwise turns. Uses two 4-bit anchors (LOOP_HEAD and TURN). Template max len = 8, so 4-bit templates are safe with simple separators.

```elixir
[
  # ── 0..3  LOOP_HEAD anchor [0,0,0,0] ─────────────────────────
  :nop_0, :nop_0, :nop_0, :nop_0,
  # ── 4..7  sense front cell; result on stack ──────────────────
  :sense_front,
  # ── 5..9  jz_t to TURN [1,1,1,1] anchor (template [0,0,0,0]? no, anchor TURN must complement the template here) ──
  # We want: jz_t reads template [1,1,1,1], searches its complement [0,0,0,0],
  # which is the LOOP_HEAD — wrong. So TURN's anchor should be [1,1,1,1] and
  # the jz_t template should also be [1,1,1,1]? No: jz_t's template complements
  # to find the target's anchor. So template [0,0,0,0] complements to [1,1,1,1].
  # We use template [0,0,0,0] for jz_t, anchor TURN = [1,1,1,1].
  # But LOOP_HEAD already uses [0,0,0,0] — meaning jz_t's template would actually
  # match LOOP_HEAD's bit pattern. We must distinguish via complementarity:
  # the SEARCH is for the COMPLEMENT, so template [0,0,0,0] searches [1,1,1,1].
  # So LOOP_HEAD anchor [0,0,0,0] is found by templates that ARE [1,1,1,1].
  # And TURN anchor [1,1,1,1] is found by templates that ARE [0,0,0,0].
  # So we encode: jmp_t back to LOOP_HEAD uses template [1,1,1,1].
  #               jz_t  to   TURN       uses template [0,0,0,0].
  :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,
  # ── 10  eat the cell ────────────────────────────────────────
  :eat,
  # ── 11  move forward ────────────────────────────────────────
  :move,
  # ── 12..17  jmp_t back to LOOP_HEAD; template [1,1,1,1] ─────
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,
  # ── 17 separator — prevents the next anchor's nops from being read as part of the template ──
  :push0,
  # ── 18..21 TURN anchor [1,1,1,1] ───────────────────────────
  :nop_1, :nop_1, :nop_1, :nop_1,
  # ── 22 turn right ──────────────────────────────────────────
  :turn_right,
  # ── 23..27 jmp_t back to LOOP_HEAD; template [1,1,1,1] ─────
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1
]
```

Length 28 (count by hand at writing time and adjust). Non-nops: `sense_front, jz_t, eat, move, jmp_t, push0, turn_right, jmp_t` = 8 — still below 10. Pad by adding two `push0; drop` pairs at the end (dead code after the final jmp). Final ~32 ops, 12 non-nops.

When writing this chapter, **count by hand and update the heading to match**. The heading should say "Forager (XX ops)" with the exact count.

- [ ] **Step 5.3: Write the chapter**

Target ~400 lines. Required contents:

1. **Template addressing, in depth.** Open with a worked example: the reader sees `jmp_t` followed by `nop_1`. They learn: the extractor reads forward from after the jump opcode, collecting consecutive nops into a "template" (max 8). It then flips each bit (nop_0 ↔ nop_1) to get the search target, and scans the codeome forward up to 256 positions, then backward up to 256, for that pattern.
2. **The bit-pattern naming convention.** Anchors and templates are described as bit strings: `[0,0,0,0]` for four consecutive `nop_0`s, etc. Use this consistently.
3. **Separators.** Explain why you need a non-nop between two adjacent template/anchor runs. Example: if `jmp_t [n0 n0]` is immediately followed by `nop_0 nop_1` (an anchor), the extractor reads `[n0 n0 n0 n1]` as the template, not `[n0 n0]`. A `:push0` between them breaks the run.
4. **Conditional jumps.** `jz_t` pops the stack BEFORE deciding. If `top == 0`, perform the jump; else fall through. Same for `jnz_t` (jump if non-zero). `jmp_t` is unconditional. Costs are all `0.2 + 0.05 × template_len`.
5. **The Forager listing.** Section-by-section commentary. Walk through what each section does and why the template/anchor pair was chosen.
6. **Conditional pop subtlety.** Stress that `jz_t` pops the stack regardless of whether the jump fires. Some readers forget this and end up with stack underflows in subsequent code.
7. **Try it.** Editor steps. Spawn on a world with abundant resources (default), watch for 60s. Compare with the walker: the forager visibly responds to terrain.
8. **One-line forward pointer:** "→ Chapter 5 introduces local memory and the loop-with-counter idiom."

- [ ] **Step 5.4: Verify the codeome works**

Paste into editor, validate, spawn, observe. The Lenie should turn when it can't eat — visible as a "wandering" rather than "stuck moving straight" behaviour.

- [ ] **Step 5.5: Commit**

```bash
git add docs/manual/04-loops-and-templates.md
git commit -m "docs(manual): 04 — template addressing and the Forager"
```

---

## Task 6: 05-memory-and-arithmetic.md (Counter-walker, Turning forager)

**Files:**
- Create: `docs/manual/05-memory-and-arithmetic.md`

**Spec reference:** Section `05-memory-and-arithmetic.md` of the design spec.

- [ ] **Step 6.1: Construct Counter-walker**

Walks N steps then turns right, forever. N = 8 (an easy power of 2 to build).

```elixir
[
  # ── 0..3 INIT_HEAD anchor [0,0,0,0] ─────────────
  :nop_0, :nop_0, :nop_0, :nop_0,
  # ── 4..10 build N=8 on the stack: push1; dup; add; dup; add; dup; add ──
  :push1, :dup, :add, :dup, :add, :dup, :add,
  # ── 11..12 store 8 in slot[0] ───────────────────
  :push0, :store,
  # ── 13..16 STEP_HEAD anchor [1,1,1,1] ───────────
  :nop_1, :nop_1, :nop_1, :nop_1,
  # ── 17..18 eat and move ─────────────────────────
  :eat, :move,
  # ── 19..23 counter -= 1 (slot[0]) ───────────────
  :push0, :load, :push1, :sub, :push0, :store,
  # actually that's 6 atoms — let me re-count
  # ...
]
```

When writing, count exactly and put the actual count in the heading. The decrement-and-test pattern is: load slot 0 → `push1; sub` → store back into slot 0 → load slot 0 again → `jnz_t` to STEP_HEAD (still positive) OR fall through to a TURN block that does `turn_right` then jumps back to INIT_HEAD.

Aim for ~22 ops. Pad if below 10 non-nops.

- [ ] **Step 6.2: Construct Turning forager**

Extends the chapter 04 Forager by replacing the unconditional `turn_right` with a random L/R choice.

Replace pos 22 (`turn_right`) in the chapter-04 listing with this 5-op block:

```elixir
# ── R..R+4  random branch: pushN, push1, push1, add, mod  → top is 0 or 1 ──
:pushN, :push1, :push1, :add, :mod,
# ── R+5..R+9 jz_t to TURN_LEFT anchor [0,1,0,1] ──
:jz_t, :nop_0, :nop_1, :nop_0, :nop_1,
# ── R+10 turn_right (executed when random was 1) ──
:turn_right,
# ── R+11..R+15 jmp_t to AFTER_TURN anchor [0,0,1,0] ──
:jmp_t, :nop_0, :nop_0, :nop_1, :nop_0,
# ── separator + TURN_LEFT anchor [1,0,1,1] + turn_left ──
:push0,
:nop_1, :nop_0, :nop_1, :nop_1,  # anchor that the jz_t complement [1,0,1,0] should find? double-check
:turn_left,
# ── AFTER_TURN anchor [1,1,0,1] ──
:nop_1, :nop_1, :nop_0, :nop_1,
# ── jmp_t back to LOOP_HEAD ──
:jmp_t, :nop_1, :nop_1, :nop_1, :nop_1
```

The exact anchor bit patterns must complement the jz_t and jmp_t templates correctly — work this out when writing, with the bit-flip rule in front of you. Total length ~32 ops.

- [ ] **Step 6.3: Write the chapter**

Target ~450 lines. Required contents:

1. **Why slots and constants.** Most non-trivial codeomes need a counter, an index, or a constant. Slots give you 4 named registers; arithmetic and stack ops let you compute and store.
2. **Slot semantics.** `:store` pops slot_index (top), then pops value, writes `slots[slot_index] = value`. **Mind the order** — many beginners flip it. `:load` pops slot_index, pushes `slots[slot_index]`. Slot index wraps mod 4, so any integer is a valid index.
3. **Constant building.** The doubling chain: `push1; dup; add` to get 2, then `dup; add` to get 4, and so on. Cost analysis: 7 ops total to build 128 (`push1` + 7 × `dup;add`), so ~1.5 energy. Compare with `pushN` which gives an unpredictable value.
4. **Counter-walker listing.** Full code, line by line. Highlight the decrement-test pattern.
5. **Stack trace for the decrement loop.** Show 3 iterations as a table.
6. **Random branches.** Introduce `pushN` (random 0..255), then `push1; push1; add` to get 2 on the stack, then `mod` for a fair coin. **Note:** `mod` pops `a` (top) then `b`, pushes `b mod a`. So `2 mod 5` requires `push 5; push 2; mod` (b=5, a=2, result=5 mod 2 = 1). Get this right in the chapter — beginners flip it.
7. **Turning forager listing.** Full code, line by line. Show the random-coin block clearly.
8. **Try it.** Save both as separate seeds. Spawn 5 of each, watch their paths trace different shapes (counter-walker draws a square spiral; turning forager wanders).
9. **One-line forward pointer:** "→ Chapter 6 introduces subroutines."

- [ ] **Step 6.4: Verify both codeomes work**

Paste each into the editor, validate, spawn, observe. Counter-walker should visibly turn every ~8 steps. Turning forager should visibly turn at random intervals.

- [ ] **Step 6.5: Commit**

```bash
git add docs/manual/05-memory-and-arithmetic.md
git commit -m "docs(manual): 05 — slots, arithmetic, Counter-walker, Turning forager"
```

---

## Task 7: 06-procedures.md (Subroutine forager)

**Files:**
- Create: `docs/manual/06-procedures.md`

**Spec reference:** Section `06-procedures.md` of the design spec.

- [ ] **Step 7.1: Construct Subroutine forager**

Refactor the chapter-04 Forager so the `eat; move` pair becomes a procedure called from two places. The procedure has its own anchor, ends with `:ret`.

```elixir
[
  # ── 0..3 LOOP_HEAD anchor [0,0,0,0] ──
  :nop_0, :nop_0, :nop_0, :nop_0,
  # ── 4 sense, then 5..9 jz_t to TURN [1,1,1,1] ──
  :sense_front,
  :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,
  # ── 10..14 call_t to EAT_MOVE [0,1,0,1] (template [1,0,1,0]) ──
  :call_t, :nop_1, :nop_0, :nop_1, :nop_0,
  # ── 15..19 jmp_t back to LOOP_HEAD ──
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,
  # ── 20 separator ──
  :push0,
  # ── 21..24 TURN anchor [1,1,1,1] ──
  :nop_1, :nop_1, :nop_1, :nop_1,
  # ── 25 turn_right ──
  :turn_right,
  # ── 26..30 call_t to EAT_MOVE — same procedure as above ──
  :call_t, :nop_1, :nop_0, :nop_1, :nop_0,
  # ── 31..35 jmp_t back to LOOP_HEAD ──
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,
  # ── 36 separator ──
  :push0,
  # ── 37..40 EAT_MOVE anchor [0,1,0,1] ──
  :nop_0, :nop_1, :nop_0, :nop_1,
  # ── 41 eat ──
  :eat,
  # ── 42 move ──
  :move,
  # ── 43 ret ──
  :ret
]
```

Length 44. Non-nops: many. Verify by hand. The interesting thing: the procedure is reached via `call_t`, runs eat+move, then `ret` pops the return-ip from the call stack and resumes after the call site.

- [ ] **Step 7.2: Write the chapter**

Target ~400 lines. Required contents:

1. **The VM has no `def`.** But `call_t` and `ret` give you the equivalent. Explain:
   - `call_t` reads its template, pushes the return-ip onto the call stack (ip of the instruction immediately after the template), then jumps to the complement.
   - `ret` pops the call stack and sets ip to that value.
   - Call stack is 32 deep. Pushing beyond drops the oldest (you can have very deep recursion but eventually lose).
2. **Cost.** `call_t` is `0.2 + 0.05 × template_len`, `ret` is `0.2`. A template_len=4 call + return costs `0.4 + 0.2 = 0.6` — comparable to a few inline ops.
3. **When to factor out.** Rule of thumb: factor when the inlined sequence is called ≥ 2 times AND the inline cost × calls > call+ret overhead. The chapter-04 forager calls eat+move from 2 places (eat path + turn path) — 2 calls × (1.0 + 2.0) = 6.0 energy saved by inlining vs 2 × 0.6 = 1.2 energy in calls — but the **code-size** savings make the codeome more compact and (later) more mutation-stable.
4. **Anchor naming convention.** Use bit-pattern strings (`[0,1,0,1]`) consistently for anchors. Within the chapter, name procedures conceptually (`EAT_MOVE`).
5. **Subroutine forager listing.** Full code, section by section.
6. **Stack-trace through one call.** Show: ip before call, ret_ip pushed, ip jumps, procedure runs, ret pops, ip resumes. 6-line ASCII trace.
7. **ret on empty call stack.** Falls through. Use case: a procedure that can be called OR fallen into (like a "tail" routine reachable both via call and via plain jmp). Briefly note this exists; don't dwell.
8. **Try it.** Save, spawn, compare behaviour to the chapter-04 forager (should be visually identical — the only difference is internal structure).
9. **One-line forward pointer:** "→ Chapter 7 builds the first replicator."

- [ ] **Step 7.3: Verify the codeome works**

Paste into the editor, validate, spawn, observe. Behaviour must match the chapter-04 Forager exactly (visually).

- [ ] **Step 7.4: Commit**

```bash
git add docs/manual/06-procedures.md
git commit -m "docs(manual): 06 — procedures via call_t/ret, Subroutine forager"
```

---

## Task 8: 07-replication.md (Mini-replicator, Sustainable replicator)

**Files:**
- Create: `docs/manual/07-replication.md`

**Spec reference:** Section `07-replication.md` of the design spec.

- [ ] **Step 8.1: Read the existing MinimalReplicator**

```bash
cat /home/patrick/projects/playground/Lenies/lib/lenies/codeomes/minimal_replicator.ex
```

The chapter does NOT dissect this — that's chapter 09. But the chapter's Sustainable replicator should be structurally simpler than MinimalReplicator (no allocate-failure handling, no random-turn block) so the two contrast in chapter 09.

- [ ] **Step 8.2: Construct Mini-replicator (one-shot)**

```elixir
[
  # ── 0..3 LOOP_HEAD anchor [1,1,1,1] ──
  :nop_1, :nop_1, :nop_1, :nop_1,
  # ── 4..6 get own size N, store in slot[0] ──
  :get_size, :push0, :store,
  # ── 7..9 allocate N (pop N=slot[0], request alloc) ──
  :push0, :load, :allocate,
  # (we ignore the :ok/:no_target reply — for the mini-replicator, no failure handling)
  # ── 10..12 init counter slot[1] = 0 ──
  :push0, :push1, :store,
  # ── 13..16 COPY_LOOP anchor [1,0,0,1] ──
  :nop_1, :nop_0, :nop_0, :nop_1,
  # ── 17..19 read_self at counter (slot[1]) ──
  :push1, :load, :read_self,
  # ── 20..24 write_child at counter — write_child pops opcode_int (top), then addr ──
  :push1, :load, :swap, :write_child, :drop,
  # ── 25..30 increment slot[1] ──
  :push1, :load, :push1, :add, :push1, :store,
  # ── 31..35 condition: N - counter ≠ 0? ──
  :push0, :load, :push1, :load, :sub,
  # ── 36..40 jnz_t back to COPY_LOOP if not done ──
  :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,
  # ── 41 divide ──
  :divide
  # (after divide, fall through into the LOOP_HEAD again — but no forage, so parent dies of starvation)
]
```

Length ~42. The chapter explicitly notes: "After `:divide`, execution continues at the next instruction. We have no further code, so the ip wraps to position 0 and the parent enters the LOOP_HEAD again, tries to allocate (front cell is now occupied by the child), `allocate` returns `:no_target` (0), but mini-replicator doesn't check — it tries `write_child` which is a no-op without an allocation, then `divide` which is a no-op. The parent loops doing nothing while energy drains, then dies. **This is intentional** — it shows why the next codeome adds a forage cycle."

- [ ] **Step 8.3: Construct Sustainable replicator**

Add a forage cycle between divisions. Skeleton:

```
LOOP_HEAD:
  get_size; store in slot[0]
  allocate N
  init copy counter slot[1] = 0
COPY_LOOP:
  read_self; write_child; increment counter
  if counter < N: jump COPY_LOOP
  divide
  random turn (use the pattern from chapter 05)
  build K=64 on stack; store in slot[0]
FORAGE_LOOP:
  sense_front; drop; eat; move
  counter slot[0] -= 1
  if counter ≠ 0: jump FORAGE_LOOP
  jump LOOP_HEAD
```

Target ~95 ops. Use 4-bit anchors throughout with `:push0` separators.

- [ ] **Step 8.4: Write the chapter**

Target ~600 lines. Required contents:

1. **The replication protocol.** A diagram of the three-step protocol: allocate → write_child loop → divide. Note that allocate sets up a buffer in the world; write_child fills it; divide commits.
2. **`allocate(n)` semantics.** Pops n. Asks the world to reserve a child buffer of size n in the front cell. The world replies on the stack: 1 for success, 0 for `:no_target` (front cell occupied or off-grid).
3. **`write_child` semantics.** Pops `opcode_int` (top), pops `addr`. Writes `opcode_int` into the pending child buffer at `addr mod n`. **Copy errors happen here** (per-call substitution/insert/delete probability).
4. **`divide` semantics.** Spawns the child, gives it half the parent's remaining energy. Child appears in the front cell. Parent stays where it is. If there's no pending allocate buffer, divide is a no-op.
5. **`read_self(addr)` semantics.** Pops addr, pushes the integer encoding of the opcode at `codeome[addr mod size]`. This integer is exactly what `write_child` expects.
6. **Why opcode encoding matters.** The integer encoding is the position in the whitelist (0 for nop_0, 1 for nop_1, … 35 for load). `read_self` and `write_child` operate in this integer space, NOT atoms. The encoding wraps too: if `write_child` receives an integer outside 0..35, the world treats it as `:nop_0` (defensive).
7. **Mini-replicator listing.** Full code with commentary. **Crucially**, explain the deliberate failure mode: after divide, the parent's loop tries to allocate again on the occupied front cell, fails, but mini-replicator doesn't check the allocate return value, so it write_childs into nothing and divides into nothing. The parent loops doing nothing while energy drains.
8. **Stack-effect cheat sheet for write_child.** Stress: `write_child` pops opcode_int (top), then addr. To write opcode O at addr A, push A first, then O, then write_child. The mini-replicator listing uses `push1; load; swap; write_child; drop` — explain the swap.
9. **Sustainable replicator listing.** Full code with commentary, structured by section (init, allocate, copy loop, divide, turn, forage build, forage loop, restart). Each section gets its own heading.
10. **Why the forage cycle.** Without it, the parent dies after one division. With it, the parent recovers ~K × (eat_gain − forage_cost) energy per cycle, amortising the copy cost across many divisions.
11. **Try it.** Save the sustainable replicator, spawn 1 with 10 000 energy on the default world. Watch population grow.
12. **One-line forward pointer:** "→ Chapter 8 does the math on whether your replicator survives."

- [ ] **Step 8.5: Verify both codeomes work**

Paste each into the editor, validate, spawn, observe. Mini-replicator should divide once and then the parent should die (visible: 1 child spawns, parent stops moving, then dies within ~30s). Sustainable replicator should grow a small colony.

- [ ] **Step 8.6: Commit**

```bash
git add docs/manual/07-replication.md
git commit -m "docs(manual): 07 — replication protocol, Mini- and Sustainable replicators"
```

---

## Task 9: 08-energy-economy.md

**Files:**
- Create: `docs/manual/08-energy-economy.md`

**Spec reference:** Section `08-energy-economy.md` of the design spec.

- [ ] **Step 9.1: Write the chapter**

Target ~250 lines. Required contents:

1. **A budget for every codeome.** Every codeome you write has an energy budget per "cycle" (one full loop of its main behaviour). To survive long-term, the budget must be net-positive (gain ≥ cost).
2. **Cost breakdown for the chapter-7 Sustainable Replicator.** Walk through every opcode in the listing, sum the per-cycle cost:
   - Init block: `get_size + push0 + store` = 0.3 + 0.1 + 0.5 = 0.9
   - Allocate: `push0 + load + allocate` where allocate is `5.0 + 0.05 × N` and N ≈ 95 → 0.6 + 5.0 + 0.05 × 95 = 10.35
   - Counter init: ~0.6
   - Copy loop body: per iteration, ~6.0 energy. ×95 iterations = ~570.
   - Divide: 10.0
   - Turn block: ~3 to 5
   - Forage init (build K=64): ~1.4
   - Forage loop body: `sense_front + drop + eat + move + counter_decrement + jnz_t` ≈ 6.2 per iteration. ×K=64 → ~397
   - Total cost per cycle: ~1000 energy.

   (Numbers above are approximate; verify against the actual costs in the chapter you wrote.)

3. **Gain per cycle.** Each successful `:eat` returns `eat_amount` (default 20) energy. With 64 forage iterations, if ~half the cells visited have resource, gain ≈ 32 × 20 = 640.
4. **Break-even.** Cycle is sustainable when `K · gain_per_eat > total_cost`. Solve for K. With cost ~1000 and gain per eat 20, we need K such that K × 20 × (eat_hit_rate) > 1000 minus the non-forage cost. Plug in numbers.
5. **Why MinimalReplicator picks K=128.** Larger K amortises the copy loop cost over more forage iterations. Picked empirically to give a stable steady-state population on the default world.
6. **Steady-state energy formula.** After each divide, parent has `(E_old − cost) / 2`. After K forage iterations, parent has `(E_old − cost) / 2 + K × (gain − forage_cost)`. Set equal to E_old to find the fixed point: `E_steady = 2 × (K × (gain − forage_cost) − cost / 2)`. For MinimalReplicator, this is ~2160 — its parents stabilise at this energy.
7. **Copy errors.** Per-call probabilities (substitution 0.005, insert 0.0005, delete 0.0005). A 121-op codeome experiences ~0.6 expected substitutions per replication cycle. Most are silent (in dead code or in templates that still find a match); some are fatal. Short codeomes (your walker, your forager) suffer less mutation per generation simply because there are fewer opcodes to mutate.
8. **A general formula for "can my codeome live?"** Box:
   ```
   sustainable iff   K · (gain · hit_rate − forage_cost) > replication_cycle_cost
   ```
9. **Practical tips.** Bullet list: "Keep your copy loop tight", "Use `dup; add` to build constants cheaply", "Prefer slot-based counters over re-reading get_size every loop", "If your codeome is < 30 ops, you probably don't need any forage at all — direct sun" (i.e. you can do a few `:eat` calls before each divide instead of a counted forage loop).
10. **One-line forward pointer:** "→ Chapter 9 dissects the canonical replicator that ships with Lenies."

- [ ] **Step 9.2: Cross-check the numbers**

Read `lib/lenies/codeome/costs.ex` and `lib/lenies/codeomes/minimal_replicator.ex` once during writing. The "MinimalReplicator picks K=128" sentence and "stabilises at ~2160" must match the moduledoc in the actual file. Quote conservatively — if you're unsure of a number, give a range.

- [ ] **Step 9.3: Commit**

```bash
git add docs/manual/08-energy-economy.md
git commit -m "docs(manual): 08 — energy economy and break-even math"
```

---

## Task 10: 09-minimal-replicator.md

**Files:**
- Create: `docs/manual/09-minimal-replicator.md`

**Spec reference:** Section `09-minimal-replicator.md` of the design spec.

- [ ] **Step 10.1: Read the source files**

```bash
cat /home/patrick/projects/playground/Lenies/lib/lenies/codeomes/minimal_replicator.ex
cat /home/patrick/projects/playground/Lenies/lib/lenies/codeomes/carnivore.ex
```

The chapter must reference real positions, anchors, and bit patterns from these files. Do NOT invent or paraphrase — quote the actual listing.

- [ ] **Step 10.2: Write the chapter**

Target ~400 lines. Required contents:

1. **Why this matters.** MinimalReplicator is the gold-standard hand-tuned replicator that ships with Lenies. Reading it is the final lesson — every idiom you saw in chapters 03–07 appears here, plus a few extras for mutation robustness.
2. **Section-by-section dissection.** Use the actual position ranges from the source moduledoc. For each section:
   - Quote the source listing block verbatim (with the `# ── pos X..Y: ... ──` headers).
   - One paragraph of plain-English commentary.
   - Cross-reference to the chapter that introduced the relevant pattern (e.g. "this is the random-turn block from chapter 5").
3. **The robustness additions.** Three things MinimalReplicator does that the chapter-7 Sustainable Replicator does not:
   - `jz_t` after `allocate` to abort cleanly if the front cell is occupied. Without this, the parent does a bunch of no-op writes and divides into nothing — fine for behaviour, but wastes energy.
   - The `ABORT_TARGET` anchor that doubles as the abort landing AND the post-divide fall-through. Saves opcodes.
   - The `K=128` forage cycle, derived empirically from the energy math in chapter 8.
4. **Separators.** Note the two `:push0` separators at positions 67 and 120 and explain exactly why each is needed (greedy template extraction across the wrap, and between adjacent anchors).
5. **Carnivore addendum.** The Carnivore codeome is MinimalReplicator with `:attack` injected before each `:eat`. The injection is done by the module:
   ```
   lib/lenies/codeomes/carnivore.ex: inject_attack_before_eat/1
   ```
   The chapter explains predation cost/benefit:
   - `:attack` costs 5.0. If front is a Lenie, transfers `attack_damage` (10) energy from victim to attacker.
   - `:defend` costs 2.0. If the victim's `:defend` ran within `defense_window_ticks` (5) before the attack, attacker pays `defense_attacker_penalty` (5) extra.
   - Net: carnivore gains 10 - 5 = 5 per successful attack, but pays 5 even when there's no Lenie in front. Sustainable only in dense populations.
6. **The big picture.** End with a panoramic table comparing all the codeomes from this manual: walker → forager → counter-walker → turning forager → subroutine forager → mini-replicator → sustainable replicator → MinimalReplicator → Carnivore. Columns: name, ops, non-nops, key idiom introduced, fitness on the default world.
7. **One-line forward pointer:** "→ Chapter 10 collects the recurring idioms as a quick-reference cookbook."

- [ ] **Step 10.3: Verify cross-references**

For every position range quoted (e.g. "pos 51..55"), check it matches the actual position in `lib/lenies/codeomes/minimal_replicator.ex`. If the source moves, the chapter is stale — fix it.

- [ ] **Step 10.4: Commit**

```bash
git add docs/manual/09-minimal-replicator.md
git commit -m "docs(manual): 09 — annotated dissection of MinimalReplicator and Carnivore"
```

---

## Task 11: 10-cookbook.md

**Files:**
- Create: `docs/manual/10-cookbook.md`

**Spec reference:** Section `10-cookbook.md` of the design spec.

- [ ] **Step 11.1: Write the chapter**

Target ~350 lines. Six patterns; each is a self-contained section ~50 lines, structured identically.

For each pattern:

```markdown
## Pattern N: <Name>

**When to use:** <one-sentence trigger>

**Code:**
```elixir
# <annotated listing — typically 3..8 atoms>
```

**Cost:** <one-line breakdown>

**Discussion:** <one paragraph of why this works, tradeoffs, common mistakes>
```

Content of the six patterns:

### Pattern 1 — Constant builder (doubling chain)

```elixir
:push1, :dup, :add, :dup, :add, :dup, :add  # → 8 on stack
```

Cost: `0.1 × 7 = 0.7`. To build 2^k, you need `1 + 2k` opcodes (push1 + k×(dup,add)). Beats `pushN` (which is random) and is shorter than a literal `push8` would be — except there's no `push8`. Mention `pushN; <high-low> ?` for non-power-of-2 constants briefly.

### Pattern 2 — Random branch 50/50

```elixir
:pushN, :push1, :push1, :add, :mod  # top is 0 or 1
:jz_t, :nop_X, :nop_Y, :nop_Z, :nop_W  # jump if coin == 0
```

Cost: `0.1 + 0.1 + 0.1 + 0.2 + 0.2 = 0.7` + jump. Fair coin from pushN's uniform 0..255 by modding 2. Note: `mod` pops `a` (top) then `b`, pushes `b mod a`. So with 2 on top, you get `pushN mod 2`.

### Pattern 3 — Defensive front sense

```elixir
:sense_front, :drop
```

Cost: `0.5 + 0.1 = 0.6`. Use when you only need the `wait_world` cycle (to make sure the world state has been observed and any cell-side effects are processed) but don't care about the value. Often paired with a follow-up `eat; move` that will use whatever is there.

### Pattern 4 — Slot-based counter loop

```elixir
# init slot[0] = N
<build N on stack>
:push0, :store

# LOOP_HEAD anchor
:nop_X, :nop_Y, :nop_Z, :nop_W

# <body here>

# decrement and test
:push0, :load, :push1, :sub, :push0, :store
:push0, :load, :jnz_t, <template back to LOOP_HEAD>
```

Cost per iteration: ~3.0 energy beyond the body. Discuss using slot 0 (just because we tend to reach for it first); any of 0..3 work.

### Pattern 5 — Anchor + separator placement

```elixir
# Bad — template extractor reads 8 nops across the boundary:
..., :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
:nop_1, :nop_1, :nop_1, :nop_1, <next code>

# Good — :push0 separator breaks the run:
..., :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
:push0,
:nop_1, :nop_1, :nop_1, :nop_1, <next code>
```

Explain the greedy extraction rule (max 8 nops). Any non-nop opcode works as separator; `:push0` is the cheapest at 0.1 and has no side effects (it just adds a 0 to the stack — drop it if you care).

### Pattern 6 — Skeleton copy loop

A fill-in-the-blanks template. Reader can paste this into the editor and add their own forage code in the marked block:

```elixir
[
  # LOOP_HEAD anchor [1,1,1,1]
  :nop_1, :nop_1, :nop_1, :nop_1,

  # get own size, store in slot[0]
  :get_size, :push0, :store,

  # allocate
  :push0, :load, :allocate,

  # init copy counter slot[1] = 0
  :push0, :push1, :store,

  # COPY_LOOP_HEAD anchor [1,0,0,1]
  :nop_1, :nop_0, :nop_0, :nop_1,

  # read_self at counter; write_child at counter; increment counter
  :push1, :load, :read_self,
  :push1, :load, :swap, :write_child, :drop,
  :push1, :load, :push1, :add, :push1, :store,

  # condition: N - counter ≠ 0?
  :push0, :load, :push1, :load, :sub,

  # jnz_t back to COPY_LOOP_HEAD if not done
  :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

  # divide
  :divide

  # ─────────────────────────────────────────
  # YOUR FORAGE / TURN / RESTART CODE GOES HERE
  # ─────────────────────────────────────────
]
```

Discussion: 35 ops of replication skeleton. Add ~40 ops of forage + restart to get a sustainable replicator. This is exactly what Chapter 7's Sustainable Replicator does.

- [ ] **Step 11.2: Verify**

```bash
wc -l docs/manual/10-cookbook.md
grep -c "^## Pattern" docs/manual/10-cookbook.md
```

Expected: 300–400 lines; exactly 6 pattern subsections.

- [ ] **Step 11.3: Commit**

```bash
git add docs/manual/10-cookbook.md
git commit -m "docs(manual): 10 — cookbook of recurring idioms"
```

---

## Task 12: README.md (index)

**Files:**
- Create: `docs/manual/README.md`

**Spec reference:** Section `README.md` of the design spec.

- [ ] **Step 12.1: Write the index**

Target ~80 lines. Required contents:

1. **Title:** `# Lenies Programming Manual`.
2. **A two-sentence pitch:** what this manual is, who it's for.
3. **How to read this manual:** linear order recommended for first-time readers; chapters are self-contained for lookup. Pyramid of codeomes builds on previous chapters.
4. **Prerequisites:** general programming concepts (stack, loop, condition). Set up the simulator per the project's main README before going further.
5. **Table of contents (linked):**

   ```markdown
   - [00. Introduction](00-introduction.md) — what a Lenie is, the world it lives in
   - [01. VM anatomy](01-vm-anatomy.md) — execution state and the ring
   - [02. Opcode reference](02-opcode-reference.md) — all 36 opcodes
   - [03. First codeome](03-first-codeome.md) — the Walker
   - [04. Loops and templates](04-loops-and-templates.md) — the Forager
   - [05. Memory and arithmetic](05-memory-and-arithmetic.md) — Counter-walker, Turning forager
   - [06. Procedures](06-procedures.md) — call_t/ret, Subroutine forager
   - [07. Replication](07-replication.md) — Mini-replicator, Sustainable replicator
   - [08. Energy economy](08-energy-economy.md) — budget, break-even, copy errors
   - [09. The MinimalReplicator dissected](09-minimal-replicator.md) — the canonical hand-tuned replicator
   - [10. Cookbook](10-cookbook.md) — six recurring idioms
   ```

6. **Conventions:**
   - Code listings are Elixir atom lists, with `# ── pos X..Y: comment ──` headers per section.
   - Stack effects are `( before -- after )` with top on the right.
   - Anchor bit patterns are written `[0,1,0,1]` etc., matching the literal `nop_0 / nop_1` sequence.
   - "Try it" boxes give exact UI clicks in the codeome editor.
7. **Where to ask questions / report errors:** point at the project's GitHub issues link via the main README.

- [ ] **Step 12.2: Verify all links work**

```bash
cd /home/patrick/projects/playground/Lenies/docs/manual
for f in README.md 00-introduction.md 01-vm-anatomy.md 02-opcode-reference.md \
         03-first-codeome.md 04-loops-and-templates.md \
         05-memory-and-arithmetic.md 06-procedures.md \
         07-replication.md 08-energy-economy.md \
         09-minimal-replicator.md 10-cookbook.md; do
  test -f "$f" && echo "OK  $f" || echo "MISS $f"
done
```

Expected: every line says `OK`.

- [ ] **Step 12.3: Commit**

```bash
git add docs/manual/README.md
git commit -m "docs(manual): README index for the programming manual"
```

---

## Task 13: Cross-reference from the project README

**Files:**
- Modify: `README.md` (project root, NOT the manual's README)

- [ ] **Step 13.1: Add a one-paragraph pointer near the start of the project README**

Read the current project README:

```bash
head -30 /home/patrick/projects/playground/Lenies/README.md
```

Find the table-of-contents block and add a `Programming manual` entry pointing at `docs/manual/README.md`. Also add a one-paragraph blurb in the "What this manual will teach you" section style — but for the project README, just one sentence at the top:

```markdown
> 📘 **Want to write your own codeomes?** See the [Lenies Programming Manual](docs/manual/README.md).
```

Insert this immediately after the project's tagline / first paragraph.

- [ ] **Step 13.2: Verify the link**

```bash
grep -n "docs/manual/README.md" /home/patrick/projects/playground/Lenies/README.md
```

Expected: exactly one match.

- [ ] **Step 13.3: Commit**

```bash
git add README.md
git commit -m "docs: link the programming manual from the project README"
```

---

## Task 14: Final smoke test

- [ ] **Step 14.1: Verify every chapter exists and is non-empty**

```bash
cd /home/patrick/projects/playground/Lenies/docs/manual
wc -l *.md
```

Expected: 12 files, each with > 50 lines (no empty stubs).

- [ ] **Step 14.2: Manually verify each codeome listing works in the editor**

For each of {walker, forager, counter-walker, turning forager, subroutine forager, mini-replicator, sustainable replicator}, open the in-app editor, paste the listing, validate (must show `✓ valid`), spawn 1 with 10 000 energy, watch for at least 30 seconds. Document any that misbehave by editing the relevant chapter.

If any listing fails validation (e.g. fewer than 10 non-nops), add padding as described in chapter 03 and re-commit the chapter.

- [ ] **Step 14.3: Push**

```bash
git push origin master
```

---

## Self-review (already performed by the plan author)

1. **Spec coverage:**
   - Every chapter listed in the spec has a corresponding task (Tasks 1–11 map directly to the 12 chapter files).
   - The "executable spirit" test plan from the spec is implemented as the smoke-test gate in Task 14.
   - Language requirement (English throughout) is enforced because every task body is written in English and instructs subagents to write English-only content.
   - Note-on-opcode-counts requirement from the spec is honoured by every task that includes a codeome — counts are approximate targets and chapter headings state the exact count once the listing is finalised.

2. **Placeholder scan:** None. Every task includes the exact codeome to construct or the exact section headings to write. The verification step in each task uses concrete commands, not "verify it works".

3. **Type / name consistency:**
   - All chapter file names use the `NN-name.md` pattern consistently.
   - Anchor naming uses the `[bit, bit, bit, bit]` notation across all chapters that introduce templates.
   - Stack-effect notation `( before -- after )` is used in chapters 02, 03, 04, 05, 06, 07 and the cookbook.
   - The phrase "MinimalReplicator" is capitalised consistently (referring to the module/codeome name), and "minimal replicator" lowercase when used as a common noun (rare).
