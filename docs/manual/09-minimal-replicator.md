# Chapter 9 — The MinimalReplicator Dissected

## 1. Why this matters

`MinimalReplicator` is the canonical hand-tuned replicator bundled with
Lenies — the reference against which new codeomes are benchmarked.

Every idiom introduced in chapters 03–07 appears in its 123 opcodes:
anchor-based loops (chapter 04), slot-based counters (chapter 05), the
doubling chain for large constants (chapter 05), the `read_self` /
`write_child` copy idiom (chapter 07). What the chapter-07 sustainable
replicator left as an exercise — graceful handling of a busy front cell —
`MinimalReplicator` solves with one extra jump and a dual-purpose anchor.

---

## 2. The shape, at a glance

- **123 opcodes total** (positions 0–122, ring-indexed).
- **6 named anchors** (4-bit `nop_0`/`nop_1` sequences):
  `LOOP_HEAD`, `COPY_LOOP_HEAD`, `ABORT_TARGET`, `TURN_LEFT_ANCHOR`,
  `SKIP_TURN_ANCHOR`, `FORAGE_LOOP_HEAD`.
- **Two `:push0` separators** at positions 67 and 122, preventing the
  template extractor from reading across adjacent nop blocks.
- **K = 128 forage iterations** between division attempts (vs K = 64 in the
  chapter-07 sustainable replicator).
- **Allocate-failure handling** via `:jz_t` at positions 10–14 — the
  chapter-07 mini-replicator had no such guard.

---

## 3. Section-by-section dissection

### pos 0..3 — LOOP_HEAD anchor `[nop_1, nop_1, nop_1, nop_1]`

```elixir
# ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──────────────────────
:nop_1, :nop_1, :nop_1, :nop_1,
```

Entry point of the main cycle. The all-ones pattern is unique among the six
anchors, guaranteeing no false match anywhere in the codeome. Jumps to
`LOOP_HEAD` carry complement template `[nop_0, nop_0, nop_0, nop_0]`.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 4..6 — get own size N, store in slot[0]

```elixir
# ── pos 4..6: get own size N, store in slot[0] ───────────────────────
:get_size, :push0, :store,
```

`:get_size` pushes 123; `:store` writes `slots[0] ← 123`. Slot[0] serves
double duty — holds N here, then the forage counter K at pos 92–93;
the lifetimes never overlap. Cross-reference: chapter 05
([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)).


### pos 7..9 — allocate child slot of size N in front cell

```elixir
# ── pos 7..9: allocate child slot of size N in front cell ────────────
:push0, :load, :allocate,
```

`push0; load` reloads N from slot[0]. `:allocate` reserves a write buffer
of size N in the front cell. Pushes 1 on success, 0 on failure.
Cross-reference: allocate semantics, chapter 07
([07-replication.md](07-replication.md)).


### pos 10..14 — jz_t to ABORT_TARGET if allocate failed

```elixir
# ── pos 10..14: jz_t → if allocate failed, jump to ABORT_TARGET ──────
:jz_t, :nop_0, :nop_0, :nop_1, :nop_1,
```

**Robustness addition 1.** If allocate returned 0, jumps to `ABORT_TARGET`
at pos 47 (complement `[nop_1, nop_1, nop_0, nop_0]`), skipping the copy
loop and `:divide` entirely. The chapter-07 mini-replicator omitted this and
risked writing into an occupied buffer. Cross-reference: chapter 04
([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 15..17 — init copy counter slot[1] = 0

```elixir
# ── pos 15..17: init copy counter slot[1] = 0 ────────────────────────
:push0, :push1, :store,
```

Writes `slots[1] ← 0`. Slot[1] is the copy-loop index.
Cross-reference: chapter 05 ([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)).


### pos 18..21 — COPY_LOOP_HEAD anchor `[nop_1, nop_0, nop_0, nop_1]`

```elixir
# ── pos 18..21: COPY_LOOP_HEAD anchor [n1, n0, n0, n1] ───────────────
:nop_1, :nop_0, :nop_0, :nop_1,
```

Top of the per-opcode copy loop. The `jnz_t` at pos 41–45 jumps back here
with complement template `[nop_0, nop_1, nop_1, nop_0]`.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 22..24 — read opcode at counter (slot[1])

```elixir
# ── pos 22..24: read opcode at counter ───────────────────────────────
:push1, :load, :read_self,
```

`push1; load` pushes `slots[1]` (copy index `i`). `:read_self` pops `i`
and pushes the integer encoding of the opcode at position `i` in the
parent's own codeome.
Cross-reference: `read_self` semantics, chapter 07
([07-replication.md](07-replication.md)).


### pos 25..29 — write opcode to child at counter

```elixir
# ── pos 25..29: write opcode to child at counter ─────────────────────
:push1, :load, :swap, :write_child, :drop,
```

After pos 22–24 the stack holds `[opcode_int]`. `push1; load` pushes `i`;
`:swap` brings `opcode_int` to the top for `:write_child` (which pops opcode
then address). `:drop` discards the status. This is the canonical
write-child idiom. Cross-reference: chapter 07
([07-replication.md](07-replication.md)).


### pos 30..45 — increment counter, test, loop back

```elixir
# ── pos 30..35: increment counter slot[1] += 1 ───────────────────────
:push1, :load, :push1, :add, :push1, :store,
# ── pos 36..40: loop condition (N - (counter+1) != 0?) ───────────────
:push0, :load, :push1, :load, :sub,
# ── pos 41..45: jnz_t → back to COPY_LOOP_HEAD if not done ───────────
:jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,
```

Pos 30–35: standard slot-increment (load, add 1, store). Pos 36–40:
`:sub` computes `N − counter` (`second − top`); zero when `counter == N`.
Pos 41–45: `:jnz_t` loops back to `COPY_LOOP_HEAD`; falls through to
`:divide` when zero.
Cross-reference: chapter 05 ([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md));
chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 46 — divide

```elixir
# ── pos 46: divide ───────────────────────────────────────────────────
:divide,
```

Seals the child buffer and spawns a new Lenie in the front cell. Parent
slots and stack are unchanged; execution falls through to pos 47.
Cross-reference: chapter 07 ([07-replication.md](07-replication.md)).


### pos 47..50 — ABORT_TARGET anchor `[nop_1, nop_1, nop_0, nop_0]`

```elixir
# ── pos 47..50: ABORT_TARGET anchor [n1, n1, n0, n0] ─────────────────
# Landing pad for both jz_t (allocate failed) and fall-through after divide.
:nop_1, :nop_1, :nop_0, :nop_0,
```

**Robustness addition 2.** Dual-purpose anchor: the `:jz_t` at pos 10–14
jumps here when allocation fails; `:divide` at pos 46 falls through here on
success. Both paths need the same next action (random turn + forage), so no
extra opcodes are spent on a separate landing anchor.
Cross-reference: anchor reuse, chapter 04
([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 51..55 — random turn: r := pushN; stack ← (r mod 2)

```elixir
# ── pos 51..55: r := pushN; stack ← (r mod 2) ────────────────────────
:pushN, :push1, :push1, :add, :mod,
```

`:pushN` pushes a random integer 0..255. `push1; push1; add` builds 2.
`:mod` computes `r mod 2` — a fair coin (0 or 1). Building 2 as
`push1 + push1 + add` is the standard idiom; there is no single-opcode
literal for N > 1.
Cross-reference: fair-coin random branch, chapter 05
([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)).


### pos 56..60 — jz_t to TURN_LEFT_ANCHOR if coin == 0

```elixir
# ── pos 56..60: jz_t → if 0, jump to TURN_LEFT_ANCHOR ────────────────
:jz_t, :nop_1, :nop_0, :nop_1, :nop_1,
```

Coin 0 → jumps to `TURN_LEFT_ANCHOR` at pos 68 (complement
`[nop_0, nop_1, nop_0, nop_0]`). Coin 1 → falls through to `:turn_right`.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 61 — turn_right; pos 62..66 — jmp_t to SKIP_TURN_ANCHOR

```elixir
# ── pos 61: turn_right (executed when r mod 2 == 1) ──────────────────
:turn_right,

# ── pos 62..66: jmp_t → skip turn_left branch ────────────────────────
:jmp_t, :nop_1, :nop_1, :nop_0, :nop_1,
```

`:turn_right` rotates 90° clockwise away from the newborn child. The
`:jmp_t` jumps to `SKIP_TURN_ANCHOR` at pos 73 (complement
`[nop_0, nop_0, nop_1, nop_0]`), bypassing the left-turn branch.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 67 — SEPARATOR `:push0`

```elixir
# ── pos 67: separator (dead code, never executed) ────────────────────
:push0,
```

**Robustness addition 3a.** Without this separator, the four nops of the
`jmp_t` template (pos 63–66) are adjacent to the four nops of
`TURN_LEFT_ANCHOR` (pos 68–71). The extractor (max 8 nops) would absorb all
eight and produce a template matching nothing. This `:push0` stops it at 4.
Dead code: `:jmp_t` at 62 jumps past it; pos 68 is entered only from pos 56.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 68..71 — TURN_LEFT_ANCHOR; pos 72 — turn_left

```elixir
# ── pos 68..71: TURN_LEFT_ANCHOR [n0, n1, n0, n0] ────────────────────
:nop_0, :nop_1, :nop_0, :nop_0,

# ── pos 72: turn_left (executed when r mod 2 == 0) ───────────────────
:turn_left,
```

Target of the `:jz_t` at pos 56–60. `:turn_left` rotates 90°
counter-clockwise. Execution falls through to `SKIP_TURN_ANCHOR`.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 73..76 — SKIP_TURN_ANCHOR `[nop_0, nop_0, nop_1, nop_0]`

```elixir
# ── pos 73..76: SKIP_TURN_ANCHOR [n0, n0, n1, n0] ────────────────────
:nop_0, :nop_0, :nop_1, :nop_0,
```

Convergence point: the right-turn path jumps here, the left-turn path falls
through. The canonical two-branch merge — one branch jumps over the other
and lands on the shared anchor immediately after it.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 77..91 — build K=128 on stack

```elixir
# ── pos 77..91: build K=128 on stack ─────────────────────────────────
# push1 (=1), then 7 doublings via dup+add: 2, 4, 8, 16, 32, 64, 128
:push1,
:dup, :add, :dup, :add, :dup, :add, :dup, :add,
:dup, :add, :dup, :add, :dup, :add,
```

Push 1, then `:dup; :add` seven times: 1 → 2 → 4 → 8 → 16 → 32 → 64 → 128.
15 opcodes for a constant with no single-opcode encoding. The chapter-07
replicator used K = 64 (six doublings); one extra pair roughly doubles energy
gathered per generation. Cross-reference: doubling chain, chapter 05
([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)).


### pos 92..93 — store K in slot[0]

```elixir
# ── pos 92..93: store K in slot[0] ───────────────────────────────────
:push0, :store,
```

Writes `slots[0] ← 128`. N's lifetime ended when the copy loop finished;
pos 4–6 overwrites slot[0] with N again at the next cycle start — two
non-overlapping lifetimes in one slot. Cross-reference: chapter 05
([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md)).


### pos 94..97 — FORAGE_LOOP_HEAD anchor `[nop_0, nop_1, nop_0, nop_1]`

```elixir
# ── pos 94..97: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
:nop_0, :nop_1, :nop_0, :nop_1,
```

Top of the forage loop. The alternating `0,1,0,1` pattern is unique among
all six anchors. Jumped back to from pos 112–116 with complement template
`[nop_1, nop_0, nop_1, nop_0]`.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 98..101 — forage body: sense_front, drop, eat, move

```elixir
# ── pos 98..101: forage body — sense, drop result, eat, move ─────────
:sense_front, :drop, :eat, :move,
```

`:sense_front` is immediately `:drop`-ped — the random turn already chose
the direction. "Defensive front sense" idiom: call it to satisfy the VM,
discard the result. `:eat` collects food (up to 20 energy). `:move` steps
forward; blocked → no-op. Cross-reference: chapter 03
([03-first-codeome.md](03-first-codeome.md)); chapter 04
([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 102..103 — try to infect a neighbour with a plasmid

```elixir
# ── pos 102..103: try to infect a neighbor; drop the result ─────────
:conjugate, :drop,
```

Tucked inside the forage body so it fires on **every** forage iteration —
128 opportunistic horizontal-gene-transfer attempts per generation cycle,
piggy-backing on the same forward sweep that gathers food. There is no
sense-and-branch guard: the codeome simply asks the world "if there's a
neighbour ahead and I'm carrying a plasmid, hand them a copy". This
densely-spammed strategy is what makes plasmids spread through a
MinimalReplicator population in seconds rather than minutes.

`:conjugate` yields to the world (like `:eat` and `:move`): the world
process inspects the front cell and, if a peer Lenie lives there, picks
**one** plasmid uniformly at random from the carrier's buffer and grafts
it into the neighbour. The opcode pushes `1` on a successful transfer
and `0` on any failure path (no neighbour, neighbour already carries
that plasmid, carrier holds no plasmids, etc.). `:drop` then throws the
success flag away — this codeome doesn't react to either outcome, it
just keeps trying on the next iteration.

Energy cost: a flat `4.0` base charged locally, plus a `0.05 ·
plasmid_size` surcharge applied by the world only on success (so a
no-target attempt costs exactly 4.0; transferring the 32-opcode Twitch
plasmid costs `4.0 + 1.6 = 5.6`). A plasmid-free carrier still pays the
4.0 base every iteration — a small but real "vaccination" tax baked into
the reference codeome. Cross-reference: chapter 10
([10-conjugation-and-plasmids.md](10-conjugation-and-plasmids.md)) for
the full plasmid lifecycle, the trailing `:push0` separator pattern, and
the energy accounting that makes this every-iteration spam sustainable.


### pos 104..116 — decrement counter, loop back to FORAGE_LOOP_HEAD

```elixir
# ── pos 104..109: counter := counter - 1 (slot[0]) ───────────────────
:push0, :load, :push1, :sub, :push0, :store,
# ── pos 110..111: load counter for check ─────────────────────────────
:push0, :load,
# ── pos 112..116: jnz_t → back to FORAGE_LOOP_HEAD if counter != 0 ───
:jnz_t, :nop_1, :nop_0, :nop_1, :nop_0,
```

Standard slot-decrement (load, subtract 1, store), reload for the jump.
`:jnz_t` loops back to `FORAGE_LOOP_HEAD` at pos 94 until counter hits 0
(128 iterations), then falls through.
Cross-reference: chapter 05 ([05-memory-and-arithmetic.md](05-memory-and-arithmetic.md));
chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 117..121 — jmp_t back to LOOP_HEAD

```elixir
# ── pos 117..121: jmp_t → back to LOOP_HEAD to retry replication ─────
:jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
```

Template `[nop_0, nop_0, nop_0, nop_0]` jumps to complement
`[nop_1, nop_1, nop_1, nop_1]` — `LOOP_HEAD` at pos 0. One full generation
cycle completes here.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).


### pos 122 — SEPARATOR `:push0`

```elixir
# ── pos 122: separator (dead code, never executed) ───────────────────
:push0,
```

**Robustness addition 3b.** In a 123-opcode ring, pos 121 wraps directly
to pos 0. Without this separator, the `jmp_t` template (four `nop_0` at
118–121) and `LOOP_HEAD` (four `nop_1` at 0–3) would be contiguous and
the extractor would read eight nops — producing a template matching nothing.
The subtlest separator: the adjacency is invisible in a linear listing.
Cross-reference: chapter 04 ([04-loops-and-templates.md](04-loops-and-templates.md)).

---

## 4. The three robustness additions

These distinguish `MinimalReplicator` from the chapter-07 sustainable
replicator.

**1. Allocate-failure handling (pos 10..14).** The `:jz_t` after `:allocate`
lets the parent skip the copy loop when the front cell is occupied, jumping
straight to the random-turn block. Cost: 5 opcodes. Benefit: no corrupt
writes into occupied or non-existent child buffers in dense worlds.

**2. ABORT_TARGET as a dual-purpose anchor (pos 47..50).** The post-divide
fall-through position doubles as the abort landing pad. Both paths need
identical follow-on behaviour, so zero extra opcodes are spent on a separate
landing anchor.

**3. Two `:push0` separators (pos 67 and 122).** Both prevent the template
extractor from reading across adjacent nop blocks and producing an oversized
template that matches no anchor. The pos 122 separator is the subtler one:
it guards the ring wrap, a boundary invisible in a linear source listing.

---

## 5. Energy balance (recap from chapter 08)

Full derivation in chapter 08 ([08-energy-economy.md](08-energy-economy.md)).

| Quantity | Value |
|---|---|
| Codeome length | 123 opcodes |
| Copy loop cost (≈ 6 energy/opcode × 123) | ≈ 738 |
| Allocate + setup + divide overhead | ≈ 33 |
| **Total per-cycle replication cost** | **≈ 759** |
| Forage body cost per iteration | ≈ 8.6 energy |
| Forage gain per iteration at 100% food hit rate | 20 energy |
| Net gain per iteration at 100% hit rate | ≈ +11.4 |
| K = 128 iterations × net gain | ≈ +1459 per cycle |
| Per-cycle gain at 100% hit rate (128 × 20) | 2560 |
| Per-cycle gain at 50% hit rate (128 × 10) | 1280 |
| Break-even hit rate | **≈ 0.69** |
| Steady-state parent energy | **≈ 2160** |

After `:divide` energy is halved; forage adds ~1459. Fixed point of
`E_new = E/2 + 1080` is `E = 2160`. Break-even at 0.69 — replication
sustained even when 31% of cells are empty.

---

## 6. Carnivore: predation as a one-line patch

`Carnivore` (`lib/lenies/codeomes/carnivore.ex`) is `MinimalReplicator`
with `:attack` injected immediately before the first (and only) `:eat`.

```elixir
defp inject_attack([], acc), do: Enum.reverse(acc)

defp inject_attack([:eat | rest], acc) do
  # Found the first :eat — inject :attack before it and return the rest unchanged
  Enum.reverse(acc) ++ [:attack, :eat | rest]
end

defp inject_attack([op | rest], acc) do
  inject_attack(rest, [op | acc])
end
```

`inject_attack/2` walks the list accumulating `acc`. When it hits the first
`:eat`, it reverses `acc`, appends `:attack`, then `:eat` and `rest`
unchanged — the tail is never touched. Result: 124 opcodes, all six anchors
and both separators inherited intact.

**Why this design is interesting.** Predation is a behavioural mutation, not
a separate codeome. The Carnivore shares 123 of its 124 opcodes with
`MinimalReplicator`; children inherit `:attack` and are also Carnivores.

### Attack and defence numerics

From `config/runtime.exs` and `lib/lenies/codeome/costs.ex`:

| Parameter | Value |
|---|---|
| `:attack` opcode cost | 5.0 energy |
| `attack_damage` | 10 energy transferred victim → attacker |
| `defense_attacker_penalty` | 5 energy extra cost if victim used `:defend` within 5 ticks |

- **Net per successful attack (victim undefended):** gain 10 − pay 5 = **+5**.
- **Net if victim used `:defend`:** gain 10 − pay 5 − penalty 5 = **0**.
- **Net when nobody is in front:** 0 − pay 5 = **−5 wasted**.

**Sustainability is density-dependent.** In a sparse world, 128 wasted
attacks per cycle cost 640 extra energy, cancelling food gain. In a dense
world, +5 net × 128 = +640 per cycle on top of food. In equilibrium,
carnivore-heavy worlds are less stable: carnivores can eat herbivores into
extinction and then starve. The Carnivore wins in crowded worlds, loses in
sparse ones.

---

## 7. Panoramic comparison table

### Teaching codeomes (chapters 3-7)

| Codeome | Ops | Non-nops | Key idiom introduced | Replicates? | Sustainable? | Notes |
|---|---|---|---|---|---|---|
| Walker (ch 03) | 16 | 14 | Loop via anchor + template | No | No | Baseline moving agent |
| Teaching Forager (ch 04) | 30 | 10 | Conditional branch on sense | No | Maybe | First eating loop |
| Counter-walker (ch 05) | ~40 | ~14 | Slot-based counter loop | No | No | Introduces slots |
| Turning forager (ch 05) | ~55 | ~18 | Fair-coin random branch | No | Maybe | First random behaviour |
| Subroutine forager (ch 06) | 44 | 12 | `call_t` / `ret` procedures | No | Maybe | First modular codeome |
| Mini-replicator (ch 07) | ~44 | many | allocate / write_child / divide | Yes (once) | No | Proof-of-concept division |
| Sustainable replicator (ch 07) | ~95 | many | Forage cycle between divides | Yes | Yes | K=64, no abort guard |

### Shipped seeds (`lib/lenies/codeomes/*.ex`)

| Codeome | Ops | Non-nops | Key idiom introduced | Replicates? | Sustainable? | Notes |
|---|---|---|---|---|---|---|
| **MinimalReplicator** | **123** | **many** | Alloc-failure guard + dual anchor | **Yes** | **Yes (~2160)** | Production reference |
| **Carnivore** | **124** | **many** | Behavioural mutation via `:attack` | **Yes** | **Density-dependent** | One-opcode patch on MR |
| **Defender** | **93** | **many** | `defend` per iter, K=32, deterministic post-divide turn | **Yes** | **Yes (~+50 margin)** | Drops random-turn machinery to fit K=32 |
| **Forager** (shipped) | **139** | **many** | 3-way `pushN mod 3` random walk every step | **Yes** | **Yes (~+1786)** | Distinct from the chapter-4 teaching Forager |
| **Hunter** | **164** | **many** | L/R alternation via slot parity + lock-on attack | **Yes** | **Yes (~+315)** | sense_front + attack with no move/turn on prey |

---

## 8. What's next

Every recurring idiom — anchors, slot counters, doubling chains, dual-purpose
anchors, ring-wrap separators, copy loops, attack injection — has appeared in
the context of a real, running, tuned codeome. The arc is complete.

The three specialized shipped seeds (Defender, Hunter, Forager) demonstrate
how these patterns combine into distinctive behaviors: K-tuning for clustering,
slot-parity for deterministic alternation, sense+branch for prey detection
with lock-on. See the README's "Built-in seeds" section for short behavioral
descriptions, and `lib/lenies/codeomes/{defender,hunter,forager}.ex` for the
line-by-line source comments.

→ Next: Chapter 10 covers conjugation and plasmids in full
([10-conjugation-and-plasmids.md](10-conjugation-and-plasmids.md)); Chapter 11
collects the recurring idioms as a quick-reference cookbook
([11-cookbook.md](11-cookbook.md)).
