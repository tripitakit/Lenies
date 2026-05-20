# Manual Chapter: Conjugation & Plasmids

**Date**: 2026-05-20
**Status**: design
**Type**: documentation (no code changes beyond doc edits)

## Goal

Add a new manual chapter teaching the conjugation feature: the two new
opcodes (`:make_plasmid`, `:conjugate`), the anchor-hijack addressing
mechanism that makes a plasmid actually express in a recipient, the two
shipped example plasmids (Twitch on Minimal Replicator, Sprint on
Carnivore), and a proven recipe for writing your own conjugable plasmid
in a custom codeome. Also bring the opcode reference and counts up to
date (the manual still says "36 opcodes"; there are now 38).

## Audience & intent

A user who has read through Chapter 7 (replication) and wants to make
their custom codeomes spread behavior horizontally. They need to
understand:
1. What conjugation is (and is not).
2. How to carve a plasmid from their own codeome at runtime
   (`:make_plasmid`) and transfer it (`:conjugate`).
3. Why a naively-appended plasmid does nothing, and how the
   anchor-hijack makes it execute every forage iteration.
4. How to keep the host viable (don't make it orbit-and-starve).

## Scope (option B)

- **New** `docs/manual/11-conjugation-and-plasmids.md`
- **Edit** `docs/manual/02-opcode-reference.md`: add `:make_plasmid`
  and `:conjugate` (new "Horizontal transfer" category); fix the
  "36 opcodes" count to 38.
- **Edit** `docs/manual/README.md`: add Chapter 11 to the TOC; fix
  "all 36 opcodes" → "all 38 opcodes".

Out of scope: adding a plasmid field to custom seeds in the editor
(a feature, not docs). Custom-codeome authors use `:make_plasmid` at
runtime — taught in the chapter.

## Verified facts (empirically confirmed before writing)

These were checked with trace harnesses against the live code, so the
chapter documents proven behavior, not theory:

- **`:make_plasmid` carving**: `push start; push length; make_plasmid`
  carves `codeome[start .. start+length-1]` (toroidal wrap) into the
  plasmid buffer, exactly. Verified: a 10-op payload at positions 4..13
  of a donor codeome is carved byte-identical.
- **Anchor-hijack expression**: a payload beginning with the
  FORAGE_LOOP_HEAD anchor `[0,1,0,1]` and ending with
  `jmp_t FORAGE_LOOP_HEAD` (template `[1,0,1,0]`), appended to a
  Minimal-Replicator recipient, executes **every forage iteration**.
  Verified: a single-`turn_left` "Veer" payload fired 183 turns over
  5000 steps (the broken LOOP_HEAD-anchored version fired 2). Eat and
  move continue normally.
- **Why LOOP_HEAD doesn't work**: the host's `jmp_t LOOP_HEAD` fires
  only once per ~128-iter forage cycle, so a LOOP_HEAD-anchored plasmid
  is essentially invisible. FORAGE_LOOP_HEAD's `jnz_t` fires every iter.
- **Viability caveat**: a deterministic single turn (`turn_left`) makes
  the host orbit a 4-cell square and starve. The Twitch plasmid avoids
  this by randomizing the turn (`pushN mod 2` → left or right). The
  chapter teaches the mechanism with Veer, then the viability principle
  with Twitch.

## Chapter outline

1. **What conjugation is** — horizontal vs vertical inheritance;
   bacterial-conjugation analogy; what it is not (not crossover/sex).
2. **The two new opcodes** — reference-style entries with stack effects
   and costs:
   - `:make_plasmid` `( start_addr length -- 1|0 )`, length ∈ [1,64],
     cost `2.0 + 0.05×length`.
   - `:conjugate` `( -- 1|0 )`, transfers buffer to the front Lenie,
     cost `4.0 + 0.05×size` on success / `4.0` on failure. Notes:
     deadlock-safe (50ms timeout + catch), idempotent (re-infecting with
     the same plasmid is a no-op).
3. **The addressing mechanism (anchor hijack)** — the crucial section.
   Why an appended plasmid is dead code unless it begins with an anchor
   the host already jumps to; how FORAGE_LOOP_HEAD `[0,1,0,1]` lets the
   host's per-iter `jnz_t` divert into the plasmid; forward-search
   resolution; the bounce-back `jmp_t FORAGE_LOOP_HEAD`. Textual flow
   diagram.
4. **Plasmid #1 dissected: Twitch** — the 31-opcode listing with
   pos-by-pos comments; random L/R via `pushN mod 2` + branch to
   TURN_LEFT_BR; bounce-back; the verified 161-turn trace.
5. **Plasmid #2 dissected: Sprint** — the 11-opcode listing; `move+eat`
   double-step; why it needs no internal branch (contrast with Twitch).
6. **Writing your own conjugable plasmid** — the proven recipe:
   - Golden rule: payload begins with the host's frequently-hit anchor
     (FORAGE_LOOP_HEAD `[0,1,0,1]` for MR-derived hosts) and ends with
     `jmp_t` back to it.
   - Stack neutrality: the payload must not leave junk on the stack.
   - Make it conjugable: include the payload as a region in your own
     codeome, `:make_plasmid start len` to carve it into the buffer,
     `:conjugate` to spread it.
   - Worked example: the "Veer" plasmid (single `turn_left`), built
     step by step, with `:make_plasmid` + `:conjugate` wired into a
     forage loop. Then the viability lesson: Veer orbits and starves;
     randomize it (see Twitch) to make it adaptive.
   - Caveat: a plasmid expresses only in hosts that have the matching
     anchor; other hosts receive it as dead code.
7. **Costs, sustainability, and pitfalls** — divide tax (0.5×size),
   the symmetric-donor deadlock (now handled), idempotency, the 1000
   codeome cap, and the dashboard's conjugation flash + event log.
8. **"Try it" box** — exact editor steps: build a codeome with a
   payload + `make_plasmid` + `conjugate`, seed it next to a Minimal
   Replicator, watch the conjugation log/flash, observe the infection.
9. **Closing & cross-references** — Chapter 4 (templates), Chapter 7
   (replication), Chapter 9 (MR dissected).

## Conventions to follow

- Anchor bit-pattern notation `[0,1,0,1]` (0 = `:nop_0`, 1 = `:nop_1`),
  per the manual README.
- Stack effects `( before -- after )`, top on the right.
- Code listings as Elixir atom lists with `# ── pos X..Y: … ──` headers.
- "Try it" box with palette group / drag target / toolbar button.

## Self-review checklist

- All opcode counts say 38, not 36.
- The Twitch (31) and Sprint (11) listings match the actual
  `MinimalReplicator.plasmid()` and `Carnivore.plasmid()`.
- The "write your own" recipe matches the verified Veer trace.
- The anchor patterns use the manual's `[0,1,0,1]` notation, not the
  `[n0,n1,n0,n1]` notation used in code comments.
