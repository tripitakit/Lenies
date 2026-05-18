# Specialised Seeds — Design

## Goal

Replace the `:random` seed (which almost never replicates and serves only
as a "fragility baseline") with three hand-written, ecologically distinct
codeomes that exercise different VM techniques and create observable
interactions on the dashboard map when seeded together:

- **Defender** — pacifist herbivore with pseudo-random movement, hard
  for a predator to track.
- **Hunter** — reactive predator with a periodic 360° sweep, attacks
  only when a Lenie is detected.
- **Forager** — adaptive herbivore that abandons exhausted patches
  after a fixed run of low-energy steps.

## Background

The default seed catalog ships two hand-written codeomes
(`MinimalReplicator` — baseline herbivore, `Carnivore` — predator
that attacks blindly every cycle) plus a "Random" entry that builds a
randomised opcode list at startup and is almost guaranteed to be
sterile. The randomised seed is useful exactly once (as a "see how
fragile a naive creature is" demo) and then it's noise in the
dropdown — the user has no reason to spawn it again.

Removing Random and adding three specialised seeds gives the user a
larger palette of ecologically-meaningful starting points and
demonstrates a wider slice of the VM (`sense_front` decision-making,
slot-based counters, periodic scan sub-routines, conditional turn
selection).

## Decisions

1. **Ecological axis**: the three new seeds occupy distinct niches —
   prey (Defender), predator (Hunter), competitor (Forager). Together
   with the existing Minimal Replicator (baseline herbivore) and
   Carnivore (blind predator) they form a 5-species ecology where each
   species has a comparative advantage in a different regime.

2. **All seeds spawn with energy 10000.0** (uniform with the existing
   seeds). Differentiating spawn-energy across seeds would hide the
   per-cycle energetic balance — the property that actually determines
   long-run survival.

3. **MinimalReplicator skeleton** for all three: init → allocate →
   copy loop → divide → post-divide turn → forage loop → jump back.
   The diff lives inside the forage body. Reusing the skeleton means
   each new seed inherits the same replication pattern that has been
   proven viable, and the brain-effort goes into the diff rather than
   re-deriving template addressing from scratch.

4. **Defender = MinimalReplicator + random turn every 5 forage
   steps**. Counter in slot[3], reset on each random turn. `K = 64`
   (half of MR's 128) to keep total per-cycle cost roughly balanced
   after the extra counter machinery (~12 opcodes/iter overhead).
   Visible behaviour: zigzag traffic at the granularity of ~5 cell
   straight runs.

5. **Hunter = MinimalReplicator + 360° sweep every 8 forage steps,
   without the post-divide random turn**. Counter in slot[3]. Every
   8 iterations the seed rotates 4 times left, sensing after each
   turn; the first lenie detected interrupts the sweep and triggers
   `attack`. If no lenie is found in any direction, the four
   `turn_left` calls bring the Lenie back to its starting facing.
   Visible behaviour: short straight runs punctuated by quick spins
   on the spot, then either a sustained chase or a continuation.

6. **Forager = MinimalReplicator + low-energy-step counter that
   forces a random turn after 5 consecutive empty `sense_front`
   sightings**. Counter in slot[3]. `K = 128` (same as MR — the
   counter overhead is amortised because it shares the `sense_front`
   the body already needed).

7. **Forager threshold relaxation** (known limitation): the user
   asked for "low energy = `sense_front < 20`". The Lenies VM has no
   less-than comparison opcode — emulating `< 20` would require ~20
   unrolled `sub`+`jz_t` pairs per forage iteration (~16 energy/iter
   overhead, doubling cycle cost). We relax to T=0 (count only cells
   where `sense_front == 0`, i.e. truly empty). Behaviourally the
   seed still detects and leaves exhausted patches; it just doesn't
   react to merely sparse ones. Adding a `:jlt_t` opcode that pops
   value + threshold from the stack is a possible follow-up (out of
   scope for this spec — would touch opcodes whitelist, dispatch,
   costs, manual, and existing tests).

8. **Hunter's post-divide turn is removed**, so after a successful
   `divide` the parent continues facing the same direction it was
   before allocating the child. The "follow prey" behaviour emerges
   from this stickiness: when the sweep finds prey, the Hunter stops
   turning and ends up facing the prey; subsequent forage moves
   advance toward it until contact, at which point `attack` fires.

9. **No new VM opcodes, no new ETS tables, no new tuning sliders**.
   The whole change is three new `Lenies.Codeomes.*` modules + a
   `Lenies.Seeds` entry swap + three tests.

10. **Test pattern**: each new seed gets its own `*_test.exs`
    following the `MinimalReplicator` test — disable copy errors and
    background mutation, raise `eat_amount` to 50 so the cycle
    completes faster in the test budget, spawn one Lenie on a
    resource-saturated grid, run up to 30 s, assert the population
    reaches generation ≥ 3. Hunter is tested **alone** (no prey on
    the grid) — the sweep finds nothing on every check but the seed
    must still reproduce on the strength of its forage loop.

## Non-goals (this spec)

- Adding a `:jlt_t` (jump-if-less-than) opcode to support stricter
  thresholds in Forager.
- Adding a Programming Manual chapter explaining the three new seeds
  (a follow-up task — the @moduledoc on each new module is the
  reference for now).
- Tuning the default-world parameters so the new seeds dominate or
  fail in interesting ways — the user can experiment via the live
  Tuning panel.
- Edit-in-place / cloning of the new built-in seeds (the existing
  custom-seed flow already covers this via the editor's "Edit"
  button on the species inspector).

## Architecture

### New modules

```
lib/lenies/codeomes/defender.ex
lib/lenies/codeomes/hunter.ex
lib/lenies/codeomes/forager.ex
```

Each exposes:

```elixir
@spec codeome() :: Lenies.Codeome.t()
def codeome, do: Lenies.Codeome.from_list([...])
```

…plus a `@moduledoc` documenting strategy, opcode count, energy
budget, slot usage, and any known limitation (Forager's T=0
relaxation, Hunter's "alone in test" caveat).

### Existing modules touched

```
lib/lenies/seeds.ex
  - drop the `:random` entry from `all/0`
  - drop the private helper `build_random_codeome/0`
  - drop the module attributes `@random_min_len` / `@random_max_len`
  - drop the `alias Lenies.Codeome.Opcodes` if it becomes unused
  - add an alias for `Lenies.Codeomes.{Defender, Hunter, Forager}`
  - add three entries after Carnivore in the dropdown order:
      Minimal Replicator → Carnivore → Defender → Hunter → Forager
```

```
README.md
  - "Built-in seeds" section: expand from 3 (Minimal/Carnivore/Random)
    to 5, drop Random, add one-paragraph description per new seed
    matching the existing style.
```

### Data flow

No new tables, no new events. The added seeds plug into the existing
`Lenies.Seeds.all/0` → dropdown render → `spawn_seed` event in
`ControlsPanelComponent` → `World.spawn_lenie(codeome, opts)` path.

### Codeome skeleton (shared by all three)

```
LOOP_HEAD anchor [4 nops]                              (the outer cycle head)
  Init: get_size, push0, store                         (slot[0] := N)
  Allocate(N)
  jz_t ABORT_TARGET                                    (skip copy if alloc failed)
  Copy counter init: push0, push1, store               (slot[1] := 0)
COPY_LOOP_HEAD anchor [4 nops]
  Read_self, write_child, increment counter
  if counter < N → jump back to COPY_LOOP_HEAD
  divide                                               (parent + child)
ABORT_TARGET anchor [4 nops]                           (landing for both abort and post-divide fallthrough)
  (Defender, Forager: random post-divide turn — pushN, mod 2, jump to TURN_LEFT/RIGHT)
  (Hunter: skip this block entirely — sticky orientation)
  Forage init: push K, store slot[0]                   (K = 64 for Defender, 128 for Hunter and Forager)
  push 0, store slot[3]                                (slot[3] := 0  — per-seed counter)
FORAGE_LOOP_HEAD anchor [4 nops]
  <per-seed forage body — see below>
  decrement slot[0]
  jnz_t FORAGE_LOOP_HEAD
  jmp_t LOOP_HEAD
```

### Per-seed forage bodies

**Defender** — random turn every 5 steps:

```
sense_front; drop; eat; move
load slot[3]; push1; add                  ; counter + 1
dup; push5; mod; jz_t RANDOM_TURN
  push3; store; jmp_t AFTER_TURN          ; counter not yet 5 → just save
RANDOM_TURN:
  drop; push0; push3; store               ; reset counter
  pushN; push2; mod; jz_t TURN_RIGHT
  turn_left; jmp_t AFTER_TURN
TURN_RIGHT:
  turn_right
AFTER_TURN:
```

~22 opcodes per forage body. With K=64: 64 × 22 ≈ 1408 opcodes inside
the forage loop — comparable to MinimalReplicator's 128 × 6 ≈ 768
plus its larger init/divide overhead.

**Hunter** — sweep every 8 steps + sense-then-attack-or-eat:

```
sense_front; dup; jnz_t NOT_EMPTY
  drop; eat; move; jmp_t INCR_COUNTER
NOT_EMPTY:
  dup; push1; add; jz_t LENIE              ; value == -1 → lenie marker
  drop; eat; move; jmp_t INCR_COUNTER
LENIE:
  drop; attack; jmp_t INCR_COUNTER         ; do NOT move — stay oriented
INCR_COUNTER:
  load slot[3]; push1; add; dup
  push8; mod; jz_t DO_SWEEP
  push3; store; jmp_t AFTER_SWEEP
DO_SWEEP:
  drop; push0; push3; store
  turn_left; sense_front; dup; push1; add; jz_t SWEEP_FOUND; drop
  turn_left; sense_front; dup; push1; add; jz_t SWEEP_FOUND; drop
  turn_left; sense_front; dup; push1; add; jz_t SWEEP_FOUND; drop
  turn_left; sense_front; dup; push1; add; jz_t SWEEP_FOUND; drop
  jmp_t AFTER_SWEEP
SWEEP_FOUND:
  drop; attack
AFTER_SWEEP:
```

~50 opcodes per forage body. Sweep is amortised (active every 8th
iteration). K = 128.

**Forager** — count consecutive empty sightings, random turn at 5:

```
sense_front; dup
jz_t LOW_ENERGY                          ; value == 0 → empty
  drop; eat; move
  push0; push3; store                    ; reset counter on any non-empty
  jmp_t AFTER
LOW_ENERGY:
  drop; eat; move                        ; eat costs 2 energy and yields 0
                                         ; on an empty cell — accepted as
                                         ; the price of uniform forage flow
  load slot[3]; push1; add; dup
  push5; mod; jz_t RANDOM_TURN
  push3; store; jmp_t AFTER
RANDOM_TURN:
  drop; push0; push3; store
  pushN; push2; mod; jz_t TURN_RIGHT
  turn_left; jmp_t AFTER
TURN_RIGHT:
  turn_right
AFTER:
```

~28 opcodes per forage body. K = 128.

### Estimated codeome sizes

| Seed | Size (opcodes) | Cost / pass (approx) | Max gain / pass (n_eat × eat_amount, default 20) |
|------|---------------:|---------------------:|--------------------------------------------------:|
| Minimal Replicator (baseline) | 121 | ~1764 | 128 × 20 = 2560 |
| Defender | ~150 | ~1400 | 64 × 20 = 1280 |
| Hunter | ~165 | ~1800 (sweep amortised) | 128 × 20 = 2560 + n_attack × attack_damage |
| Forager | ~155 | ~1700 | 128 × 20 = 2560 |

Final values fall out of the implementation — the spec commits to the
algorithmic structure, not exact opcode counts.

## Testing strategy

Three new test files mirroring `test/lenies/codeomes/minimal_replicator_test.exs`:

```
test/lenies/codeomes/defender_test.exs
test/lenies/codeomes/hunter_test.exs
test/lenies/codeomes/forager_test.exs
```

Each test:

1. Setup: zero copy / mutation rates, low `min_viable_codeome_opcodes`,
   `eat_amount: 50`, `interpreter_steps_per_batch: 50` (fast-mode tuning
   used by the existing seed tests).
2. Start `Lenies.World` with `tick_interval_ms: 0`.
3. Seed the grid with 200 resource per cell over a wide strip.
4. Spawn one Lenie at a known position with energy 5000.
5. Poll the `:lenies` ETS table for up to 30 s.
6. Assert `max_generation` ≥ 3 by the deadline.

Hunter runs the same test **alone** (no prey present). This validates
that the seed survives on its forage loop even when the sweep finds
nothing — i.e. the sweep is a bonus, not load-bearing for replication.

The existing seed-catalog test (`test/lenies/seeds_test.exs`, if
present) is updated to drop the `:random` assertion and add the three
new ids. Same for any controls-panel test that asserts dropdown
contents.

## Side-effects to track

- **Default selection**: the seed dropdown's first `<option>` is the
  default the browser picks. Order stays Minimal Replicator first so
  the default user experience is unchanged.
- **World auto-spawn**: `World.init/1` does not auto-spawn anything.
  Removing Random doesn't affect boot behaviour.
- **README** "Built-in seeds" section becomes a 5-entry list.
- **Forager + carcasses**: `sense_front` returns `:empty` for a cell
  that contains only a carcass (no Lenie and no resource — see
  `Lenies.World.do_action({:sense_front, …})`). Forager treats that
  cell as low-energy and walks away from carcass patches it could
  have eaten. Documented in the Forager module's @moduledoc. Not a
  regression — the existing Minimal Replicator has the same "blind to
  carcasses" property — it's just worth calling out.

## Open follow-ups (out of scope here)

- `:jlt_t` opcode (jump-if-less-than) so Forager can implement the
  original T=20 spec exactly.
- Programming Manual chapter 11 walking through one of the new seeds
  opcode-by-opcode, mirroring chapter 9 on Minimal Replicator.
- An "ecology test" that seeds all five species into the same world
  and asserts that no species goes extinct within 60 s (today the
  seeds are tested independently).
