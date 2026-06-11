# Chapter 8 — Energy Economy

Every codeome runs on energy. This chapter gives you the math to understand why your replicator
from Chapter 7 works and how to dimension your own codeomes. No new code — just analysis. The
worked example is `Ancestor` (Chapter 9), the canonical 100-opcode replicator that ships with
Lenies; the Chapter 7 sustainable replicator has the same shape.

---

## 8.1 Every codeome has a budget

Think of a replication cycle as a ledger. On the cost side: every opcode you execute draws energy.
On the gain side: every successful `:eat` adds energy. The rule is simple:

```
survive long-term  ->  gain per cycle >= cost per cycle
grow the population ->  gain per cycle > cost per cycle (with margin for the divide split)
```

At `:divide`, energy is split evenly between parent and child. If your codeome enters a divide
with energy E, both emerge with E/2. A codeome that breaks even exactly on energy will slowly
decline, because repeated halvings drain any buffer. You need a genuine surplus.

---

## 8.2 Cost breakdown for Ancestor (the sustainable replicator)

`Ancestor` is 100 opcodes. All costs below are derived from
`lib/lenies/codeome/costs.ex` and the actual opcode layout in
`lib/lenies/codeomes/ancestor.ex`.

Exact costs for the one-time setup before the copy loop:

```
HEAD anchor        4 x nop               0.40
Save N             get_size+push0+store  0.90
Allocate(100)      5.0 + 0.05x100       10.00
jz_t alloc check   4-bit template        0.40
Top index N-1      push0+load+push1+sub+push0+store  1.50
```

The `0.05 × N` allocate term means larger codeomes pay proportionally more to reproduce.

### Copy loop (repeated N = 100 times)

`Ancestor` uses a **single-slot down-counter** that doubles as the copy address — no separate
index variable, no per-iteration reload of N. Each iteration costs:

| Step | Opcodes | Cost |
|------|---------|------|
| Copy own[i] → child[i] | push0, load, dup, read_self, write_child, drop | 2.1 |
| Zero test | push0, load, jz_t (4-bit template) | 1.0 |
| Decrement index | push0, load, push1, sub, push0, store | 1.5 |
| Loop back | jmp_t (4-bit template) | 0.4 |
| **Per-iteration total** | | **5.0** |

Full copy loop: `5.0 × 100 = 500 energy`. (The `COPY` anchor's four nops are jumped *over* each
iteration — the loop-back lands just past them — so they cost nothing per iteration.)

### Divide

```
divide  10.0 energy
turn_right 0.5 energy
```

### Cost through divide

```
HEAD nops              0.40
save N                 0.90
allocate block        10.00
jz_t check             0.40
top index N-1          1.50
copy loop (100 iters) 500.00
divide                10.00
turn_right             0.50
                      ======
                     523.70 energy   (~524)
```

This is the "replication cycle cost" — the energy spent before the parent and child separate.

### Forage init (build the K=64 budget)

```
ABORT anchor + push1 + 6x(dup+add) + push0 + store   ~2.9 energy
```

### Forage loop body (repeated K = 64 times)

| Step | Opcodes | Cost |
|------|---------|------|
| Exit check | push0, load, jz_t | 1.0 |
| Forage | eat, move | 4.0 |
| Decrement budget | push0, load, push1, sub, push0, store | 1.5 |
| Loop back | jmp_t (4-bit template) | 0.4 |
| **Per-iteration total** | | **6.9** |

Full forage loop: `6.9 × 64 = 441.6 energy`. (The `FORAGE` anchor's nops are jumped over each
iteration, like `COPY`.)

### Full per-cycle cost summary

```
Cost through divide       523.70
Forage init                 2.90
Forage loop (64 x 6.9)    441.60
                          ======
Total per cycle           968.20 energy   (~969)
```

---

## 8.3 Gain per cycle

Each successful `:eat` returns `eat_amount = 20` energy. The forage loop runs K = 64 iterations.
Define `hit_rate` as the fraction of visited cells that have resource when you arrive:

```
gain per cycle = 64 x 20 x hit_rate = 1280 x hit_rate
```

| hit_rate | gain | cost | net |
|----------|------|------|-----|
| 1.00 | 1280 | 969 | +311 |
| 0.80 | 1024 | 969 | +55 |
| 0.76 | ~969 | 969 | ~0 (break-even) |
| 0.50 | 640 | 969 | -329 |

At 50% hit rate the replicator starves. At 80% it survives with a surplus. Hit rate is not a free
parameter — it emerges from radiation replenishment and population pressure. A crowded world
collapses hit rate and triggers crashes.

---

## 8.4 Why Ancestor picks K = 64

The break-even hit rate at K = 64 is ~0.76. That places the operating point inside the sustainable
zone for a well-seeded world while keeping generations short — important because shorter cycles
mean a lineage adapts faster and spends less wall-clock time between divisions. K = 64 is also
convenient to build exactly via six doublings of `push1` — no approximation needed.

With K = 128 the surplus grows and the break-even hit rate drops, but each cycle takes twice as
long in wall-clock time and mutation accumulates faster per unit time. With K = 32 the break-even
rises toward ~0.9 — viable only in a very well-fed world. K = 64 is a deliberate sweet spot for a
100-opcode body.

---

## 8.5 Steady-state energy formula

At `:divide`, energy is split evenly. Let C = cost through divide (524) and F = net forage gain
after divide = `K × eat_amount × hit_rate − forage_loop_cost − forage_init`. The recurrence is:

```
E_{k+1} = (E_k - C) / 2 + F
```

At steady state E_{k+1} = E_k:

```
E_steady = 2F - C
```

For Ancestor at 100% hit rate:

```
F = 64 x 20 - 441.6 - 2.9 = 1280 - 444.5 = 835.5
E_steady = 2 x 835.5 - 524 ~ 1147 energy
```

So a well-fed Ancestor settles around ~1150 energy per generation. E_steady rises with forage net
gain and falls with replication cost — the two levers you tune when designing a codeome.

---

## 8.6 Copy errors and mutation rates

From `runtime.exs`:

```
copy_substitution_rate: 0.005   # 0.5% per opcode copied
copy_insert_rate:       0.0005  # 0.05% per opcode
copy_delete_rate:       0.0005  # 0.05% per opcode
```

For a 100-opcode codeome, each replication produces on average:

```
substitutions:  100 x 0.005  = 0.500 per replication
insertions:     100 x 0.0005 = 0.050
deletions:      100 x 0.0005 = 0.050
=====================================
total:          ~ 0.60 mutations per replication
```

Roughly 1 in every 1.7 replications introduces at least one mutation. Most are silent: anchor
nops, the dead-code separators (pos 49, pos 99), or substitutions that do not change data flow.
A few are fatal — corrupting `:allocate` at pos 9, `:divide` at pos 54, or `:write_child` at pos
29 breaks the replication machinery entirely. Those lineages forage forever and never divide.

**Length vs. mutation robustness:** shorter codeomes see fewer mutations per generation but have
less redundancy, so a higher fraction of mutations are fatal. Longer codeomes accumulate more
mutations per generation but most land in non-critical padding or anchor positions.

---

## 8.7 A general formula for "can my codeome survive?"

```
sustainable  iff

  K x (eat_amount x hit_rate  -  forage_cost_per_iter)  >  replication_cycle_cost
```

Where:

- `K` = number of forage iterations between divisions
- `eat_amount = 20` (default)
- `hit_rate` = fraction of visited cells with resource (world-dependent, typically 0.7–1.0 in
  well-seeded runs)
- `forage_cost_per_iter = 6.9` (for Ancestor's `eat; move` forage body; leaner bodies cost less)
- `replication_cycle_cost` = setup + allocate + copy loop + divide (≈ 524 for a 100-op codeome;
  scales mainly with codeome length via the copy loop and allocate terms)

Solve for the minimum K:

```
K > replication_cycle_cost / (eat_amount x hit_rate - forage_cost_per_iter)
```

At different hit rates (for a 100-op codeome, forage_cost_per_iter = 6.9):

| hit_rate | eat_amount × h | net per iter | K_min |
|----------|----------------|--------------|-------|
| 1.00 | 20.0 | 13.1 | 40 |
| 0.80 | 16.0 | 9.1 | 58 |
| 0.70 | 14.0 | 7.1 | 74 |
| 0.50 | 10.0 | 3.1 | 169 |

At 80% hit rate K = 58 already works; K = 64 gives a small margin. At 70% you would need K = 74,
so a K = 64 Ancestor needs a reasonably well-fed world (hit rate ~0.78+). At 50% you would need
K > 169, making each cycle very slow.

For a leaner ~50-op replicator, `replication_cycle_cost ≈ 280`; at 80% hit rate K_min ≈ 31, so a
short codeome can break even with a much smaller forage budget.

---

## 8.8 Practical tips

- **Keep your copy loop tight.** Every extra opcode in the loop body adds `N × cost` to the copy
  phase. Ancestor's 6-opcode functional copy body (`push0, load, dup, read_self, write_child,
  drop`) is close to the minimum for read-and-write-by-index. The single-slot down-counter avoids
  a second slot and a per-iteration reload of N. Avoid redundant stack shuffles inside the loop.

- **Use the doubling chain for constants.** Building K = 64 with `push1; dup; add; …` (13 ops,
  ~1.9 energy) is exact and cheaper than any arithmetic alternative.

- **Prefer slot-based counters over re-computing.** Storing N once costs 0.9 up front, then only
  0.5 (`:load`) per use. Reusing one slot across two non-overlapping lifetimes (copy index, then
  forage budget) saves a slot entirely.

- **Short codeomes do not need a counted forage loop.** A 20-op codeome with a few inline
  `:eat; :move` ops can break even without the overhead of a counter, init block, and
  template-based jumps. The counted forage pattern mainly pays for codeomes of 50+ ops.

- **Watch for hidden wall-clock cost.** `:sense_front` (0.5 energy) also synchronously queries
  the World — the lenie process blocks until the reply arrives. Frequent senses slow your lenie
  in real time even when the energy math looks fine.

- **Attack changes the energy landscape.** `:attack` costs 5.0 energy to the attacker and inflicts
  `attack_damage = 10` on the target. If predatory codeomes are present, factor in occasional
  damage when sizing your forage surplus. (See Chapter 9 §6 for the predation numerics.)

---

## 8.9 What's next

→ Next: Chapter 9 dissects `Ancestor`, the canonical replicator that ships with Lenies.
([09-ancestor.md](09-ancestor.md))
