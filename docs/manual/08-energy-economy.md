# Chapter 8 — Energy Economy

Every codeome runs on energy. This chapter gives you the math to understand why your replicator
from Chapter 7 works and how to dimension your own codeomes. No new code — just analysis. The
worked example is `Ancestor` (Chapter 9), the canonical 100-opcode replicator that ships with
Lenies; the Chapter 7 sustainable replicator has the same shape.

---

## 8.1 Every codeome has a budget

Think of a replication cycle as a ledger. On the cost side: every opcode you execute draws energy.
On the gain side: every successful `:eat` empties a cell and banks its contents. The rule is simple:

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

The cost side is exact — opcode counts don't lie. The gain side is where the **energy field**
comes in. A single `:eat` **empties the whole cell**, so each successful bite yields whatever that
cell happens to hold: `0` in a desert, up to the per-cell cap (`3 × eat_amount` = 150 by default)
in a full oasis. There is no fixed per-eat yield to multiply by.

So gain per cycle is the total resource your forager sweeps up over its K `eat; move` steps, and
that depends on two things you do not control directly:

- **Field richness** — how much of the grid is oasis versus desert right now, and how full those
  oasis cells are. The field slowly drifts and cycles, so a patch that is fertile this minute may
  be barren later.
- **Competition** — other Lenies draining the same cells before you reach them. A crowded world
  thins the oases.

The practical consequence is that foraging is **bursty**. A forager that wanders into an oasis
fills up in a handful of bites (each worth up to 150); one stuck in a desert burns its move budget
for nothing. Survival is less about a steady trickle and more about **finding and draining charged
cells faster than you spend energy moving between them** — grazing.

---

## 8.4 Why Ancestor picks K = 64

K is the forage budget — the number of `eat; move` steps between divisions. It has to be large
enough to cross the lean stretches between oases without the parent starving, and to bank the
~969-energy cycle cost plus a divide surplus. Because a single oasis bite now returns up to 150
energy, a forager in a rich field needs far fewer *successful* eats than a fixed-yield model would
suggest — but it still needs enough K to keep moving through deserts until it reaches the next
charged cell.

K = 64 is a sensible budget for a 100-opcode body: long enough to graze across a few zones, short
enough to keep generations fast (shorter cycles adapt faster and bank surplus sooner). It is also
convenient to build exactly via six doublings of `push1`. In a sparse or crowded field you would
want a larger K (more chances to find food); in a consistently rich field a smaller one suffices.

---

## 8.5 Steady-state energy formula

At `:divide`, energy is split evenly. Let C = cost through divide (≈524) and F = net energy banked
during the forage phase (resource swept from grazed cells, minus the forage loop and init cost).
The recurrence still holds structurally:

```
E_{k+1} = (E_k - C) / 2 + F      ->      E_steady = 2F - C
```

The difference from a fixed-yield world is that **F is set by the field, not by a formula**: it
rises in rich, uncrowded conditions and falls in deserts or crowds. A codeome with a high F (an
efficient forager in a generous field) settles at a high steady-state energy; one that barely
covers C declines through repeated divide-halvings until it dies.

The two levers you *do* control are the **replication cost** (keep the copy loop and body tight —
see 8.2) and the **forage efficiency** (a cheap `eat; move` body and good movement, so you actually
reach charged cells). The field — and how crowded the world is — sets the rest.

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

## 8.7 A general rule for "can my codeome survive?"

Putting the two sides together:

```
sustainable  iff   energy swept from grazed cells per cycle  >  cycle cost
```

The **cost side is precise and under your control:**

- `replication_cycle_cost` = setup + allocate + copy loop + divide (≈ 524 for a 100-op codeome;
  scales mainly with length via the copy loop and `allocate` terms). A leaner ~50-op replicator is
  ≈ 280 — it breaks even on far less food.
- `forage_loop_cost` = `K × forage_cost_per_iter` (≈ 6.9 for Ancestor's `eat; move` body; leaner
  bodies cost less).

The **gain side is field-dependent and bursty**, so there is no clean `K_min` table any more: the
same codeome thrives in a rich, uncrowded field and starves in a desert or a crush of competitors.
Three design rules follow:

- **Move well.** Since one bite empties a cell, the bottleneck is *reaching the next charged cell*.
  Efficient turning and movement — not getting wedged against walls or other Lenies — matters more
  than raw eat count.
- **Keep cost low.** Every opcode you cut from the copy loop or forage body lowers the bar your
  foraging has to clear.
- **Right-size K.** Big enough to cross the deserts between oases; not so big that generations
  crawl. Tune it to how rich and crowded your world is.

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
