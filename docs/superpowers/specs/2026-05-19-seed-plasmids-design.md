# Seed Plasmids — MR-Twitch & Carnivore-Sprint

**Date**: 2026-05-19
**Status**: design
**Builds on**: [2026-05-19-plasmid-conjugation-design.md](./2026-05-19-plasmid-conjugation-design.md)

## Motivation

The plasmid conjugation feature (MVP, just merged) added a transferable
secondary opcode buffer per Lenie but no seed actually carries one yet.
This spec equips two shipped seeds — `MinimalReplicator` and `Carnivore`
— with distinctive plasmids that:

1. Are exhibited as a visible movement signature by the seed itself
   from the moment of spawn, not just after some emergent acquisition.
2. Spread horizontally via `:conjugate` calls embedded in the seed's
   forage loop.
3. Activate in any recipient whose codeome contains a `jmp_t LOOP_HEAD`
   pattern (i.e. any MR-derived organism) via **homologous integration**:
   the plasmid begins with an anchor that matches the recipient's
   existing jump template, intercepting its end-of-forage flow.

This turns a passive transport mechanism into a visible biological
dynamic — players see one species' trait infect another through
proximity.

## Goals

- `MinimalReplicator` carries a **Twitch** plasmid → exhibits random L/R
  direction changes every forage cycle; spreads twitch behavior on
  conjugation.
- `Carnivore` carries a **Sprint** plasmid → covers approximately double
  the distance per forage cycle (extra move + extra eat); spreads sprint
  behavior on conjugation.
- Both seeds remain energy-sustainable under default tuning.
- Both plasmids are observable on the dashboard map within a few ticks
  of spawning a single seed.

## Non-goals

- Refactoring the `:conjugate` cost model.
- Adding new opcodes.
- Plasmids for Defender/Hunter/Forager (their behavior is already
  distinctive; plasmids would muddy the signal).
- Persistent plasmid library / user-editable plasmids.

## Design

### Seed catalog change

`Lenies.Seeds` records gain an optional `:plasmid` field whose value
is a list of opcode atoms:

```elixir
%{
  id: :minimal_replicator,
  name: "Minimal Replicator",
  codeome: MinimalReplicator.codeome(),
  plasmid: MinimalReplicator.plasmid(),  # NEW — nil for seeds without one
  default_options: %{energy: 10_000.0}
}
```

`plasmid` is `nil` for seeds without one (Defender/Hunter/Forager). The
existing dashboard spawn handler reads it and passes
`plasmids: [%Plasmid{opcodes: plasmid}]` as a spawn opt to
`World.spawn_lenie`. When `plasmid` is `nil`, no opt is passed (default
`[]` preserved).

A new public function on each opted-in seed module returns the opcode
list:

```elixir
@spec plasmid() :: [atom()]
def plasmid, do: @plasmid_opcodes
```

### Anchor hijack mechanism

`Lenies.Interpreter.Template.find_complement/4` searches forward first
from the jump position, then backward, both within a bounded radius
(`template_search_radius` config, default ≥ codeome size in practice).
The first matching anchor wins.

MR's end-of-forage jump is:

```
jmp_t [n0,n0,n0,n0]   # template, looks for [n1,n1,n1,n1] = LOOP_HEAD
```

Without a plasmid, this lands on position 0 (the original LOOP_HEAD).
With a plasmid appended after the codeome that begins with
`[n1,n1,n1,n1]`, the forward search finds the plasmid's anchor first
(it sits immediately after the original codeome at positions 121-124,
much closer to the jmp at position 115 than position 0 reached via
wrap). Execution diverts into the plasmid; the plasmid runs to
completion and ends with its own `jmp_t [n0,n0,n0,n0]` whose forward
search from the plasmid's end wraps back to position 0 (LOOP_HEAD).

The hijack is **transparent**: it doesn't require any explicit
"integration site" in the recipient; it just exploits the template
machinery the recipient already has.

### Twitch plasmid

**Behavioral intent**: every time the host's end-of-forage `jmp_t`
fires, do a random `:turn_left` or `:turn_right` (50/50 via
`pushN mod 2`) before bouncing back to the actual LOOP_HEAD. Randomness
prevents the host settling into a 4-cell orbit, so cell depletion isn't
a starvation risk.

**Opcode layout** (31 opcodes — under the 64-op cap):

```
pos  opcode      stack effect    role
0    nop_1                       \
1    nop_1                        | INTERCEPT_ANCHOR — matches MR LOOP_HEAD template
2    nop_1                        |
3    nop_1                       /
4    pushN       [r]
5    push1       [r,1]
6    push1       [r,1,1]
7    add         [r,2]
8    mod         [r mod 2]
9    jz_t                         pops; jump if 0 → TURN_LEFT_BR
10   nop_1                       \
11   nop_0                        | template [n1,n0,n0,n0] (complement of [n0,n1,n1,n1])
12   nop_0                        |
13   nop_0                       /
14   turn_right                   fallthrough — mod was 1
15   jmp_t                        bounce back to LOOP_HEAD
16   nop_0                       \
17   nop_0                        | template [n0,n0,n0,n0] (complement of [n1,n1,n1,n1])
18   nop_0                        |
19   nop_0                       /
20   push0                        SEPARATOR (prevents 8-nop misread into next anchor)
21   nop_0                       \
22   nop_1                        | TURN_LEFT_BR anchor [n0,n1,n1,n1]
23   nop_1                        |
24   nop_1                       /
25   turn_left
26   jmp_t                        bounce back to LOOP_HEAD
27   nop_0                       \
28   nop_0                        | template [n0,n0,n0,n0]
29   nop_0                        |
30   nop_0                       /
```

Energy cost when the plasmid intercepts: ~1.8 energy
(pushN 0.1 + push1+push1+add+mod 0.5 + jz_t 0.4 + turn 0.5 + jmp_t 0.4).

The plasmid's two `jmp_t LOOP_HEAD` instructions both bounce to the
host's original LOOP_HEAD via forward search wrap.

### Sprint plasmid

**Behavioral intent**: every host iter, after intercepting the
end-of-forage `jmp_t`, do an extra `:move` + extra `:eat` before
bouncing back. Total: 2 moves + 2 eats per forage iter (host's original
move/eat + plasmid's extra move/eat).

**Opcode layout** (11 opcodes):

```
pos  opcode      role
0    nop_1                       \
1    nop_1                        | INTERCEPT_ANCHOR — matches LOOP_HEAD template
2    nop_1                        |
3    nop_1                       /
4    move                         extra step forward
5    eat                          eat that cell too
6    jmp_t                        bounce back to host LOOP_HEAD
7    nop_0                       \
8    nop_0                        | template [n0,n0,n0,n0]
9    nop_0                        |
10   nop_0                       /
```

Energy cost when intercepting: 2.0 (move) + 2.0 (eat) + 0.4 (jmp_t)
= 4.4. Compensated by the extra eat (gain up to 20).

### Seed codeome modifications

**MinimalReplicator** gains `:conjugate, :drop` in its forage body so
it actively spreads the plasmid:

Before:
```
FORAGE_LOOP_HEAD:
  sense_front, drop, eat, move,
  counter machinery,
  jmp_t FORAGE_LOOP_HEAD
```

After:
```
FORAGE_LOOP_HEAD:
  sense_front, drop, eat, move,
  conjugate, drop,           # NEW: try to infect neighbor every forage iter
  counter machinery,
  jmp_t FORAGE_LOOP_HEAD
```

`:conjugate` pushes 1 or 0; `:drop` removes the result (we don't act
on it for now).

**Carnivore** is `MinimalReplicator.opcodes() |> inject_attack_before_eat()`.
The `:conjugate, :drop` addition is inherited automatically — the
existing patcher operates on `:eat` location which is unaffected.

### Costs and sustainability

**MR-Twitch** per forage iter (when plasmid intercepts):

| Operation | Cost |
|---|---|
| sense_front | 0.5 |
| drop | 0.1 |
| eat | 2.0 |
| move | 2.0 |
| conjugate (fail) | 4.0 |
| drop | 0.1 |
| counter | 1.5 |
| load + jnz_t | 0.9 |
| plasmid intercept | 1.8 |
| **Total** | ~12.9 |

Eat gain at default 20 → net per iter: ~+7.1.

Codeome size: 121 (MR) + 2 (conjugate, drop) = 123 ops. Plasmid buffer
31 ops doesn't count toward codeome size but adds a divide tax of
0.5 × 31 = 15.5.

Replication cost ≈ 123 × 6.8 + 29 (overhead) + 15.5 (plasmid tax) ≈
881 energy.

E_ss = 2 × 128 × 7.1 − 881 ≈ +937. Sustainable.

**Carnivore-Sprint** per forage iter:

| Operation | Cost |
|---|---|
| sense_front + drop | 0.6 |
| attack | 5.0 |
| eat | 2.0 |
| move | 2.0 |
| conjugate (fail) | 4.0 |
| drop | 0.1 |
| counter + jnz_t | 2.4 |
| plasmid: move + eat + jmp_t | 4.4 |
| **Total** | ~20.5 |

Gain: 2 eats × 20 = 40. Net: +19.5.

Codeome size: 122 + 2 = 124. Plasmid buffer 11 ops, divide tax 5.5.
Replication cost ≈ 124 × 6.8 + 29 + 5.5 ≈ 877.

E_ss = 2 × 128 × 19.5 − 877 ≈ +4115. Very sustainable.

### Dashboard display

Both seeds keep their current names (`Minimal Replicator`, `Carnivore`)
but the species table will show new codeome hashes (modified codeome
with conjugate + drop = different hash from any pre-plasmid MR/Carnivore
out there). The conjugation flash from the previous PR handles the
visual feedback when MR-Twitch infects a neighbor.

### File structure

**Modified files:**
- `lib/lenies/codeomes/minimal_replicator.ex` — add `:conjugate, :drop`
  in forage body; add new `plasmid/0` function returning the 31-opcode
  Twitch payload
- `lib/lenies/codeomes/carnivore.ex` — add `plasmid/0` function
  returning the 11-opcode Sprint payload (Carnivore inherits MR's
  codeome modification automatically)
- `lib/lenies/seeds.ex` — add `:plasmid` field to MR and Carnivore
  catalog entries; populate from each seed's `plasmid/0`
- Dashboard spawn handler (wherever it dispatches to
  `World.spawn_lenie`) — read `seed.plasmid` and pass `plasmids:` opt
- `test/lenies/codeomes/minimal_replicator_test.exs` — add gen-≥-3 test
  (must still pass with the new codeome) + integration test for
  conjugation spreading the twitch
- `test/lenies/codeomes/carnivore_test.exs` — analogous for sprint

## Test plan

1. **MR-Twitch gen ≥ 3**: existing replication test must still pass —
   verifies energy sustainability under modified codeome.
2. **MR-Twitch movement signature**: spawn one MR-Twitch alone; after
   100 ticks, both x and y displacement from start must be nonzero
   (vanilla MR walks straight, so y stays = start_y).
3. **Conjugation spread**: spawn MR-Twitch adjacent to vanilla MR;
   within N ticks the vanilla MR's codeome grows by 31 opcodes (the
   plasmid is appended) and its plasmid_buffer matches the Twitch
   plasmid.
4. **Carnivore-Sprint gen ≥ 3**: replication still sustainable.
5. **Carnivore-Sprint distance**: after K ticks, distance from start >
   distance of vanilla Carnivore over same period.

## Risk

- **Plasmid hijack search radius**: depends on `template_search_radius`
  config. The default must be large enough that the forward search
  from MR's end-of-forage jmp_t at position ~115 reaches the appended
  plasmid at position ~121. Verify before implementation; if it's too
  small, raise it or add a search-from-after-jump test.
- **MR vanilla becomes a hybrid**: every existing MR Lenie (pre-rollout)
  has a different codeome_hash from MR-Twitch. After one conjugation,
  the recipient's codeome is unique (hash changes). The species table
  will fragment more.
- **Sprint plasmid double-step**: Carnivore-Sprint moves 2 cells per
  iter — twice the area depletion. Compensated by the extra eat, but
  if `eat_amount` drops below ~3 in tuning, it starves.
- **Conjugate-every-iter**: MR-Twitch and Carnivore-Sprint spam
  `:conjugate` calls. In a dense population this amplifies the
  symmetric-donor deadlock footgun noted in the plasmid-conjugation
  spec. Acceptable for MVP; if observed in practice, lower frequency
  by gating `:conjugate` behind a slot counter.

## Out of scope

- Plasmids for Defender/Hunter/Forager
- User-editable plasmids
- Multiple plasmids per Lenie (still MVP single-plasmid)
- `:absorb_plasmid` (receiver-pull) opcode
