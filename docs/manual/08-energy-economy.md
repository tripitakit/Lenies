# Chapter 8 — Energy Economy

Every codeome runs on energy. This chapter gives you the math to understand why your replicator
from Chapter 7 works and how to dimension your own codeomes. No new code — just analysis.

---

## 8.1 Every codeome has a budget

Think of a replication cycle as a ledger. On the cost side: every opcode you execute draws energy.
On the gain side: every successful `:eat` adds energy. The rule is simple:

```
survive long-term  →  gain per cycle ≥ cost per cycle
grow the population →  gain per cycle > cost per cycle (with margin for the divide split)
```

At `:divide`, energy is split evenly between parent and child. If your codeome enters a divide
with energy E, both emerge with E/2. A codeome that breaks even exactly on energy will slowly
decline, because repeated halvings drain any buffer. You need a genuine surplus.

---

## 8.2 Cost breakdown for the sustainable replicator (Chapter 7)

The Chapter 7 replicator is structurally identical to `MinimalReplicator` (121 opcodes). All
costs are exact, derived from `lib/lenies/codeome/costs.ex` and the actual opcode layout.

Exact costs for the one-time setup before the copy loop:

```
LOOP_HEAD anchor   4 × nop              0.40
Init block         get_size+push0+store 0.90
Allocate(121)      5.0 + 0.05×121      11.05
jz_t alloc check   4-bit template       0.40
Copy counter init  push0+push1+store    0.70
```

The `0.05 × N` allocate term means larger codeomes pay proportionally more to reproduce.

### Copy loop (pos 18–45, repeated N = 121 times)

Each iteration executes the COPY_LOOP_HEAD anchor (4 nops, 0.4) plus:

| Step | Opcodes | Cost |
|------|---------|------|
| Loop head anchor | 4 × nop | 0.4 |
| Read opcode at counter | push1, load, read_self | 0.9 |
| Write to child | push1, load, swap, write_child, drop | 1.8 |
| Increment counter | push1, load, push1, add, push1, store | 1.5 |
| Loop condition | push0, load, push1, load, sub | 1.4 |
| Branch back | jnz_t (4-bit template) | 0.4 |
| **Per-iteration total** | | **6.4** |

Full copy loop: `6.4 × 121 = 774.4 energy`

The moduledoc quotes "~6.8/iter" — that approximate figure is for the full 123-opcode
plasmid-carrying codeome (which adds the in-forage `:conjugate, :drop` pair, covered in
Chapter 10). The precise per-iteration copy cost from `costs.ex` for the 121-opcode
plasmid-free replicator analysed here is 6.4.

### Divide (pos 46)

```
divide  10.0 energy
```

### Cost through divide

```
LOOP_HEAD nops         0.40
init block             0.90
allocate block        11.05
jz_t check             0.40
copy counter init      0.70
copy loop (121 iters) 774.40
divide                10.00
                      ──────
                      797.85 energy
```

This is the "replication cycle cost" — the energy spent before the parent and child separate.

### Turn block (pos 47–76) and forage init (pos 77–93)

After divide (or allocate failure), the codeome picks a random turn direction then initialises
the forage counter. Both are one-time costs per cycle:

```
ABORT_TARGET anchor + random turn decision + branch   2.8 energy
Forage init: push1 + 7×(dup+add) + push0 + store     2.8 energy
```

### Forage loop body (pos 94–114, repeated K = 128 times)

| Step | Opcodes | Cost |
|------|---------|------|
| FORAGE_LOOP_HEAD anchor | 4 × nop | 0.4 |
| Sense, discard, eat, move | sense_front, drop, eat, move | 4.6 |
| Decrement counter | push0, load, push1, sub, push0, store | 1.5 |
| Load counter for check | push0, load | 0.6 |
| Branch back | jnz_t (4-bit template) | 0.4 |
| **Per-iteration total** | | **7.5** |

Full forage loop: `7.5 × 128 = 960.0 energy`
Forage total (init + loop): `2.8 + 960.0 = 962.8 energy`

### Final jump back to LOOP_HEAD (pos 115–119): `0.4 energy`

### Full per-cycle cost summary

```
LOOP_HEAD nops              0.40
Init block                  0.90
Allocate(121)              11.05
jz_t (alloc check)          0.40
Copy counter init            0.70
Copy loop (121 × 6.4)      774.40
Divide                      10.00
Turn block                   2.80
Forage init                  2.80
Forage loop (128 × 7.5)    960.00
Final jmp_t                  0.40
                           ──────
Total per cycle           1763.85 energy
```

All numbers are exact, derived directly from `costs.ex` and the opcode layout in
`minimal_replicator.ex`.

---

## 8.3 Gain per cycle

Each successful `:eat` returns `eat_amount = 20` energy. The forage loop runs K = 128 iterations.
Define `hit_rate` as the fraction of visited cells that have resource when you arrive:

```
gain per cycle = 128 × 20 × hit_rate = 2560 × hit_rate
```

| hit_rate | gain | cost | net |
|----------|------|------|-----|
| 1.00 | 2560 | 1764 | +796 |
| 0.80 | 2048 | 1764 | +284 |
| 0.69 | ~1767 | 1764 | ~0 (break-even) |
| 0.50 | 1280 | 1764 | -484 |

At 50% hit rate the replicator starves. At 80% it survives with a moderate surplus. Hit rate is
not a free parameter — it emerges from radiation replenishment (`radiation_per_tick = 500` across
a 256×256 grid) and population pressure. A crowded world collapses hit rate and triggers crashes.

---

## 8.4 Why MinimalReplicator picks K = 128

The break-even hit rate for K = 128 is ~0.69. That value places the operating point comfortably
into the sustainable zone for most world conditions. K = 128 is also convenient to build exactly
via seven doublings of `push1` — no approximation needed.

With K = 64, break-even rises to ~0.87 — viable only in a very well-fed world. With K = 256,
the surplus grows but each cycle takes twice as long in wall-clock time and mutation accumulates
faster per unit time. K = 128 is a deliberate sweet spot.

The moduledoc states `Forage per cycle: … ≈ 13.4/iter`, but that figure includes the in-forage
`:conjugate, :drop` pair of the full plasmid-carrying codeome (Chapter 10). The precise figure
from `costs.ex` for the plasmid-free forage body analysed here is 7.5/iter; use 7.5 in your own
calculations.

---

## 8.5 Steady-state energy formula

At `:divide`, energy is split evenly. Let C = cost through divide (797.85) and F = net forage
gain after divide = `K × eat_amount × hit_rate − forage_and_turn_cost`. The recurrence is:

```
E_{k+1} = (E_k − C) / 2 + F
```

At steady state E_{k+1} = E_k:

```
E_steady = 2F − C
```

For MinimalReplicator at 100% hit rate:

```
F = 128 × 20 − 966 = 2560 − 966 = 1594
E_steady = 2 × 1594 − 798 ≈ 2390 energy
```

The moduledoc gives a different steady-state estimate (≈ +805 surplus per generation) because it
models the full 123-opcode plasmid-carrying codeome with its extra `:conjugate` costs and a lower
per-iteration net gain. The precise figures from `costs.ex` for the plasmid-free 121-opcode
replicator analysed here give E_steady ≈ 2390. Both agree on the shape: E_steady rises with
forage net gain and falls with replication cost.

---

## 8.6 Copy errors and mutation rates

From `runtime.exs`:

```
copy_substitution_rate: 0.005   # 0.5% per opcode copied
copy_insert_rate:       0.0005  # 0.05% per opcode
copy_delete_rate:       0.0005  # 0.05% per opcode
```

For a 121-opcode codeome, each replication produces on average:

```
substitutions:  121 × 0.005  = 0.605 per replication
insertions:     121 × 0.0005 = 0.061
deletions:      121 × 0.0005 = 0.061
─────────────────────────────────────
total:          ≈ 0.73 mutations per replication
```

Roughly 1 in every 1.4 replications introduces at least one mutation. Most are silent: anchor
nops, dead-code separators (pos 67, pos 120), or substitutions that do not change data flow.
A few are fatal — corrupting `:allocate` at pos 9, `:divide` at pos 46, or `:write_child` at
pos 28 breaks the replication machinery entirely. Those lineages forage forever and never divide.

**Length vs. mutation robustness:** shorter codeomes see fewer mutations per generation but have
less redundancy, so a higher fraction of mutations are fatal. Longer codeomes accumulate more
mutations per generation but most land in non-critical padding or anchor positions.

---

## 8.7 A general formula for "can my codeome survive?"

```
sustainable  iff

  K × (eat_amount × hit_rate  −  forage_cost_per_iter)  >  replication_cycle_cost
```

Where:

- `K` = number of forage iterations between divisions
- `eat_amount = 20` (default)
- `hit_rate` = fraction of visited cells with resource (world-dependent, typically 0.7–1.0 in
  well-seeded runs)
- `forage_cost_per_iter = 7.5` (for the standard 10-opcode forage body used in MinimalReplicator;
  leaner bodies cost less)
- `replication_cycle_cost` = init + allocate + copy loop + divide (≈ 798 for a 121-op codeome;
  scales mainly with codeome length via the copy loop and allocate terms)

Solve for the minimum K:

```
K > replication_cycle_cost / (eat_amount × hit_rate − forage_cost_per_iter)
```

At different hit rates (for a 121-op codeome, forage_cost_per_iter = 7.5):

| hit_rate | eat_amount × h | net per iter | K_min |
|----------|----------------|--------------|-------|
| 1.00 | 20.0 | 12.5 | 64 |
| 0.80 | 16.0 | 8.5 | 94 |
| 0.70 | 14.0 | 6.5 | 123 |
| 0.50 | 10.0 | 2.5 | 320 |

At 80% hit rate K = 94 already works; K = 128 gives a comfortable margin. At 50% hit rate you
would need K > 320, making each cycle very slow. This is why the default world uses
`initial_resource_per_cell: 30` and `radiation_per_tick: 500` — those values keep hit rate
well above 0.69 in the early game.

For a 50-op codeome, `replication_cycle_cost ≈ 340` (copy loop 320 + other 20). At 80% hit
rate K_min ≈ 40, so K = 64 is comfortable.

---

## 8.8 Practical tips

- **Keep your copy loop tight.** Every extra opcode in the loop body adds `N × cost` to the copy
  phase. The 6-opcode functional body in MinimalReplicator is close to the minimum for
  read-modify-write-increment-check-branch. Avoid redundant stack shuffles inside the loop.

- **Use the doubling chain for constants.** Building K = 128 with `push1; dup; add; …` (17 ops,
  2.8 energy) is exact and cheaper than any arithmetic alternative.

- **Prefer slot-based counters over re-computing.** Storing N once in slot[0] costs 0.9 up front,
  then only 0.5 (`:load`) per loop iteration. Calling `get_size` every iteration avoids the slot
  but adds stack management complexity.

- **Short codeomes do not need a counted forage loop.** A 20-op codeome with a few inline
  `:eat; :move` ops can break even without the overhead of a counter, init block, and
  template-based jumps. The counted forage pattern mainly pays for codeomes of 50+ ops.

- **Watch for hidden wall-clock cost.** `:sense_front` (0.5 energy) also synchronously queries
  the World GenServer — the lenie process blocks until the reply arrives. Frequent senses slow
  your lenie in real time even when the energy math looks fine.

- **Attack changes the energy landscape.** `:attack` costs 5.0 energy to the attacker and inflicts
  `attack_damage = 10` on the target. If predatory codeomes are present, factor in occasional
  damage when sizing your forage surplus.

---

## 8.9 What's next

→ Next: Chapter 9 dissects the canonical MinimalReplicator that ships with Lenies. ([09-minimal-replicator.md](09-minimal-replicator.md))
