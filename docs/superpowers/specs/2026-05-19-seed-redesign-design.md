# Seed Redesign — Defender, Hunter, Forager

**Date**: 2026-05-19
**Status**: design
**Supersedes**: parts of `2026-05-18-specialized-seeds-design.md` (Defender, Hunter, Forager sections)

## Motivation

The three specialized seeds added on 2026-05-18 (Defender, Hunter, Forager) do
not produce visually distinctive behaviors compared to MinimalReplicator (MR)
and Carnivore. Specifically:

- **Hunter walks in a straight line.** Its "360° sweep every 8 iterations"
  consists of 4 consecutive `turn_left` instructions, which return the Lenie
  to its starting facing. Between sweeps Hunter advances straight like MR.
- **Hunter does not detect prey.** It senses only the cell directly in front
  while walking; prey moves out of that single cell before Hunter reaches it.
  The sweep finds prey at the moment of sweeping, but the prey has moved by
  the next sweep — Hunter cannot pursue.
- **Hunter starves.** Its per-iteration cost is ~21 opcodes (vs MR's ~9),
  driven by inline lenie-check + counter machinery. Without effective kills
  it runs an energy deficit.
- **Defender and Forager are too similar to MR.** Defender's "zigzag every
  5 steps" is subtle; Forager's "turn after 5 consecutive empty cells"
  almost never triggers in a resource-rich world, leaving it visually
  identical to MR.

The user explicitly asked for behaviors that differ **visually**, especially
in how the Lenies move through the world.

## Design approach

**Approach A — Movement archetypes.** Each redesigned seed gets a distinctive
movement signature that is recognizable within a few ticks of observation:

| Seed       | Movement archetype                        | Visual                       |
|------------|-------------------------------------------|------------------------------|
| MR         | Long straight runs + rare random turn     | Long straight lines          |
| Carnivore  | Long straight runs + rare random turn     | Long straight lines          |
| **Defender** | **Short straight bursts + post-divide divergence + defend each iter** | Branching tree, dense cluster |
| **Hunter**   | **L/R alternating turn every step + lock-on attack** | Weaving zigzag corridor    |
| **Forager**  | **3-way random turn (no-turn/L/R) every step** | Chaotic random walk         |

All three keep MR's replication skeleton (copy → divide → post-divide turn →
K-iteration forage loop). The differences are localized to the **forage body**
and the choice of K. This minimizes risk and keeps the codeomes diffable
against MR for inspection.

## Defender — "Sentinel"

### Behavior
Replicates often (K=32). Each forage iteration: `defend`, `eat`, `move`.
Cluster forms because of frequent replication + post-divide random turn
spreading children in different directions.

### Forage body (pseudocode)
```
FORAGE_LOOP_HEAD:
  decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
  defend
  eat
  move
  jmp_t FORAGE_LOOP_HEAD
```

### Parameters
- **K = 32** (vs MR's 128). Replicate every ~32 forage steps.
- Post-divide turn: **random** (preserve MR's `pushN mod 2`-based 50/50
  turn_left/turn_right) — children must diverge to form a cluster.
- No `sense_front` in forage (not needed; saves per-iter cost).
- No in-forage zigzag (saves codeome size, makes K=32 sustainable).

### Anchors
Uses MR's 6 anchors only. No new anchors.

### Codeome size estimate
~93 opcodes (vs MR's 121). Significant reduction because no in-forage turn
logic and no sense_front.

### Energy sustainability
- Replication cost C ≈ 93 × 6 + 33 ≈ 591
- Per-iter cost: defend(~3) + eat(~1) + move(~2) + counter(~3) = ~9 → gain ≈ +11
- E_ss = 2 × K × gain − C = 2 × 32 × 11 − 591 = +113 → **sustainable**.

### Distinctive feel
Short straight runs ~32 cells, branching every 32 steps because the random
post-divide turn sends each child in a different direction. Defender + child
+ grandchild form a fractal-tree cluster. Defended against incoming attacks
(attackers take penalty when attacking a defending Lenie).

## Hunter — "Stalker"

### Behavior
Weaves L/R at every step (covers a 2-3 cell wide corridor instead of a 1-cell
line) → more chances to encounter prey crossing its path. When `sense_front`
returns `-1` (Lenie ahead), attacks **and stays in place facing the same
direction** — locks on, so consecutive iters keep attacking until prey
dies or moves.

### Forage body (pseudocode)
```
FORAGE_LOOP_HEAD:
  decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
  sense_front
  push1; add                 ; value+1: 0 iff was -1 (lenie)
  jz_t LENIE_HANDLER        ; pops value+1
  drop                       ; non-lenie: drop value+1
  eat
  move
  ; alternate turn via slot[3] parity
  push1; push1; push1; add; add; load   ; load slot[3]
  push1; add                              ; counter+1
  dup                                     ; [counter+1, counter+1]
  push1; push1; add                       ; [counter+1, counter+1, 2]
  mod                                     ; [counter+1, (counter+1) mod 2]
  jz_t TURN_LEFT_BR                       ; pops mod; if 0
  turn_right
  push1; push1; push1; add; add; store   ; slot[3] := counter+1
  jmp_t FORAGE_LOOP_HEAD

LENIE_HANDLER:
  attack
  jmp_t FORAGE_LOOP_HEAD     ; no move, no turn — lock on

TURN_LEFT_BR:
  turn_left
  push1; push1; push1; add; add; store   ; slot[3] := counter+1
  jmp_t FORAGE_LOOP_HEAD
```

### Parameters
- **K = 96** (vs MR's 128). Reduced ~25% to compensate for higher per-iter cost.
- Post-divide turn: deterministic `turn_left`. This drops `TURN_LEFT_ANCHOR`
  and `SKIP_TURN_ANCHOR` from the codeome, freeing 2 anchors (4 patterns) in
  the 4-bit template budget for the new in-forage anchors.

### Anchors
Two new anchors beyond MR's 6:
- `LENIE_HANDLER` — entry for prey-detected branch
- `TURN_LEFT_BR` — entry for the turn_left side of the L/R alternation

Total: 8 anchors × 2 patterns each (anchor + complement template) = 16 patterns,
exactly the 4-bit budget. Pattern assignment must be checked at implementation
time to avoid collisions.

### Codeome size estimate
~150-160 opcodes (vs current Hunter's ~190). Smaller because no 360° sweep
machinery.

### Distinctive feel
S-curve weaving advance (turns 90° L then 90° R alternately, advancing by 1
cell on each turn). When prey appears in front, Hunter freezes facing it and
attacks every iter until prey dies or escapes. The "freeze and chew" behavior
on prey contact is visually striking and contrasts with the constant weaving.

### How this fixes "never detects prey"
Two improvements stack:
1. **Corridor width 2-3 instead of 1** → ~3x baseline probability that a prey
   crossing the area is in Hunter's sense_front during its scan.
2. **Lock-on attack** → once prey is detected, multiple consecutive attacks
   land before the prey can move away. Current Hunter's sweep attacks once
   then resumes walking, often missing the kill.

## Forager — "Wanderer"

### Behavior
At every forage iteration: `eat`, `move`, then a 3-way random branch:
- 33%: no turn (continue forward)
- 33%: `turn_left`
- 33%: `turn_right`

The direction performs a random walk on {N, W, S, E} → the position performs
a 2D random walk that fills space rather than walking in lines.

### Forage body (pseudocode)
```
FORAGE_LOOP_HEAD:
  decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
  eat
  move
  pushN; push1; push1; push1; add; mod    ; pushN mod 3
  dup
  jz_t NO_TURN_BR                          ; pops dup; if val == 0
  push1; sub                                ; (val=1 → 0; val=2 → 1)
  jz_t TURN_LEFT_BR                         ; pops; if was 1
  ; val was 2
  turn_right
  jmp_t FORAGE_LOOP_HEAD

NO_TURN_BR:
  drop                                     ; drop leftover val (== 0)
  jmp_t FORAGE_LOOP_HEAD

TURN_LEFT_BR:
  turn_left
  jmp_t FORAGE_LOOP_HEAD
```

### Parameters
- **K = 128** (same as MR). Random walk needs many steps to cover area.
- Post-divide turn: deterministic `turn_left`. Drops `TURN_LEFT_ANCHOR` and
  `SKIP_TURN_ANCHOR` (same as Hunter), freeing pattern budget for the new
  in-forage anchors.
- No `sense_front` in forage (cleaner, cheaper).

### Anchors
Two new anchors beyond MR's 6:
- `NO_TURN_BR` — entry for the no-turn path
- `TURN_LEFT_BR` — entry for the turn_left path

Total: 8 anchors. Same budget as Hunter.

### Codeome size estimate
~115-125 opcodes (similar to MR; the random walk branch costs a bit more than
MR's straight `sense_front; drop`).

### Distinctive feel
No long straight runs. Every step is potentially a 90° turn in either direction.
Position drift over many steps is the classic 2D random walk pattern —
visible as a "thick blob" of explored cells rather than a "line."

### Note on `pushN mod 3` bias
`pushN` returns 0..255. 256 mod 3 = 1, so values 0 and 1 are returned 86
times and value 2 is returned 84 times in a perfect 256-sample distribution.
Relative bias: ~2.4%. Negligible for behavior.

## Testing

All three seeds need updated tests in `test/lenies/codeomes/`.

### Common tests per seed
1. **Codeome parses cleanly**: `Codeome.from_list/1` succeeds.
2. **Anchor uniqueness**: no duplicate 4-bit anchor patterns within the
   codeome (template extractor would mis-route jumps).
3. **Replication**: spawned with `energy: 10_000`, after N ticks at least
   one child exists.
4. **Energy sustainability** (long-running): after M replication cycles,
   population is non-zero.

### Per-seed movement signature tests
- **Defender**: spawn one, record positions every tick for 50 ticks. Verify
  consecutive-position distance is bounded (no long-range jumps; movement
  is local).
- **Hunter**: spawn one in an empty grid (no prey). Record direction at every
  tick for 50 ticks. Verify direction changes at ≥70% of ticks (weaving
  signature).
- **Forager**: spawn one in an empty grid. Record positions for 200 ticks.
  Verify variance of x-coordinate AND variance of y-coordinate are both
  above a threshold (2D random walk, not 1D).

### Hunter-specific behavior test
- Spawn Hunter at position A facing east. Place a stationary "prey" Lenie
  at position B directly east of A. Within 5 ticks, prey must have taken
  damage (energy decreased).

### Test refactoring
The existing tests for Hunter (`test/lenies/codeomes/hunter_test.exs`),
Defender, Forager will be rewritten to reflect new behavior. The old
"sweep happens every 8 iters" and "5-empties trigger" tests are removed.

## Implementation order

1. **Defender** first — simplest (no new anchors, smaller codeome). Establishes
   the K=32 + cluster-feel pattern.
2. **Forager** — second simplest (only 2 new anchors, structure parallels MR).
3. **Hunter** — most complex (2 new anchors, conditional branch for lenie
   handler with stack discipline).

Each seed is its own commit. Each gets its own test rewrite in the same
commit.

## Out of scope

- MR and Carnivore are not modified.
- The species table, dashboard, codeome editor, and custom-seed store are not
  affected (they consume seeds via `Lenies.Seeds.all/0` which already lists
  these IDs).
- No new opcodes are introduced.
- The `defense_attacker_penalty` config is not changed (Defender behavior
  uses the existing penalty).

## Risk

- **Energy math is approximate.** The MR moduledoc gives +11.4 gain/iter at
  default `eat_amount: 20` and a specific cost table. My estimates for the
  new seeds are based on rough opcode counts. If a seed turns out to
  starve, K can be tuned (Defender K=32 → K=48; Hunter K=96 → K=64) without
  redesign.
- **Anchor collisions**: Hunter and Forager both add 2 new anchors which
  consume the remaining 4-bit pattern budget. Specific pattern assignments
  must avoid collisions with MR's 6 anchors AND with each other within the
  same codeome. The implementation step will enumerate explicit assignments.
- **Hunter lock-on may stack-leak**: if `LENIE_HANDLER` is entered with a
  non-empty stack (jz_t pops the top, but the rest of the stack from prior
  iter matters), the next iter could mis-execute. The pseudocode assumes
  `jz_t` cleanly pops and stack is otherwise empty at FORAGE_LOOP_HEAD —
  must be verified in implementation by reasoning through each path.
