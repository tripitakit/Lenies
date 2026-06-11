# Chapter 4 — Loops and Templates

In chapter 3 you built a Crawler that marches north forever. The only thing it does not do is *think* — it cannot react to what it finds. This chapter teaches the mechanism that makes reaction possible: **template addressing**. By the end you will understand how jumps work at the byte level and how to reason about anchor patterns and search direction, and you will have built **Reflex** — rung 1 of the seed ladder — a creature that senses the cell ahead and reacts three ways: eat when food is there, cruise over empty cells, and turn away from a neighbour.

---

## 1 — Why template addressing?

Most assembly-like languages give jumps an explicit label or numeric address:

```
L1:
  ...
  goto L1      ; jump to address 42
```

Lenies has no labels and no numeric addresses in jump instructions. Why?

Because the codeome is also a *genome*. The simulator applies random mutations — bit-flips, insertions, deletions — at runtime. A numeric address embedded in an opcode stream would point at garbage after a single substitution. The branch would fire at a random location and the creature would crash or behave nonsensically. Evolution cannot repair that; the fitness landscape is too jagged.

Template addressing solves this by making branches **content-addressed**. Instead of "jump to position 42", a jump says "jump to wherever a certain bit pattern appears". If a mutation shifts the target anchor a few positions left or right, the search still finds it. If a mutation garbles the anchor badly enough, the jump falls through harmlessly rather than landing at garbage. The mechanism degrades gracefully under mutation — a property hard-coded addresses cannot provide.

---

## 2 — The mechanic in detail

Every jump opcode (`jmp_t`, `jz_t`, `jnz_t`) runs through five steps.

### Step 1 — Extract the template

Immediately after the jump opcode, the interpreter reads a sequence of `:nop_0` and `:nop_1` opcodes. It stops when it hits any non-nop opcode, or when it has collected `template_max_len = 8` bits (whichever comes first). This sequence is the **template**.

If the jump is at position `ip`, extraction starts at `ip + 1`.

Extraction is purely a read — it does not advance the ip and does not consume energy beyond the jump's own cost. The nop opcodes following the jump are read as data; they will also be *executed* normally when the ip passes through them in linear execution. This double-duty (data for the extractor, no-ops for the executor) is why `:nop_0` and `:nop_1` exist as distinct opcodes at all: the extractor treats them as data bits, and the executor treats them as cheap do-nothing instructions (cost 0.1 each).

### Step 2 — Compute the complement

Flip every bit: `:nop_0 → :nop_1` and `:nop_1 → :nop_0`. The complement is what the jump will search for in the codeome.

### Step 3 — Search the codeome

The interpreter scans forward through the codeome, starting at position `ip + 1`, for up to `template_search_radius = 512` positions (the ring wraps via `Integer.mod`). If no match is found going forward, it then scans *backward* from `ip - 1`, again up to 512 positions. The position returned is the index of the **first nop** of the matched complement run.

The forward pass has priority: if both a forward and a backward match exist, the forward one wins. This matters when designing codeomes with multiple potential targets — put the intended target forward of the jump whenever possible.

If neither pass finds a match, the jump does not fire (see step 5).

### Step 4 — Land immediately after the complement

On success:

```
target_ip = (match_position + template_length) mod codeome_size
```

This places the instruction pointer at the opcode **immediately after** the matched complement, not at the first nop of the complement. The anchor is jumped *past*, not *into*.

### Step 5 — Fall through on failure

If the search found no match, the jump is silently skipped. The ip advances past the template as if the jump were not there:

```
ip = (jump_ip + 1 + template_length) mod codeome_size
```

Execution continues with whatever opcode follows the template. This fall-through behaviour is intentional: a creature whose target anchor has been mutated away does not crash — it just runs a different path. From an evolutionary perspective, fall-through is a form of robustness: a partially-broken branch degrades into a straight-line execution rather than an illegal memory access. Many viable mutations affect anchors in exactly this way — a creature that loses one jump target may still survive if the fall-through path does something useful.

A zero-length template (the opcode immediately following the jump is not a nop) also results in fall-through. The `find_complement` function returns `:not_found` immediately for an empty template, so such a jump is a no-op that only costs its base energy.

### ASCII diagram

Consider this codeome fragment:

```
pos:    5        6       7       8       ...    12      13      14
op:  :jmp_t  :nop_0  :nop_0  :push0   ...  :nop_1  :nop_1  :push0
```

- Jump is at ip = 5.
- **Extract**: start at 6, read `:nop_0, :nop_0`, stop at 8 (`:push0` is not a nop).
  Template = `[:nop_0, :nop_0]`, length = 2.
- **Complement**: `[:nop_1, :nop_1]`.
- **Search forward**: starting at position 6, scan for `[:nop_1, :nop_1]`.
  Match found at position 12.
- **Land**: target_ip = (12 + 2) mod size = 14.
  Ip jumps to 14, which holds `:push0`.

```
codeome:  [.. :jmp_t :nop_0 :nop_0 :push0 .. :nop_1 :nop_1 :push0 ..]
position:      5      6      7      8     ..   12     13     14
                      |___template___|          |__anchor__|    ^
                      searched complement ------>              ip lands here
```

### Notes on the search implementation

Two details are worth keeping in mind when reasoning about which anchor a jump will reach:

1. The forward search starts at `ip + 1`, not at `ip`. This means the jump's own template region is not excluded from the search. If the template `[:nop_0, :nop_0]` appears in the jump's own trailing nops, a match *could* theoretically be found there — but only if the complement of the template happens to match those same nops, which requires `[:nop_0, :nop_0]` to be its own complement. Since the complement flips bits, no non-empty template can be its own complement. You therefore never need to worry about a jump accidentally "matching itself".

2. The backward search starts at `ip - 1`, meaning it can find anchors that appear *before* the jump in the codeome. This creates backward branches (loops). All loops in Lenies, including Reflex's main loop, rely on a jump searching backward to find an anchor it passed over on the way through.

---

## 3 — Anchor bit-pattern naming convention

An **anchor** is a run of consecutive `:nop_0`/`:nop_1` opcodes that serves as a jump target. The project names them by their bit pattern: anchor `[0,0,0,0]` is four `:nop_0` opcodes in a row; anchor `[0,1,0,1]` is `:nop_0, :nop_1, :nop_0, :nop_1`.

To jump *to* an anchor you write its **complement** as the template after the jump opcode, because the search looks for the complement of the template.

| Anchor in codeome    | Search template after jump |
|----------------------|---------------------------|
| `[0,0,0,0]`          | `[1,1,1,1]`               |
| `[1,1,1,1]`          | `[0,0,0,0]`               |
| `[0,1,0,1]`          | `[1,0,1,0]`               |
| `[1,0,0,1]`          | `[0,1,1,0]`               |

The naming is purely a human convention — the VM does not know about anchor names. Any run of nops in the codeome is a potential target for any jump whose template is its complement.

A practical consequence: if your codeome contains two anchors with the same bit pattern (say, two separate `[0,0,0,0]` blocks), *both* are valid targets for a jump carrying template `[1,1,1,1]`. The jump will land at whichever one is found first — the nearest one in the forward direction, or if none is forward, the nearest one backward. Duplicate anchors are common in longer codeomes and can cause unexpected control flow. Use distinct anchor patterns for distinct targets, or accept that a search may find the "wrong" one and design your code to handle both landing points correctly.

---

## 4 — Separators: the greedy extractor trap

The template extractor is **greedy**. It does not stop at the boundary between two anchor runs — it stops only at a non-nop opcode or at `template_max_len`. This creates a common mistake.

Suppose you place two anchors next to each other without anything between them:

```elixir
# BROKEN - extractor swallows both anchor runs into one 8-bit template
..., :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
:nop_1, :nop_1, :nop_1, :nop_1, <next_opcode>
```

The extractor reads all eight nops as a single template `[:nop_0, :nop_0, :nop_0, :nop_0, :nop_1, :nop_1, :nop_1, :nop_1]`. The complement is `[:nop_1, :nop_1, :nop_1, :nop_1, :nop_0, :nop_0, :nop_0, :nop_0]`, which is unlikely to appear anywhere in the codeome. The jump will almost certainly fall through.

Fix: insert any non-nop opcode between the anchor runs to act as a **separator**. The cheapest option is `:push0` (cost 0.1, side effect: pushes 0 onto the data stack — harmless in most contexts):

```elixir
# CORRECT - push0 terminates the extractor
..., :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
:push0,
:nop_1, :nop_1, :nop_1, :nop_1, <next_opcode>
```

Now the extractor reads `[:nop_0, :nop_0, :nop_0, :nop_0]` (stops at `:push0`), and the search looks for the four-bit complement `[:nop_1, :nop_1, :nop_1, :nop_1]`. This separator idiom appears throughout Lenies programs whenever two nop regions must coexist near each other. It will be covered as a named cookbook pattern in chapter 11.

---

## 5 — Conditional jumps and the pop subtlety

`jz_t` and `jnz_t` work like `jmp_t` but check the top of the data stack before deciding whether to jump:

- `jz_t` — jumps if top of stack == 0.
- `jnz_t` — jumps if top of stack != 0.
- `jmp_t` — unconditional, never touches the stack.

The critical detail: **both conditional jump variants always pop the top of the stack, regardless of whether the condition is true**.

This is not a quirk — it is by design, implemented explicitly in the interpreter:

```
# For conditional jumps, consume the stack value (always)
state_after_pop =
  case condition do
    :always -> state          # jmp_t: no pop
    _       -> {_, s} = State.pop(state); s   # jz_t / jnz_t: pop unconditionally
  end
```

The resulting state — with the tested value removed — is what advances to the next instruction, whether the jump fired or not.

**Example of the trap.** Suppose the stack holds `[3, 5]` (top on the right per the manual convention — so `5` is the top, `3` is below) and execution reaches `jz_t`:

```
before jz_t:   stack = [3, 5]    (top = 5)
jz_t tests 5 (not zero -> condition false, no jump)
jz_t pops 5 regardless
after jz_t:    stack = [3]
```

If the next instruction is `:dup`, it will duplicate `3`, not `5`. Beginners expecting `5` to survive the failed test are caught off guard every time.

**Cost formula.** All three jump opcodes pay:

```
cost = 0.2 + 0.05 x template_length
```

A 4-bit template costs 0.40 per jump execution. An 8-bit template costs 0.60. Keep templates short when energy budget matters.

To put this in context: Reflex executes one or two conditional jumps plus a loop-back `jmp_t` per iteration, each with a 4-bit template (0.40 each). On the food path it spends roughly `sense_front` (0.5) + `dup` (0.1) + `jz_t` (0.4) + `push1`+`add` (0.3) + `jz_t` (0.4) + `eat` (2.0) + `move` (2.0) + `jmp_t` (0.4) ≈ 6.1 energy; the cruise and turn paths are cheaper. With an initial 10 000 energy budget and `eat_amount = 20` per cell, it needs to eat often enough to offset the move cost. On a well-populated grid this is easy; on a sparse grid it will starve — and because Reflex never replicates, that is the end of that lineage.

---

## 6 — Reflex

`Reflex` is rung 1 of the seed ladder and the smallest creature that genuinely
*reacts*. It senses the cell directly ahead and branches three ways:

- **food ahead** (`sense_front > 0`) → `eat`, then `move`;
- **empty** (`== 0`) → `move` (cruise);
- **a neighbour ahead** (`== -1`) → `turn_right` (steer away).

It loops forever and never replicates — a mortal reflex agent. The trick that
makes a three-way branch fit in a stack machine is **sign discrimination**: the
sensed value is `-1`, `0`, or positive, and two `jz_t` tests (with a `+1` in
between) sort the three cases apart.

The codeome is 49 opcodes with three anchors. We use 4-bit anchors to keep jump
costs low, chosen so the three anchors are mutually distinct (no duplicate-anchor
trap):

| Label | Anchor      | Jump template |
|-------|-------------|---------------|
| LOOP  | `[1,1,1,1]` | `[0,0,0,0]`   |
| EMPTY | `[0,1,1,0]` | `[1,0,0,1]`   |
| AVOID | `[1,1,0,0]` | `[0,0,1,1]`   |

```elixir
[
  # == 0..3   LOOP anchor [1,1,1,1] =====================================
  :nop_1, :nop_1, :nop_1, :nop_1,
  # == 4..5   sense the cell ahead, duplicate the value ==================
  :sense_front, :dup,
  # == 6..10  jz_t EMPTY (template [1,0,0,1]) - taken when value == 0 ====
  :jz_t, :nop_1, :nop_0, :nop_0, :nop_1,
  # == 11..12 value + 1: lenie(-1)->0, food(>0)->>=2 ====================
  :push1, :add,
  # == 13..17 jz_t AVOID (template [0,0,1,1]) - taken when value was -1 ==
  :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,
  # == 18..19 food path: eat, then advance ==============================
  :eat, :move,
  # == 20..24 jmp_t LOOP (template [0,0,0,0]) ===========================
  :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
  # == 25     separator =================================================
  :push0,
  # == 26..29 EMPTY anchor [0,1,1,0] ====================================
  :nop_0, :nop_1, :nop_1, :nop_0,
  # == 30..31 cruise: drop the leftover 0, then advance =================
  :drop, :move,
  # == 32..36 jmp_t LOOP ================================================
  :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
  # == 37     separator =================================================
  :push0,
  # == 38..41 AVOID anchor [1,1,0,0] ====================================
  :nop_1, :nop_1, :nop_0, :nop_0,
  # == 42     turn away from the neighbour ==============================
  :turn_right,
  # == 43..47 jmp_t LOOP ================================================
  :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
  # == 48     separator (breaks the wrap into LOOP at pos 0) ============
  :push0
]
```

### Section-by-section walkthrough

**Positions 0–3: LOOP anchor `[1,1,1,1]`.** The landing pad for all three
loop-back jumps. Each carries the template `[0,0,0,0]`, whose complement is
`[1,1,1,1]`. When a jump matches, the ip lands at position 4.

**Positions 4–5: `sense_front`, `dup`.** `sense_front` pushes a value describing
the cell ahead: `-1` for a Lenie, `0` for empty, a positive integer for food.
`dup` keeps a second copy, because the first `jz_t` will consume one.

**Positions 6–10: `jz_t EMPTY`.** Tests (and pops) the top copy. If it is `0`
(empty cell), the jump fires to the EMPTY anchor at 26, leaving the *other*
copy (`0`) still on the stack. Otherwise the value was `-1` or positive, and the
jump falls through with that copy still present.

**Positions 11–12: `push1`, `add`.** Adds 1 to the surviving value. A neighbour
(`-1`) becomes `0`; food (`>0`) becomes `≥2`. This is the sign-discrimination
trick: it turns "is this the neighbour case?" into a plain zero test.

**Positions 13–17: `jz_t AVOID`.** Tests (and pops) the result. If it is `0`
(the value was `-1`, a neighbour), the jump fires to the AVOID anchor at 38.
Otherwise it was food, and the jump falls through to the food path with an empty
stack.

**Positions 18–19: `eat`, `move`.** The food path. Consume the resource and
step forward.

**Positions 20–24: `jmp_t LOOP`.** Loop back to LOOP for the next iteration.

**Position 25: `push0` separator.** Stops the template extractor from reading
the `jmp_t`'s `[0,0,0,0]` template straight into the EMPTY anchor's nops.

**Positions 26–29: EMPTY anchor `[0,1,1,0]`.** Landing pad for `jz_t EMPTY`.

**Positions 30–31: `drop`, `move`.** The cruise path arrives here with the
leftover dup'd `0` still on the stack — `drop` clears it (keeping the stack
balanced), then `move` advances over the empty cell.

**Positions 32–36: `jmp_t LOOP`.** Loop back.

**Position 37: `push0` separator.** Same role before the AVOID anchor.

**Positions 38–41: AVOID anchor `[1,1,0,0]`.** Landing pad for `jz_t AVOID`.

**Position 42: `turn_right`.** Steer away from the neighbour; the next iteration
faces a different cell.

**Positions 43–47: `jmp_t LOOP`.** Loop back.

**Position 48: `push0` separator.** Guards the ring wrap: without it, the final
`jmp_t`'s `[0,0,0,0]` template would merge with the LOOP anchor's `[1,1,1,1]`
across the wrap into an eight-nop run.

Every path is stack-balanced: only the cruise path arrives with a value left
over, and it `drop`s it immediately.

### Execution traces

**Food ahead** (`sense_front` returns 15):

```
ip=4   sense_front -> pushes 15            stack: [15]
ip=5   dup                                 stack: [15, 15]
ip=6   jz_t EMPTY: tests 15 != 0, no jump; pops one  stack: [15]
ip=11  push1; add -> 15 + 1 = 16           stack: [16]
ip=13  jz_t AVOID: tests 16 != 0, no jump; pops      stack: []
ip=18  eat; move
ip=20  jmp_t LOOP -> ip = 4                (loop repeats)
```

**Empty cell** (`sense_front` returns 0):

```
ip=4   sense_front -> pushes 0             stack: [0]
ip=5   dup                                 stack: [0, 0]
ip=6   jz_t EMPTY: tests 0 == 0, JUMP; pops one      stack: [0]
ip=30  drop                                stack: []
ip=31  move
ip=32  jmp_t LOOP -> ip = 4                (loop repeats)
```

**Neighbour ahead** (`sense_front` returns -1):

```
ip=4   sense_front -> pushes -1            stack: [-1]
ip=5   dup                                 stack: [-1, -1]
ip=6   jz_t EMPTY: tests -1 != 0, no jump; pops one  stack: [-1]
ip=11  push1; add -> -1 + 1 = 0            stack: [0]
ip=13  jz_t AVOID: tests 0 == 0, JUMP; pops          stack: []
ip=42  turn_right
ip=43  jmp_t LOOP -> ip = 4                (loop repeats)
```

---

## 7 — Try it in the editor

1. Click **+ New Seed** in the Seeds panel (or open the built-in `Reflex` seed
   to load it ready-made).
2. Drag the 49 opcodes into the editor in the order shown in section 6.
3. Click **Validate**. The status bar should report `✓ valid (49 ops, 17
   non-nop)`. If the non-nop count differs, recount — a misplaced separator or
   an extra nop shifts the tally.
4. Click **Save** and name the seed `reflex-v1`.
5. Spawn one instance with **10 000** initial energy.

Watch the creature on the grid. Compare it with the Crawler from chapter 3:

- The **Crawler** moves north indefinitely regardless of what it finds. It
  ploughs through empty cells and neighbours alike, executing `:move` even when
  there is nothing to eat.
- **Reflex** reacts. On food it eats and steps forward; on an empty cell it
  cruises; on a neighbour it turns away. You will see it beeline onto resource
  and veer off others rather than blindly marching.

Reflex still has limits: it has no memory, so it cannot count consecutive
failures, remember depleted patches, or escape a corner it keeps turning into.
And it never replicates — it is mortal, a baseline against which the replicating
rungs are measured. Chapter 5 introduces local memory registers that let you
build creatures that count, compare against a threshold, and break out of spin
cycles.

### Common mistakes checklist

Before spawning a Reflex variant, run through these:

- **Anchor pattern collision**: are your LOOP, EMPTY, and AVOID anchors
  distinct? A jump targeting one must not find another first.
- **Missing separator**: do you have a non-nop between any two adjacent nop
  regions that should be separate anchors? One `:push0` is enough — including
  across the ring wrap.
- **Stack imbalance after `jz_t`/`jnz_t`**: the tested value is always popped.
  Reflex relies on this — and on the leftover `dup` copy reaching the cruise
  path, where `drop` clears it.
- **Template too long**: if the extractor reads past the intended boundary, the
  complement matches no anchor and the jump always falls through. Cap extraction
  with a separator.
- **Non-nop count below 10**: if validation rejects the codeome, count non-nops
  carefully.

---

## 8 — What's next

→ Next: Chapter 5 introduces local memory and counter loops.
([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md))

Reflex is a good baseline creature. The chapters that follow add the
capabilities the higher rungs of the ladder need — memory and arithmetic
(chapter 5), subroutines (chapter 6), and replication (chapter 7) — building
toward Ancestor, Architect, and Symbiont.
