# Chapter 10 — Conjugation and Plasmids

Source of truth: `lib/lenies/codeomes/symbiont.ex`,
`lib/lenies/codeomes/ancestor.ex`, `lib/lenies/lenie.ex`,
`lib/lenies/codeome/costs.ex`.

Every codeome you have written so far inherits *vertically*: a parent copies
its opcodes into a child during replication (Chapter 7), with the occasional
copy error (Chapter 8). The genome only ever flows down the family tree.

This chapter adds a second axis. **Conjugation** lets one living Lenie hand a
small chunk of executable code — a **plasmid** — to the Lenie standing directly
in front of it, regardless of family. The recipient does not have to be a
descendant; it does not even have to be the same species. A useful trait can
sweep through a whole population by contact in a few hundred ticks, the way an
antibiotic-resistance plasmid spreads through a bacterial colony.

This is exactly what rung 4 of the seed ladder — **Symbiont** — is built to do:
it mints a plasmid from its own code at runtime and conjugates it into the
neighbours it meets. By the end of the chapter you will understand the two
opcodes that drive it (`make_plasmid`, `conjugate`), the addressing trick that
makes a transferred plasmid actually *run* in its new host, and you will have a
proven recipe for writing your own conjugable plasmid.

---

## 1. What conjugation is — and what it is not

A Lenie has, in addition to its codeome, a **plasmid buffer**: the list of
plasmids it carries — each a short sequence of opcodes (up to 64). Think of the
codeome as the chromosome and a plasmid as a loose ring of DNA riding alongside
it. A Lenie can carry **several distinct plasmids** at once; they accumulate as
it acquires them.

Two opcodes act on plasmids:

- `make_plasmid` carves a slice of the creature's *own* codeome into the buffer
  — the payload it offers when it conjugates.
- `conjugate` sends **one** carried plasmid — picked uniformly at random among
  those it holds — to the Lenie directly ahead, appending those opcodes to that
  Lenie's codeome and **adding** the plasmid to that Lenie's own buffer. The
  recipient keeps any plasmids it already had, and can pass the new one on in
  turn.

That second clause is what makes it spread: every recipient becomes a potential
donor. A single carrier dropped into a field of plain replicators can, over
time, convert the whole field.

What conjugation is **not**:

- It is **not** sexual reproduction or crossover. No genomes are blended; a
  fixed payload is copied one-directionally from donor to recipient.
- It does **not** create offspring. The recipient keeps living as itself, just
  with extra code grafted on.
- The donor keeps its plasmid. Transfer is a copy, not a move.

Of the four shipped ladder seeds, only **Symbiont** uses plasmids — and unlike
older designs that were handed a plasmid at spawn, Symbiont **mints its own at
runtime** with `make_plasmid` and spreads it with `conjugate`. We dissect it in
§4. The other three rungs (Reflex, Ancestor, Architect) carry none.

---

## 2. The two opcodes

### `make_plasmid` `( start_addr length -- 1|0 )`

Pops `length` (top) and `start_addr`. Carves
`codeome[start_addr .. start_addr+length-1]` — reading with toroidal wrap, like
every codeome access — and **appends** it to this creature's plasmid buffer.
Multiple plasmids can be carried simultaneously (the buffer is a list;
`:conjugate` later picks one uniformly at random to transfer).
`length` must be in `[1, 64]`; an invalid length pushes `0` and changes nothing.
It also pushes `0` and changes nothing if minting the plasmid would push the
execution stream (chromosome + carried plasmids) past the codeome length cap.
On success pushes `1`.

**Cost:** `2.0 + 0.05 × length` on success, `2.0` on a validation failure.

`make_plasmid` is a pure VM opcode: it completes in-process, with no world
round-trip. It is how a codeome gives itself something to conjugate. You point
it at a region of your own code and say "this is the part I want to spread".

### `conjugate` `( -- 1|0 )`

Takes no operands. If the creature holds at least one plasmid and the cell
directly ahead is occupied by another Lenie, **one of its plasmids — chosen at
random** — is appended to that Lenie's codeome and added to its buffer. Pushes
`1` on a successful transfer.

Pushes `0` — and pays only the base cost — on any failure path:

- the donor has no plasmid;
- no Lenie is in the cell ahead;
- the recipient already carries the plasmid that was picked (see below);
- the recipient is full (appending would exceed the codeome length bound, 1024);
- the recipient is busy (see the deadlock note below).

**Cost:** `4.0 + 0.05 × plasmid_size` on success, `4.0` on failure.

Two robustness properties worth knowing:

- **Once per encounter.** Sending a recipient a plasmid it already carries is a
  no-op: nothing is appended, **no conjugation event fires**, and the donor
  reads failure (`0`). So two adjacent Lenies that already share a plasmid don't
  spam transfers or bloat each other toward the length cap — a given plasmid
  crosses to a given neighbour at most once. Combined with the random pick
  above, a multi-plasmid donor hands the neighbour each distinct plasmid it
  lacks over successive forage steps, then falls quiet.
- **Deadlock-safe.** If two Lenies face each other and both call `conjugate` in
  the same instant, each is trying to write into the other at once. The transfer
  uses a short (50 ms) timeout and treats a busy recipient as an ordinary
  failure, so both survive.

---

## 3. The addressing trick: why a plasmid must hijack an anchor

Here is the subtlety that trips up every first attempt.

When `conjugate` succeeds, the plasmid is **appended to the end** of the
recipient's codeome. Appending code does not make it run. The recipient's
instruction pointer is busy looping through the original program; it never walks
off the end into the new opcodes. A naively-written plasmid sits at the tail of
the codeome as **dead code**, doing nothing, while still costing energy to carry
and copy. The recipient's behaviour is unchanged.

This is, in fact, *by design* for Symbiont's own plasmid — a deliberately inert
passenger, see §4. But if you want a plasmid that **changes** its host's
behaviour, it must **hijack a jump the host already performs.** Recall from
Chapter 4 that a jump opcode does not store an address — it scans the codeome
for a run of nops matching the *complement* of its template, and jumps just past
the first match. The search runs **forward first**, then wraps.

Take `Ancestor` (Chapter 9) as the host. Its forage loop ends each iteration
with:

```
jmp_t FORAGE     # template [0,1,1,1]; searches for the run [1,0,0,0]
```

That `jmp_t` fires on **every** forage step. It looks for the anchor `[1,0,0,0]`
— the `FORAGE` label, which in the original codeome sits at position 75.

Now suppose the appended plasmid *begins* with its own `[1,0,0,0]` run. The
host's `jmp_t FORAGE` is at position 94; its forward search starts just after it
and reaches the appended plasmid (around position 100) **before** it could wrap
all the way around to the original anchor at 75. The forward search finds the
plasmid's anchor first. Every forage step now diverts into the plasmid.

The plasmid runs its behaviour and ends with its own:

```
jmp_t FORAGE     # template [0,1,1,1]; bounces back
```

whose forward search — starting from the plasmid's tail and wrapping through the
chromosome — reaches the *original* `FORAGE` at 75 before it could loop back to
the plasmid's own copy, so the real forage body (eat, move) runs next, then the
host's `jmp_t FORAGE` diverts into the plasmid again. The result is a tight
cycle:

```
   +============================================+
   |  real forage body: eat, move               |
   |  decrement counter                         |
   |  jmp_t FORAGE  =====================+       |
   +====================================|=======+
                                        v
                      +==================================+
                      |  PLASMID (appended at tail)      |
                      |  [1,0,0,0] anchor                |
                      |  ...behaviour...                 |
                      |  jmp_t FORAGE  =================+ |
                      +================================|=+
                            (bounces to the real anchor at 75)
```

The behaviour fires once per forage step — frequent, and therefore *visible*.

> **Pick the jump that fires at the rate you want.** Anchor to a per-iteration
> jump (like `FORAGE`) and your trait expresses every step. Anchor instead to a
> jump the host takes only once per generation (like `HEAD`, reached only when a
> whole forage run finishes) and the trait fires a couple of times in thousands
> of steps — effectively invisible.

Two discipline rules make or break a plasmid:

**1. Stack neutrality.** The host's forage loop keeps values on the stack
between steps; if your plasmid leaves junk behind, it corrupts the host's
arithmetic. Push and pop in balance.

**2. A trailing separator (easy to forget and fatal).** The plasmid is appended
at the very end of the host's codeome ring, so its final `jmp_t` template is
immediately followed — across the wrap back to position 0 — by the host's `HEAD`
anchor, which is *also* nops (`[1,1,1,1]`). The template extractor reads a run
of nops up to 8 long; with no break between your final template and `HEAD` it
reads 8 nops instead of 4, computes the wrong complement, and the bounce-back
jump lands in the host's replication setup instead of `FORAGE`. The host then
loops through replication forever, never forages, and starves in place — it
looks frozen. **Always end a plasmid with a single non-nop opcode** (a `:push0`
is conventional, exactly as Ancestor does at the end of its own codeome). That
one byte breaks the nop run across the wrap and is never executed (the preceding
`jmp_t` jumps past it).

---

## 4. Symbiont dissected: minting and spreading a passenger

`Symbiont` (rung 4) is the shipped organism built around horizontal transfer.
It does three things no other seed does: it reads its own age as a clock, it
**mints** a plasmid from its own code, and it **conjugates** that plasmid into
neighbours conditioned on what it senses.

**Minting (runs once, at spawn).** The first eight opcodes are:

```
# == pos 0: start_addr = 0 ===========================================
:push0,
# == pos 1..5: build length 4 (push1; dup; add; dup; add) ============
:push1, :dup, :add, :dup, :add,
# == pos 6: mint codeome[0..3] into the buffer (pushes 1/0) ==========
:make_plasmid,
# == pos 7: discard the result ======================================
:drop,
```

`make_plasmid` here carves `codeome[0..3]` — which happens to be
`[push0, push1, dup, add]` — into the buffer. That four-opcode cassette is the
**passenger**: it contains **no `:nop` opcodes**, so it can never match any
jump's template and can never hijack an anchor in a recipient. It rides along as
an inert, inherited gene. Symbiont deliberately spreads a benign passenger: the
point is to demonstrate the *transfer pathway*, not to alter recipients.

**Spreading (every spread-phase step).** Symbiont alternates phases on an age
clock (`sense_age mod 8`). In its spread phase it senses the cell ahead and, if
a Lenie is there, conjugates:

```
# sense the cell ahead; +1 turns the "lenie" code -1 into 0
:sense_front, :push1, :add,
:jz_t,  ...INFECT...        # neighbour ahead -> jump to the infect block
:eat, :move, ...            # otherwise just forage
# INFECT:
:conjugate, :drop, :move, ...
```

So conjugation is **environment-conditioned**: it fires only when a neighbour is
actually in front, rather than blindly every step. A successful transfer raises
the recipient's plasmid count (visible in the species panel — see
`project_species_plasmid_count`) and, because offspring inherit carried plasmids
by segregation at `divide`, the cassette then also flows **vertically** down
each lineage it has entered. Vertical + horizontal spread from one organism.

The passenger does nothing to the recipient's behaviour. To build a plasmid that
*does*, you use the anchor-hijack technique of §3 — covered next.

---

## 5. Writing your own expressing plasmid

You now have everything you need. Here is the recipe, then a worked example
verified end to end against an `Ancestor` host.

**The golden rule.** A payload that should *express* in its host must:

1. **begin** with an anchor matching a jump the host performs at the frequency
   you want — for an `Ancestor`-style host that is `FORAGE`, `[1,0,0,0]`, hit
   every forage step;
2. **do its work** in between, leaving the stack as it found it;
3. **end** with `jmp_t FORAGE` (template `[0,1,1,1]`) to return control to the
   real forage body;
4. **then add one trailing non-nop separator** (`:push0`) as the very last
   opcode — see rule 2 in §3. Without it the final template merges with the
   host's `HEAD` anchor across the ring wrap and the bounce-back lands in
   replication setup, freezing the host. This byte is never executed; it just
   breaks the nop run.

**Making it conjugable.** Give yourself a plasmid at runtime exactly as Symbiont
does:

1. Place the payload as a contiguous region inside your own codeome.
2. Run `make_plasmid` with that region's `start_addr` and `length` to copy it
   into your buffer.
3. Run `conjugate` (typically inside your forage loop, or guarded by a
   `sense_front` like Symbiont) to spread it to neighbours.

### Worked example: the "Veer" plasmid

The simplest payload that visibly changes movement is a single turn. Eleven
opcodes (ten of behaviour plus the mandatory trailing separator):

```
# == pos 0..3: FORAGE anchor [1,0,0,0] ======================
:nop_1, :nop_0, :nop_0, :nop_0,

# == pos 4: the trait - one left turn =======================
:turn_left,

# == pos 5..9: jmp_t FORAGE (template [0,1,1,1]) ============
:jmp_t, :nop_0, :nop_1, :nop_1, :nop_1,

# == pos 10: trailing separator (mandatory - rule 4) ========
:push0
```

Suppose this sits at positions 40..50 of your codeome. Somewhere your code
builds the constants `40` and `11` on the stack (Chapter 5), then runs
`make_plasmid; drop` to carve `codeome[40..50]` into the buffer, and later
`conjugate; drop` inside the forage loop to infect the Lenie ahead.

Once conjugated into an `Ancestor`, the appended `[1,0,0,0]` anchor is found by
the host's per-step `jmp_t FORAGE` before the real anchor at 75, so `turn_left`
fires on every forage step and the bounce returns cleanly to the forage body —
the host keeps eating and moving, now veering.

### The viability lesson

Veer *works* — but a host that turns left on every step walks in a 2×2 square,
re-grazing four exhausted cells until it starves. The mechanism is correct; the
*trait* is maladaptive.

This is the difference between "does my plasmid express?" (an addressing
question — answered by the anchor) and "does my plasmid help its host?" (a
design question — answered by selection). Make the turn *random* — `pushN;
push1; push1; add; mod` for a fair coin, then branch to a `turn_left` or
`turn_right` block (Chapter 5) — and the host performs a random walk, never
closing into a starving loop, and keeps reaching fresh resource. A surviving
turning-plasmid randomizes; a fixed turn does not.

And remember the host-compatibility caveat: an anchor-driven plasmid expresses
**only** in a host that performs the jump your anchor hijacks. Conjugate Veer
into a creature with no `FORAGE` `[1,0,0,0]` run and its anchor never fires —
carried and inherited, but effectively dead code (exactly like Symbiont's
deliberately-inert passenger).

---

## 6. Costs, sustainability, and pitfalls

- **Carry cost.** Plasmids are *extra-chromosomal*: they are kept separate from
  the chromosome and never fused into it, so they do **not** lengthen the host's
  codeome and there is no `divide` surcharge for carrying them. Their cost is
  paid as **execution**: a plasmid's opcodes run as part of the host's execution
  stream (chromosome followed by every carried plasmid), so an *expressed*
  plasmid spends energy every step it runs. An unexpressed one (like Symbiont's
  passenger) is nearly free. Budget for the ones that fire (Chapter 8).
- **Per-step cost.** A random-turn plasmid adds ~1.8 energy to each forage step
  (the random bit, the branch, the turn, the bounce). A plasmid that costs
  energy without returning any — like Veer's bare turn — is a net drain unless
  the *behaviour* earns its keep indirectly (fresh grazing).
- **The 1024-opcode cap.** Conjugation refuses a plasmid if it would push the
  recipient's *execution stream* (chromosome + carried plasmids) past the codeome
  length bound. The once-per-encounter rule keeps the same plasmid from stacking,
  and across generations **segregational loss** at `divide` (each plasmid is kept
  by the child only with probability `1 − plasmid_loss_probability`) bounds how
  many a lineage hoards.
- **Symmetric conjugation.** Two carriers facing each other both calling
  `conjugate` is safe (§2) — neither dies — but neither transfer completes that
  tick.
- **Watch it happen.** When a conjugation succeeds the dashboard flashes both
  cells and updates the conjugation indicator next to the *World* header — a
  live events/sec rate with a short sparkline of recent activity and the name of
  the last plasmid transferred. This is the quickest way to confirm your custom
  plasmid is actually spreading.

---

## 7. Try it

1. Open the codeome editor (**+ New Seed** on the dashboard, or the editor
   page).
2. Build an `Ancestor`-style forage loop, or start from `Ancestor` and edit it.
   Insert a `conjugate` followed by a `drop` into the forage body (after
   `move`), so the creature tries to infect whatever is ahead each step.
3. Append a Veer payload — anchor `nop_1 nop_0 nop_0 nop_0`, then `turn_left`,
   then `jmp_t` with template `nop_0 nop_1 nop_1 nop_1`, then `:push0`
   (separator) — to the end of the codeome. Note its start position and length
   (11).
4. Before the forage loop, push that start position and `11`, then add
   `make_plasmid` and `drop` to load the payload into the buffer.
5. Save the seed, give it a colour, and spawn one copy next to a plain
   `Ancestor` (spawn the built-in seed first, pause, then spawn yours adjacent —
   or spawn several of each and let them mingle).
6. Resume and watch the conjugation log. When your seed conjugates the plain
   `Ancestor`, the recipient picks up the eleven-opcode plasmid (its chromosome
   is untouched — the plasmid rides alongside it in the execution stream) and
   begins veering — you will see a previously straight-walking Lenie start
   curving.
7. Now swap `turn_left` for a random-turn block (§5) and observe the difference
   in how long the converted hosts survive.

---

## 8. Where this fits

Conjugation sits on top of two earlier chapters: template addressing
([Chapter 4](04-loops-and-templates.md)) is the entire basis of the anchor
hijack, and the replication skeleton ([Chapter 7](07-replication.md), dissected
as `Ancestor` in [Chapter 9](09-ancestor.md)) is the host structure whose
`FORAGE` anchor you are hijacking. If a plasmid does not express, re-read
Chapter 4's account of forward search and confirm your anchor matches the host's
jump template; if it expresses but the host dies, re-read Chapter 8 and make the
trait pay for itself.

You can now move a trait sideways across a population, not just down a lineage —
which is precisely what `Symbiont` does with its self-minted passenger. Combine
the mechanism freely with everything else: a random-branch plasmid (Pattern 2
from the Cookbook) that spreads a counter-driven behaviour (Pattern 4) is a
perfectly natural thing to build. Infect responsibly.
