# Chapter 10 — Cookbook

This chapter is a quick-reference for the recurring idioms you will reach for
whenever you write a new codeome from scratch.  You have already seen most of
them in context across chapters 03–09; here they are stripped down, costed
precisely, and presented in the format you can paste directly into your own
work.

A note on notation: stack diagrams read left-to-right, with the **rightmost
value on top**.  Costs are computed from `Lenies.Codeome.Costs` and rounded to
two decimal places.  Template lengths are written in square brackets after the
jump opcode, e.g. `jnz_t[4]`.

---

## Pattern 1 — Constant Builder (Doubling Chain)

**When to use:** You need a specific power of 2 on the stack and have no
suitable value elsewhere.

**Code:**
```elixir
# Build 2:
:push1, :dup, :add
# → stack: [2]

# Build 4:
:push1, :dup, :add, :dup, :add
# → stack: [4]

# Build 8:
:push1, :dup, :add, :dup, :add, :dup, :add
# → stack: [8]

# General rule: push1 followed by k repetitions of (dup, add) → 2^k
# Cost formula: 0.1 + 0.3k  (initial push1 plus k repetitions of dup + add)
#   k=1 → 2,   cost 0.40
#   k=3 → 8,   cost 1.00
#   k=7 → 128, cost 2.20
#   k=8 → 256, cost 2.50
```

**Cost:** `0.1 + 0.3k` energy for 2^k (initial `:push1` plus k repetitions of `:dup + :add`).
Building 2 (k=1) costs 0.40; building 8 (k=3) costs 1.00; building 128 (k=7) costs 2.20;
building 256 (k=8) costs 2.50.

**Discussion:** There is no `:push N` opcode for arbitrary N — `:pushN`
produces a *random* integer in 0..255.  The doubling chain is therefore the
only deterministic path to a specific constant.  For non-power-of-2 values,
compose additions after the chain: to build 5, do `push1 + dup + add` (→ 2)
`+ push1 + add` (→ 3) `+ push1 + add` (→ 4) `+ push1 + add` (→ 5) — eight
ops at cost 0.80.  The single most common mistake is omitting the leading
`:push1` and opening with `:dup, :add`, which merely doubles whatever was
already on top of the stack — a lurking bug that only surfaces when that
pre-existing value changes.

---

## Pattern 2 — Random Branch 50/50

**When to use:** You want behaviour to differ randomly between two paths with
equal probability.

**Code:**
```elixir
:pushN,                              # → r in 0..255  (uniform random)
:push1, :push1, :add,               # → r, 2
:mod,                                # → (r mod 2)  ∈ {0, 1}

# Jump to PATH_A if coin == 0; fall through to PATH_B otherwise.
# The four nop_X atoms form the 4-bit template that must be complemented
# by the PATH_A anchor.
:jz_t, :nop_0, :nop_0, :nop_1, :nop_1   # template [0,0,1,1] → searches for [1,1,0,0]

# --- PATH_B code ---
# ...

# --- PATH_A anchor ---
:nop_1, :nop_1, :nop_0, :nop_0,
# --- PATH_A code ---
```

**Cost:** `pushN (0.10) + push1 (0.10) + push1 (0.10) + add (0.20) + mod
(0.20) + jz_t[4] (0.40) = 1.10` energy for the coin-flip machinery itself.

**Discussion:** `:mod` pops `a` (top), then pops `b`, and pushes `b mod a`.
With 2 on top: `pushN mod 2`.  The coin is fair because `:pushN` draws
uniformly from 0..255, an even-length range — exactly half of those 256
values are even (0 mod 2 = 0).  The most common mistake is pushing 2 *before*
`:pushN`; then mod computes `2 mod r`, which equals 2 for all r > 2 (roughly
99% of the time), making the coin almost always land on 1 and completely
breaking the 50/50 distribution.

---

## Pattern 3 — Defensive Front Sense

**When to use:** You need to yield a World tick (allowing the World GenServer
to step) but do not need the cell's actual contents.

**Code:**
```elixir
:sense_front,   # yields to World; pushes a small integer for the front cell
:drop           # discard the result — keep the stack clean
```

**Cost:** `sense_front (0.50) + drop (0.10) = 0.60` energy.

**Discussion:** `:sense_front` is the cheapest way to hand control back to the
World scheduler, which matters when your codeome must cooperate with other
cells running concurrently.  If you immediately follow `:sense_front` with
`:eat` or `:move` unconditionally, the sensed value is irrelevant — dropping
it prevents it from corrupting later arithmetic or conditional tests.  The
chapter-3 Walker uses this idiom in its idle spin loop.  The common mistake is
forgetting the `:drop`, leading to a stack that slowly fills with cell-type
integers; a subsequent `:mod` or `:sub` then operates on the wrong values
entirely.

---

## Pattern 4 — Slot-Based Counter Loop

**When to use:** You want to execute a fixed body exactly N times, where N is
a compile-time constant or a value already computed and sitting on the stack.

**Code:**
```elixir
# ── SETUP ──────────────────────────────────────────────────────────────────
# Assumes N is already on top of the stack.
:push0, :store,             # slot[0] = N       (store pops slot_idx then value)

# ── LOOP HEAD anchor ────────────────────────────────────────────────────────
:nop_1, :nop_1, :nop_0, :nop_0,   # anchor bits [1,1,0,0]

# ── BODY ────────────────────────────────────────────────────────────────────
# ... your work here ...

# ── DECREMENT AND TEST ──────────────────────────────────────────────────────
:push0, :load,              # → [counter]
:push1, :sub,               # → [counter - 1]   (sub: pops a top, pops b, pushes b - a)
:push0, :store,             # slot[0] = counter - 1   (pops slot_idx then value)
:push0, :load,              # → [counter - 1]   (re-read for the conditional)
:jnz_t, :nop_0, :nop_0, :nop_1, :nop_1   # if non-zero, jump to anchor [1,1,0,0]
```

**Cost:** Per iteration (overhead only, excluding the body):
`push0 (0.10) + load (0.50) + push1 (0.10) + sub (0.20) + push0 (0.10) +
store (0.50) + push0 (0.10) + load (0.50) + jnz_t[4] (0.40) = 2.50` energy.

**Discussion:** Any slot 0..3 works; slot 0 is the conventional first choice.
Note that `:store` pops the slot index first (top of stack), then the value —
so the sequence `push0, store` means "store whatever was already on top into
slot 0".  The second `push0, load` before `:jnz_t` is not redundant: the
first load was consumed by `:sub` and then the result was written back by
`:store`, leaving the stack empty at the conditional.  A common alternative is
to `:dup` the decremented value before `:store`, saving one `:push0, :load`
pair at the cost of briefly having two copies of the counter on the stack —
valid, but harder to read.  This pattern appears in the chapter-7 sustainable
replicator.

---

## Pattern 5 — Anchor + Separator Placement

**When to use:** Two anchor-run sequences are adjacent in the codeome, or an
anchor-run immediately follows the nop-template of a jump instruction.

**Bad code:**
```elixir
# jmp_t uses a 4-bit template [0,0,0,0]; the very next instruction begins
# the anchor for the next jump target [1,1,1,1].
..., :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
:nop_1, :nop_1, :nop_1, :nop_1, <next code>
```

**Good code:**
```elixir
..., :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
:push0,                                        # ← SEPARATOR (any non-nop opcode)
:nop_1, :nop_1, :nop_1, :nop_1, <next code>
```

**Cost:** `0.10` energy for the separator (`:push0` is cheapest); add
`:drop (0.10)` if the extra 0 on the stack would be disruptive.

**Discussion:** The template extractor reads consecutive `:nop_0`/`:nop_1`
atoms greedily up to `template_max_len = 8`.  Without the separator, the
jump's template is 8 bits `[0,0,0,0,1,1,1,1]` instead of the intended 4 bits
`[0,0,0,0]`.  The search then looks for the complement `[1,1,1,1,0,0,0,0]`,
which almost certainly does not exist in the codeome, so the jump falls through
rather than branching — a silent correctness bug.  Any non-nop opcode breaks
the greedy read; `:push0` is preferred because it costs only 0.10 and produces
a 0 that is harmless in dead-code positions.  If the extra stack value matters,
append `:drop`.  The MinimalReplicator (chapter 09) contains two separators —
at positions 67 and 120 — for exactly this reason.

---

## Pattern 6 — Skeleton Copy Loop

**When to use:** You are writing a new replicator from scratch and need a
working starting point for the self-copy cycle.

**Code:**
```elixir
[
  # ── OUTER LOOP HEAD anchor [1,1,1,1] ─────────────────────────────────────
  :nop_1, :nop_1, :nop_1, :nop_1,

  # ── GET AND STORE OWN SIZE ────────────────────────────────────────────────
  :get_size,                           # → [size]           cost 0.30
  :push0, :store,                      # slot[0] = size     cost 0.60

  # ── ALLOCATE CHILD ────────────────────────────────────────────────────────
  :push0, :load,                       # → [size]           cost 0.60
  :allocate,                           # → [ok/no_target]   cost 5.0 + 0.05×size
  :drop,                               # discard reply      cost 0.10

  # ── INIT COPY COUNTER ─────────────────────────────────────────────────────
  :push0,                              # → [0]              cost 0.10
  :push1, :store,                      # slot[1] = 0        cost 0.60

  # ── COPY LOOP HEAD anchor [1,0,0,1] ──────────────────────────────────────
  :nop_1, :nop_0, :nop_0, :nop_1,

  # ── COPY BODY: read self[i], write child[i], i++ ──────────────────────────
  :push1, :load,                       # → [i]              cost 0.60
  :read_self,                          # → [opcode_int]     cost 0.30 (pops addr)
  :push1, :load,                       # → [opcode_int, i]  cost 0.60
  :swap,                               # → [i, opcode_int]  cost 0.10
  :write_child,                        # writes opcode_int at child[i]; pops both
                                       #                    cost 1.00
  :push1, :load,                       # → [i]              cost 0.60
  :push1, :add,                        # → [i+1]            cost 0.30
  :push1, :store,                      # slot[1] = i+1      cost 0.60

  # ── CONDITION: remaining = size - counter ─────────────────────────────────
  :push0, :load,                       # → [size]           cost 0.60
  :push1, :load,                       # → [size, i+1]      cost 0.60
  :sub,                                # → [size - (i+1)]   cost 0.20

  # ── LOOP BACK IF NOT DONE ─────────────────────────────────────────────────
  :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,   # complement of [1,0,0,1] is [0,1,1,0]
                                              # cost 0.40 (template_len = 4)

  # ── DIVIDE (spawn child) ──────────────────────────────────────────────────
  :divide,                             # cost 10.0

  # ═══════════════════════════════════════════════════════════════════════════
  # YOUR FORAGE / TURN / RESTART CODE GOES HERE
  # After foraging, jump back to the outer LOOP HEAD anchor [1,1,1,1]:
  #   :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0   (complement of [1,1,1,1])
  # ═══════════════════════════════════════════════════════════════════════════
]
```

**Cost:** Replication cycle cost (skeleton only, excluding forage):

| Phase              | Formula               | Example (N=100) |
|--------------------|-----------------------|-----------------|
| init + allocate    | `0.60 + 5.0 + 0.05N`  | 10.60           |
| copy body × N      | `N × 4.10`            | 410.00          |
| condition + jnz_t  | `N × 1.80`            | 180.00          |
| divide             | `10.0`                | 10.00           |
| **total**          | `≈ 5.95N + 15.60`     | **610.60**      |

Per-iteration copy body breakdown: `push1+load (0.60) + read_self (0.30) +
push1+load (0.60) + swap (0.10) + write_child (1.00) + push1+load (0.60) +
push1+add (0.30) + push1+store (0.60) = 4.10` energy; condition overhead:
`push0+load (0.60) + push1+load (0.60) + sub (0.20) + jnz_t[4] (0.40) =
1.80` energy — for a total of 5.90 per iteration of the loop body (copy +
condition); the `5.95N` figure in the table above also amortises allocate's
per-byte cost (`0.05N`) over each iteration.

**Discussion:** This skeleton is intentionally minimal — it will not survive
long without a forage block, because each replication cycle at N=100 costs
roughly 590 energy while a bare `:eat` only recovers 2.0.  To make it
sustainable, add a turn-and-eat loop after `:divide` and before the
`:jmp_t` that restarts the outer loop; see chapter 7 for the full pattern.
The `:drop` after `:allocate` is non-negotiable: without it the ok/no_target
reply (1 or 0) stays on the stack and poisons the arithmetic in the copy loop.
The separator between the outer anchor and the allocate block is implicit here
because `:get_size` is a non-nop opcode; add an explicit separator if you
place a second anchor-run immediately after any anchor.

---

## Closing Words

You now have the full toolkit: you know the VM anatomy, the opcode costs, the
template-based control flow, the slot memory model, and the energy economy.
You have built every canonical codeome in the pyramid — the Walker, the Grazer,
the Predator, and the sustainable Replicator — and you have dissected the
MinimalReplicator at the byte level.  The six patterns in this chapter are the
mortar that holds those structures together.  Mix them freely.  A random branch
(Pattern 2) inside a counter loop (Pattern 4) inside a replication skeleton
(Pattern 6) is a perfectly natural composition.  When something does not work,
the MinimalReplicator (`docs/manual/09-minimal-replicator.md`) is your best
reference for a known-good example of every idiom used together under real
energy pressure.

Experiment.  Break things.  Measure the cost.  Then fix it.

Happy hacking.
