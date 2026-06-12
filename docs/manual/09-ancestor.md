# Chapter 9 — The Ancestor Dissected

## 1. Why this matters

`Ancestor` is the canonical self-replicator of the seed ladder — rung 2, and
the reference against which new replicating codeomes are benchmarked.

Every idiom introduced in chapters 03–07 appears in its 100 opcodes:
anchor-based loops (chapter 04), a slot-based counter (chapter 05), the
doubling chain for large constants (chapter 05), the `read_self` /
`write_child` copy idiom (chapter 07). What the chapter-07 sustainable
replicator left as an exercise — graceful handling of a busy front cell —
`Ancestor` solves with one extra jump and a dual-purpose anchor.

Its signature trick: a **single slot used as both the copy counter and the
copy address**. Where a naive replicator keeps `N` in one slot and a separate
index in another, `Ancestor` counts *down* from `N-1` and uses that same value
as the address to read and write — copying the chromosome high-address-first.

---

## 2. The shape, at a glance

- **100 opcodes total** (positions 0–99, ring-indexed).
- **5 named anchors** (4-bit `nop_0`/`nop_1` sequences):
  `HEAD`, `COPY`, `REPRODUCE`, `ABORT`, `FORAGE`.
- **Two `:push0` separators** at positions 49 and 99, preventing the template
  extractor from reading across adjacent nop blocks.
- **K = 64 forage iterations** between division attempts.
- **Allocate-failure handling** via `:jz_t` at positions 10–14.
- **Deterministic post-divide `:turn_right`** — no random coin, so no
  turn-branch anchors are needed (one reason it is leaner than a six-anchor
  design).

The five anchors are drawn from five **different complement-pairs**, so the
ten nop windows (five anchors + five jump templates) are all distinct 4-bit
patterns. Every search target therefore occurs exactly once in the ring and
each jump resolves to its intended anchor unambiguously.

| Label     | Anchor          | Jump template     |
|-----------|-----------------|-------------------|
| HEAD      | `[n1,n1,n1,n1]` | `[n0,n0,n0,n0]`   |
| COPY      | `[n1,n0,n0,n1]` | `[n0,n1,n1,n0]`   |
| REPRODUCE | `[n1,n1,n0,n0]` | `[n0,n0,n1,n1]`   |
| ABORT     | `[n1,n0,n1,n0]` | `[n0,n1,n0,n1]`   |
| FORAGE    | `[n1,n0,n0,n0]` | `[n0,n1,n1,n1]`   |

---

## 3. Section-by-section dissection

### pos 0..3 — HEAD anchor `[nop_1, nop_1, nop_1, nop_1]`

```elixir
# == pos 0..3: HEAD anchor [n1, n1, n1, n1] ===========================
:nop_1, :nop_1, :nop_1, :nop_1,
```

Entry point of the main cycle. The all-ones pattern is unique among the five
anchors. Jumps to `HEAD` carry complement template `[nop_0, nop_0, nop_0,
nop_0]`. Cross-reference: chapter 04
([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 4..6 — save own size N in slot[0]

```elixir
# == pos 4..6: save own size N into slot[0] ===========================
:get_size, :push0, :store,
```

`:get_size` pushes 100; `:store` writes `slots[0] ← 100`. Saving `N` to a slot
*before* allocating keeps the failure branch clean: whether allocate succeeds
or not, the stack is empty when the guard runs. Cross-reference: chapter 05
([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)).


### pos 7..9 — allocate child slot of size N in the front cell

```elixir
# == pos 7..9: allocate child slot of size N in front cell ============
:push0, :load, :allocate,
```

`push0; load` reloads N from slot[0]. `:allocate` reserves a write buffer of
size N in the front cell. Pushes 1 on success, 0 on failure.
Cross-reference: allocate semantics, chapter 07
([07-replication.md](07-replication.md)).


### pos 10..14 — jz_t to ABORT if allocate failed

```elixir
# == pos 10..14: jz_t -> if allocate failed, jump to ABORT ============
:jz_t, :nop_0, :nop_1, :nop_0, :nop_1,
```

**Robustness addition 1.** If allocate returned 0, jumps to `ABORT` at pos 56
(complement `[nop_1, nop_0, nop_1, nop_0]`), skipping the copy loop and
`:divide` and going straight to refuelling. Because N was already stored, the
stack is empty here on both branches. Cross-reference: chapter 04
([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 15..20 — top copy index N-1 → slot[0]

```elixir
# == pos 15..20: top copy index N-1 -> slot[0] =======================
:push0, :load, :push1, :sub, :push0, :store,
```

`push0; load` reloads N; `push1; :sub` computes `N − 1` (`second − top`);
`push0; store` writes it back to slot[0]. The slot now holds the **top copy
index**, which the loop will use as both counter and address.
Cross-reference: chapter 05 ([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)).


### pos 21..24 — COPY anchor `[nop_1, nop_0, nop_0, nop_1]`

```elixir
# == pos 21..24: COPY anchor [n1, n0, n0, n1] ========================
:nop_1, :nop_0, :nop_0, :nop_1,
```

Top of the per-opcode copy loop. The `jmp_t` at pos 44–48 jumps back here
with complement template `[nop_0, nop_1, nop_1, nop_0]`.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 25..30 — copy own[i] → child[i]

```elixir
# == pos 25..30: copy own[i] -> child[i] =============================
:push0, :load, :dup, :read_self, :write_child, :drop,
```

`push0; load` pushes the index `i` (= slot[0]); `:dup` keeps a second copy.
`:read_self` pops the top `i` and pushes the integer encoding of the opcode at
position `i` in the parent's own chromosome — the stack is now `[i, op_i]`,
which is exactly `[addr, opcode_int]`, the order `:write_child` wants (it pops
opcode then address). `:write_child` writes `op_i` into child slot `i`; `:drop`
discards the status flag. One slot served as counter *and* address — no
separate index variable. Cross-reference: `read_self`/`write_child` semantics,
chapter 07 ([07-replication.md](07-replication.md)).


### pos 31..37 — reload i, test for zero → REPRODUCE

```elixir
# == pos 31..32: reload i for the zero test ==========================
:push0, :load,
# == pos 33..37: jz_t -> copied index 0? then divide =================
:jz_t, :nop_0, :nop_0, :nop_1, :nop_1,
```

`push0; load` reloads `i`. `:jz_t` pops it: when `i == 0` the parent has just
copied index 0 — every opcode is now in the child — so it jumps to `REPRODUCE`
at pos 50 (complement `[nop_1, nop_1, nop_0, nop_0]`). Otherwise it falls
through to the decrement. Cross-reference: chapter 05
([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)).


### pos 38..48 — decrement i, loop back to COPY

```elixir
# == pos 38..43: decrement i (slot[0] -= 1) ==========================
:push0, :load, :push1, :sub, :push0, :store,
# == pos 44..48: jmp_t -> back to COPY ===============================
:jmp_t, :nop_0, :nop_1, :nop_1, :nop_0,
```

Standard slot-decrement (load, subtract 1, store), then an unconditional
`:jmp_t` back to `COPY`. Because the zero-test already happened *before* the
decrement, index 0 is copied before the loop exits — the whole `0..N-1` range
is covered exactly once, high to low. Cross-reference: chapter 05
([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)); chapter 04
([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 49 — SEPARATOR `:push0`

```elixir
# == pos 49: separator =============================================
:push0,
```

**Robustness addition 2a.** Without this separator the four nops of the
`jmp_t COPY` template (pos 45–48) would be adjacent to the four nops of the
`REPRODUCE` anchor (pos 50–53); the extractor (max 8 nops) would absorb all
eight. This `:push0` stops it at four. It is dead code — `:jmp_t` at 44 jumps
over it, and `REPRODUCE` is only reached by the `:jz_t` at pos 33.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 50..55 — REPRODUCE: divide, step off the child

```elixir
# == pos 50..53: REPRODUCE anchor [n1, n1, n0, n0] ===================
:nop_1, :nop_1, :nop_0, :nop_0,
# == pos 54..55: bear the child, then step off it ====================
:divide, :turn_right,
```

`:divide` seals the child buffer and spawns the new Lenie in the front cell.
`:turn_right` then rotates 90° clockwise so the parent does not immediately
collide with its own newborn on the next `:move`. A *deterministic* turn —
unlike a random-coin design — costing one opcode and zero anchors. Execution
falls through into `ABORT`. Cross-reference: chapter 07
([07-replication.md](07-replication.md)).


### pos 56..59 — ABORT anchor `[nop_1, nop_0, nop_1, nop_0]`

```elixir
# == pos 56..59: ABORT anchor [n1, n0, n1, n0] (also alloc-fail landing)
:nop_1, :nop_0, :nop_1, :nop_0,
```

**Robustness addition 2b.** Dual-purpose anchor: the `:jz_t` at pos 10 jumps
here when allocation fails; `:turn_right` at pos 55 falls through here on
success. Both paths need the same next action — set up the forage budget — so
no opcodes are spent on a separate landing anchor. Cross-reference: anchor
reuse, chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 60..74 — build the K=64 forage budget into slot[0]

```elixir
# == pos 60..72: build 64 (push1 + 6x(dup,add)) ======================
:push1,
:dup, :add, :dup, :add, :dup, :add,
:dup, :add, :dup, :add, :dup, :add,
# == pos 73..74: store budget in slot[0] =============================
:push0, :store,
```

Push 1, then `:dup; :add` six times: 1 → 2 → 4 → 8 → 16 → 32 → 64. Thirteen
opcodes for a constant with no single-opcode encoding. `push0; store` writes
`slots[0] ← 64`. N's lifetime ended when the copy loop finished; slot[0] is
free to become the forage counter — two non-overlapping lifetimes in one slot.
Cross-reference: doubling chain, chapter 05
([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)).


### pos 75..78 — FORAGE anchor `[nop_1, nop_0, nop_0, nop_0]`

```elixir
# == pos 75..78: FORAGE anchor [n1, n0, n0, n0] ======================
:nop_1, :nop_0, :nop_0, :nop_0,
```

Top of the forage loop. Jumped back to from pos 94–98 with complement template
`[nop_0, nop_1, nop_1, nop_1]`. Cross-reference: chapter 04
([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 79..81 — exit when the budget is spent

```elixir
# == pos 79..80: load budget for exit check ==========================
:push0, :load,
# == pos 81..85: jz_t -> budget spent? back to HEAD to replicate =====
:jz_t, :nop_0, :nop_0, :nop_0, :nop_0,
```

`push0; load` reloads the budget; `:jz_t` jumps to `HEAD` (complement
`[nop_1, nop_1, nop_1, nop_1]`) when it reaches 0, starting the next
replication cycle. Cross-reference: chapter 04
([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 86..87 — forage body: eat, move

```elixir
# == pos 86..87: forage - eat then advance ===========================
:eat, :move,
```

`:eat` collects food (up to `eat_amount`, default 50); `:move` steps forward
(blocked → no-op). Ancestor forages by ploughing straight ahead — the
deterministic post-divide turn already chose a fresh heading each generation.
Cross-reference: chapter 03 ([03-first-codeome.md](03-first-codeome.md)).


### pos 88..98 — decrement budget, loop back to FORAGE

```elixir
# == pos 88..93: decrement budget (slot[0] -= 1) =====================
:push0, :load, :push1, :sub, :push0, :store,
# == pos 94..98: jmp_t -> back to FORAGE =============================
:jmp_t, :nop_0, :nop_1, :nop_1, :nop_1,
```

Standard slot-decrement, then an unconditional `:jmp_t` back to `FORAGE` at pos
75 until the budget hits 0 (64 iterations). Cross-reference: chapter 05
([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)); chapter 04
([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 99 — SEPARATOR `:push0`

```elixir
# == pos 99: separator (guards the ring wrap into HEAD) ==============
:push0,
```

**Robustness addition 2c.** In a 100-opcode ring, pos 99 wraps directly to pos
0. Without this separator, the `jmp_t FORAGE` template (four nops at 95–98)
and the `HEAD` anchor (four nops at 0–3) would be contiguous and the extractor
would read eight nops. The subtlest separator: the adjacency is invisible in a
linear listing. Cross-reference: chapter 04
([04-loops-and-templates.md](04-loops-and-templates.md)).

---

## 4. The robustness additions

These distinguish `Ancestor` from the chapter-07 sustainable replicator.

**1. Allocate-failure handling (pos 10..14).** The `:jz_t` after `:allocate`
lets the parent skip the copy loop when the front cell is occupied, jumping
straight to the forage block. No corrupt writes into occupied or non-existent
child buffers in dense worlds.

**2. ABORT as a dual-purpose anchor (pos 56..59).** The post-divide
fall-through position doubles as the abort landing pad. Both paths need the
same follow-on behaviour, so zero extra opcodes are spent on a separate
landing anchor.

**3. Two `:push0` separators (pos 49 and 99).** Both prevent the template
extractor from reading across adjacent nop blocks. The pos 99 separator is the
subtler one: it guards the ring wrap, a boundary invisible in a linear source
listing.

A fourth design choice keeps the codeome small: the **single-slot down-counter**.
By using one value as counter *and* address, `Ancestor` never needs a second
slot or a reload of `N` inside the copy loop.

---

## 5. Energy balance (recap from chapter 08)

Full derivation in chapter 08 ([08-energy-economy.md](08-energy-economy.md)).

| Quantity | Value |
|---|---|
| Codeome length | 100 opcodes |
| Copy loop cost (≈ 5 energy/opcode × 100) | ≈ 500 |
| Setup + allocate + divide + turn overhead | ≈ 24 |
| **Total per-cycle replication cost** | **≈ 524** |
| Forage body cost per iteration (load + jz + eat + move + decrement + jmp) | 6.9 energy |
| Forage gain per iteration at 100% food hit rate | 20 energy |
| Net gain per iteration at 100% hit rate | ≈ +13.1 |
| K = 64 iterations × net gain | ≈ +838 per cycle |
| Break-even hit rate (gain ≥ cost per cycle) | **≈ 0.76** |
| Steady-state parent energy (100% hit) | **≈ 1150** |

After `:divide` energy is halved; one forage run nets ~836. The fixed point of
`E_new = (E − 524)/2 + 836` is `E ≈ 1150`. Below a food-hit rate of ~0.76 the
cycle no longer nets positive and the lineage cannot sustain itself — chapter 08
derives this in full.

---

## 6. Predation as an opcode, not a creature

The seed ladder contains no predator: its four rungs are about computational
architecture (reflex → replication → structure → introspection/HGT), not
ecological role. Predation is still available to any codeome you write in the
editor through two opcodes.

From `config/runtime.exs` and `lib/lenies/codeome/costs.ex`:

| Parameter | Value |
|---|---|
| `:attack` opcode cost | 5.0 energy |
| `attack_damage` | 10 energy transferred victim → attacker |
| `:defend` opcode cost | 2.0 energy |
| `defense_attacker_penalty` | 5 energy extra cost if the victim used `:defend` within the window |

`:attack` strikes the cell ahead; if a Lenie is there, energy is transferred to
the attacker (the reward arrives asynchronously). If the target recently
`:defend`-ed, the attacker pays an extra penalty. Both opcodes yield to the
world like `:eat` and `:move`.

- **Net per successful attack (victim undefended):** gain 10 − pay 5 = **+5**.
- **Net if the victim used `:defend`:** gain 10 − pay 5 − penalty 5 = **0**.
- **Net when nobody is in front:** 0 − pay 5 = **−5 wasted**.

To build a predator, drop an `:attack` immediately before the `:eat` in a
replicator's forage body (so it strikes whatever it is about to graze).
Sustainability is then density-dependent: in a sparse world the wasted strikes
cancel food gain; in a crowded world the +5 per kill adds up. See chapter 11
([11-cookbook.md](11-cookbook.md)) for the recipe.

---

## 7. Panoramic comparison table

### Teaching codeomes (chapters 3–7)

These are built step by step as you learn; they are exercises, not shipped
seeds.

| Codeome | Ops | Key idiom introduced | Replicates? | Sustainable? | Notes |
|---|---|---|---|---|---|
| Crawler (ch 03) | ~7 | Loop via anchor + template | No | No | Blind move-eat baseline |
| Stepper (ch 05) | ~40 | Slot-based counter loop | No | No | Introduces slots |
| Wanderer (ch 05) | ~55 | Fair-coin random branch | No | Maybe | First random behaviour |
| Subroutine Crawler (ch 06) | ~44 | `call_t` / `ret` procedures | No | Maybe | First modular codeome |
| Mini-replicator (ch 07) | ~44 | allocate / write_child / divide | Yes (once) | No | Proof-of-concept division |
| Sustainable replicator (ch 07) | ~95 | Forage cycle between divides | Yes | Yes | K=64, no abort guard |

### Shipped seeds — the capability ladder (`lib/lenies/codeomes/*.ex`)

| Rung | Codeome | Ops | Signature idea | Replicates? | Reference |
|---|---|---|---|---|---|
| 1 | **Reflex** | 49 | sense→branch reflex; no memory, no replication | No (mortal) | Core War Imp; Braitenberg |
| 2 | **Ancestor** | 100 | single-slot down-counter copy loop | Yes | Tierra ancestor; von Neumann |
| 3 | **Architect** | 173 | nested `call_t`/`ret` subroutines (the call stack) | Yes | Dijkstra; modular genomes |
| 4 | **Symbiont** | 118 | age clock + `make_plasmid` + `conjugate` (HGT) | Yes | Lederberg–Tatum; *lac* operon |

---

## 8. What's next

Every recurring idiom — anchors, slot counters, doubling chains, dual-purpose
anchors, ring-wrap separators, the single-slot copy loop — has appeared in the
context of a real, running, tuned codeome. The replication arc is complete.

`Architect` (rung 3) takes the very same allocate/copy/divide machinery
dissected here and wraps it in `call_t`/`ret` subroutines (chapter 06);
`Symbiont` (rung 4) adds a self-minted plasmid and horizontal transfer.

→ Next: Chapter 10 covers conjugation and plasmids in full, dissecting
`Symbiont` ([10-conjugation-and-plasmids.md](10-conjugation-and-plasmids.md));
Chapter 11 collects the recurring idioms as a quick-reference cookbook
([11-cookbook.md](11-cookbook.md)).
