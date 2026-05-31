# Chapter 4 — Loops and Templates

In chapter 3 you built a Walker that marches north forever. The only thing it does not do is *think* — it cannot react to what it finds. This chapter teaches the mechanism that makes reaction possible: **template addressing**. By the end you will understand how jumps work at the byte level and how to reason about anchor patterns and search direction, and you will have built a Forager that eats resources when the cell ahead is occupied and turns right when it is not.

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

The interpreter scans forward through the codeome, starting at position `ip + 1`, for up to `template_search_radius = 256` positions (the ring wraps via `Integer.mod`). If no match is found going forward, it then scans *backward* from `ip - 1`, again up to 256 positions. The position returned is the index of the **first nop** of the matched complement run.

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

2. The backward search starts at `ip - 1`, meaning it can find anchors that appear *before* the jump in the codeome. This creates backward branches (loops). All loops in Lenies, including the Forager's main loop, rely on a jump searching backward to find an anchor it passed over on the way through.

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
# BROKEN — extractor swallows both anchor runs into one 8-bit template
..., :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
:nop_1, :nop_1, :nop_1, :nop_1, <next_opcode>
```

The extractor reads all eight nops as a single template `[:nop_0, :nop_0, :nop_0, :nop_0, :nop_1, :nop_1, :nop_1, :nop_1]`. The complement is `[:nop_1, :nop_1, :nop_1, :nop_1, :nop_0, :nop_0, :nop_0, :nop_0]`, which is unlikely to appear anywhere in the codeome. The jump will almost certainly fall through.

Fix: insert any non-nop opcode between the anchor runs to act as a **separator**. The cheapest option is `:push0` (cost 0.1, side effect: pushes 0 onto the data stack — harmless in most contexts):

```elixir
# CORRECT — push0 terminates the extractor
..., :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
:push0,
:nop_1, :nop_1, :nop_1, :nop_1, <next_opcode>
```

Now the extractor reads `[:nop_0, :nop_0, :nop_0, :nop_0]` (stops at `:push0`), and the search looks for the four-bit complement `[:nop_1, :nop_1, :nop_1, :nop_1]`. This separator idiom appears throughout Lenies programs whenever two nop regions must coexist near each other. It will be covered as a named cookbook pattern in chapter 10.

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
jz_t tests 5 (not zero → condition false, no jump)
jz_t pops 5 regardless
after jz_t:    stack = [3]
```

If the next instruction is `:dup`, it will duplicate `3`, not `5`. Beginners expecting `5` to survive the failed test are caught off guard every time.

**Cost formula.** All three jump opcodes pay:

```
cost = 0.2 + 0.05 × template_length
```

A 4-bit template costs 0.40 per jump execution. An 8-bit template costs 0.60. Keep templates short when energy budget matters.

To put this in context: the Forager executes two jump instructions per loop iteration (one `jz_t` plus one `jmp_t`), each with a 4-bit template. That is 0.80 energy per loop just for branches, on top of `sense_front` (0.5), `turn_right` (0.5), `eat` (2.0), and `move` (2.0). A Forager that alternates between eating and turning spends roughly 0.80 + 0.5 + 0.5 = 1.80 energy per turn-cycle and 0.80 + 0.5 + 2.0 + 2.0 = 5.30 per eat-cycle. With an initial 10 000 energy budget and `eat_amount = 20` per cell, it needs to eat at least once every few hundred loop iterations to stay alive. On a well-populated grid this is easy; on a sparse grid it will starve.

---

## 6 — The Forager

The Forager is a creature that senses the cell directly ahead, eats and moves forward if there is a resource there, and turns right if the cell is empty. It loops forever.

The codeome has two branches and two loop-back jumps. We use 4-bit anchors to keep jump costs low.

```elixir
[
  # ── 0..3   LOOP_HEAD anchor [0,0,0,0] ────────────────────────────────
  :nop_0, :nop_0, :nop_0, :nop_0,
  # ── 4      sense the front cell; push result onto stack ──────────────
  :sense_front,
  # ── 5..9   jz_t to TURN [1,1,1,1] (template [0,0,0,0]) ─────────────
  #          jz_t consumes the sense result regardless of branch taken
  :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,
  # ── 10     eat the cell ───────────────────────────────────────────────
  :eat,
  # ── 11     move forward ───────────────────────────────────────────────
  :move,
  # ── 12..16 jmp_t back to LOOP_HEAD (template [1,1,1,1]) ─────────────
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,
  # ── 17     separator — terminates extractor before TURN anchor ───────
  :push0,
  # ── 18..21 TURN anchor [1,1,1,1] ─────────────────────────────────────
  :nop_1, :nop_1, :nop_1, :nop_1,
  # ── 22     turn right when there's nothing to eat ─────────────────────
  :turn_right,
  # ── 23..27 jmp_t back to LOOP_HEAD (template [1,1,1,1]) ─────────────
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,
  # ── 28..29 padding to reach the 10 non-nop minimum ───────────────────
  :push0, :drop
]
```

This is 30 opcodes total. Non-nop count: `sense_front`, `jz_t`, `eat`, `move`, `jmp_t`, `push0`, `turn_right`, `jmp_t`, `push0`, `drop` — exactly 10, meeting the validation gate precisely.

### Section-by-section walkthrough

**Positions 0–3: LOOP_HEAD anchor `[0,0,0,0]`**

Four consecutive `:nop_0`. This is the landing pad for both loop-back jumps. Any `jmp_t` or `jz_t` carrying the template `[1,1,1,1]` will complement that to `[0,0,0,0]` and find this run. When the search matches, the ip lands at position 4 (immediately after the last `:nop_0`).

**Position 4: `sense_front`**

Queries the simulation world: what is the resource value of the cell immediately ahead? The result is pushed onto the data stack. A value of 0 means the cell is empty; a positive integer means there is a resource present.

**Positions 5–9: `jz_t :nop_0 :nop_0 :nop_0 :nop_0`**

The conditional branch. The template is `[:nop_0, :nop_0, :nop_0, :nop_0]` — four bits. The complement searched for is `[:nop_1, :nop_1, :nop_1, :nop_1]`, which matches the TURN anchor at positions 18–21.

- If `sense_front` returned 0 (empty cell): condition is true, jump fires, ip → 22 (`turn_right`). The 0 is popped.
- If `sense_front` returned positive (resource present): condition is false, jump does not fire, but the value is still popped. Ip falls through to position 10 (`eat`).

Either way, the stack is clean after this instruction.

**Positions 10–11: `eat`, `move`**

Reached only when the front cell has a resource. `:eat` consumes up to `eat_amount = 20` units of resource from the front cell and credits the creature's energy. `:move` advances the creature one step in its current direction. Both cost 2.0 energy each — expensive, but they return resources.

**Positions 12–16: `jmp_t :nop_1 :nop_1 :nop_1 :nop_1`**

Unconditional loop-back. Template = `[:nop_1, :nop_1, :nop_1, :nop_1]`, complement = `[:nop_0, :nop_0, :nop_0, :nop_0]`. The search finds the LOOP_HEAD anchor at positions 0–3. Ip → 4 (`sense_front`). The EAT path loops back here after every successful meal.

**Position 17: `push0` (separator)**

Without this separator, the extractor at position 12 would read eight consecutive nops — positions 13–16 (`:nop_1` × 4) and then 18–21 (`:nop_1` × 4) — producing an 8-bit template `[1,1,1,1,1,1,1,1]`. That complement `[0,0,0,0,0,0,0,0]` does not exist in the codeome, so the jump would fall through. The `:push0` separator terminates extraction at four bits. It also pushes 0 onto the stack, which `:drop` at position 29 removes — net stack effect is zero.

**Positions 18–21: TURN anchor `[1,1,1,1]`**

Four consecutive `:nop_1`. This is the landing pad for the `jz_t` at position 5. When the search for complement `[1,1,1,1]` succeeds, ip lands at position 22 (`turn_right`).

**Position 22: `turn_right`**

Rotates the creature 90 degrees clockwise. Costs 0.5 energy. After turning, the creature will sense a different cell on the next loop iteration.

**Positions 23–27: `jmp_t :nop_1 :nop_1 :nop_1 :nop_1`**

Identical loop-back to the one at positions 12–16. Template = `[1,1,1,1]`, complement = `[0,0,0,0]`, target = LOOP_HEAD at position 4. The TURN path also needs to loop back, so it gets its own copy of the jump.

**Positions 28–29: `push0`, `drop`**

These two opcodes are never executed (the loop-back jumps at 12 and 23 always redirect before reaching them). They exist solely to satisfy the validator's `min_viable_codeome_opcodes = 10` requirement, which counts non-nop opcodes. Without them the codeome would have only 8 non-nops and would be rejected at spawn time.

### Execution trace

**Cycle with an empty front cell** (`sense_front` returns 0):

```
ip=4   sense_front  → pushes 0          stack: [0]
ip=5   jz_t [0,0,0,0]
       tests top: 0 == 0 → true, will jump
       pops 0 unconditionally            stack: []
       searches for [1,1,1,1] → found at pos 18
       ip = (18 + 4) mod size = 22
ip=22  turn_right   → rotates creature
ip=23  jmp_t [1,1,1,1]
       searches for [0,0,0,0] → found at pos 0
       ip = (0 + 4) mod size = 4
ip=4   sense_front  → next cell ahead   (loop repeats)
```

**Cycle with a resource in the front cell** (`sense_front` returns 15):

```
ip=4   sense_front  → pushes 15         stack: [15]
ip=5   jz_t [0,0,0,0]
       tests top: 15 == 0 → false, no jump
       pops 15 unconditionally           stack: []
       falls through to ip = (5+1+4) mod size = 10
ip=10  eat          → consumes resource, gains energy
ip=11  move         → advances one cell
ip=12  jmp_t [1,1,1,1]
       searches for [0,0,0,0] → found at pos 0
       ip = (0 + 4) mod size = 4
ip=4   sense_front  → next cell ahead   (loop repeats)
```

---

## 7 — Try it in the editor

1. Click **+ New Seed** in the Seeds panel.
2. Drag the 30 opcodes into the editor in the order shown in section 6.
3. Click **Validate**. The status bar should report `✓ valid (30 ops, 10 non-nop)`. If it shows a different non-nop count, recount your non-nop opcodes — a misplaced separator or an extra nop can shift the tally.
4. Click **Save** and name the seed `forager-v1`.
5. Spawn one instance with **10 000** initial energy.
6. Open the energy graph in the inspector panel. On a well-resourced grid the Forager's energy should hold relatively stable or decline slowly. On a sparse or freshly-grazed grid you will see sharp drops during extended turn-only cycles.

Watch the creature on the grid. Compare it with the Walker from chapter 3:

- The **Walker** moves north indefinitely regardless of what it finds. It plows through empty cells and walls alike, executing `:move` even when there is nothing to eat.
- The **Forager** reacts. When the front cell has a resource it eats and steps forward. When the front cell is empty it turns right, eventually spiralling toward wherever resources cluster. You will see it pause at boundaries and pivot rather than blindly marching.

The Forager still has weaknesses: it turns right exclusively (it never backtracks or explores left), it cannot count consecutive failures to detect when it is truly stuck, and it cannot remember which patches it has already depleted. As a result it can spin in place turning right repeatedly if surrounded by empty cells on all sides — a full 360-degree turn returning it to its original heading, only to sense the same empty cell and turn again.

Chapter 5 introduces local memory registers that will let you build creatures that count consecutive failures, compare against a threshold, and break out of spin cycles.

### Common mistakes checklist

Before spawning a Forager variant, run through these:

- **Anchor pattern collision**: are your LOOP_HEAD and TURN anchors distinct? `[0,0,0,0]` and `[1,1,1,1]` are distinct; `[0,0,0,0]` and `[0,0,0,0]` are not (a jump targeting the first may land at the second).
- **Missing separator**: do you have a non-nop between any two adjacent nop regions that should be separate anchors? One `:push0` is enough.
- **Stack imbalance after `jz_t`/`jnz_t`**: the tested value is gone. If the next instruction after a failed conditional jump expects the tested value still on the stack, it will get the value beneath it instead.
- **Template too long**: if the extractor silently reads past the intended template boundary, the complement will not match any anchor and the jump will always fall through. Use the separator pattern to cap extraction early.
- **Non-nop count below 10**: if validation rejects the codeome, count non-nops carefully. Add `:push0`/`:drop` pairs in dead code regions to reach the threshold.

---

## 8 — What's next

`→ Next: Chapter 5 introduces local memory and counter loops. (`[05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)`)`

The Forager is a good baseline creature. Save your seed now — in later chapters you will extend it step by step into a creature that counts, compares, replicates, and competes.
