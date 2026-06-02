# Chapter 10 — Conjugation and Plasmids

Source of truth: `lib/lenies/codeomes/minimal_replicator.ex`,
`lib/lenies/codeomes/carnivore.ex`, `lib/lenies/lenie.ex`,
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

By the end of the chapter you will understand the two opcodes that drive it
(`make_plasmid`, `conjugate`), the addressing trick that makes a transferred
plasmid actually *run* in its new host, and you will have a proven recipe for
writing your own conjugable plasmid in a custom codeome.

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

The two seeds shipped with the simulator already carry plasmids — the Minimal
Replicator carries **Twitch**, the Carnivore carries **Sprint** — and both
spread them by calling `conjugate` on every forage step. We dissect both below.

---

## 2. The two opcodes

### `make_plasmid` `( start_addr length -- 1|0 )`

Pops `length` (top) and `start_addr`. Carves
`codeome[start_addr .. start_addr+length-1]` — reading with toroidal wrap, like
every codeome access — and **appends** it to this creature's plasmid buffer.
Multiple plasmids can be carried simultaneously (the buffer is a list;
`:conjugate` later picks one uniformly at random to transfer).
`length` must be in `[1, 64]`; an invalid length pushes `0` and changes nothing.
On success pushes `1`.

**Cost:** `2.0 + 0.05 × length` on success, `2.0` on a validation failure.

`make_plasmid` is a pure VM opcode: it completes in-process, with no world
round-trip. It is how a custom codeome — which has no way to pre-load a buffer
through the editor — gives itself something to conjugate. You point it at a
region of your own code and say "this is the part I want to spread".

### `conjugate` `( -- 1|0 )`

Takes no operands. If the creature holds at least one plasmid and the cell
directly ahead is occupied by another Lenie, **one of its plasmids — chosen at
random** — is appended to that Lenie's codeome and added to its buffer. Pushes
`1` on a successful transfer.

Pushes `0` — and pays only the base cost — on any failure path:

- the donor has no plasmid;
- no Lenie is in the cell ahead;
- the recipient already carries the plasmid that was picked (see below);
- the recipient is full (appending would exceed the codeome length bound, 1000);
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
  failure, so both survive. (Earlier the default 5-second timeout let such pairs
  kill each other; that is fixed.)

---

## 3. The addressing trick: why a plasmid must hijack an anchor

Here is the subtlety that trips up every first attempt.

When `conjugate` succeeds, the plasmid is **appended to the end** of the
recipient's codeome. Appending code does not make it run. The recipient's
instruction pointer is busy looping through the original program; it never walks
off the end into the new opcodes. A naively-written plasmid sits at the tail of
the codeome as **dead code**, doing nothing, while still costing energy to carry
and copy. The recipient's behaviour is unchanged. This is exactly the bug the
first version of these plasmids had.

To make a plasmid execute, it must **hijack a jump the host already performs.**
Recall from Chapter 4 that a jump opcode does not store an address — it scans
the codeome for a run of nops matching the *complement* of its template, and
jumps just past the first match. The search runs **forward first**, then wraps.

The Minimal Replicator's forage loop ends each iteration with:

```
jnz_t FORAGE_LOOP_HEAD     # template [1,0,1,0]; searches for the run [0,1,0,1]
```

That `jnz_t` fires on **every** forage step (it loops back as long as the forage
counter is non-zero). It looks for the anchor `[0,1,0,1]` — the FORAGE_LOOP_HEAD
label, which in the original codeome sits early, around position 94.

Now suppose the appended plasmid *begins* with its own `[0,1,0,1]` run. The
host's `jnz_t` is at, say, position 112; its forward search starts just after it
and reaches the appended plasmid (around position 123) **before** it could wrap
all the way around to the original anchor at 94. The forward search finds the
plasmid's anchor first. Every forage step now diverts into the plasmid.

The plasmid runs its behaviour and ends with:

```
jmp_t FORAGE_LOOP_HEAD     # template [1,0,1,0]; bounces back
```

whose forward search wraps around to the *original* FORAGE_LOOP_HEAD at 94, so
the real forage body (sense, eat, move) runs next — then its `jnz_t` diverts
into the plasmid again. The result is a tight cycle:

```
   +============================================+
   |  real forage body: sense_front, eat, move  |
   |  decrement counter                         |
   |  jnz_t FORAGE_LOOP_HEAD  ============+     |
   +======================================|=====+
                                          |  (counter != 0)
                                          v
                        +==================================+
                        |  PLASMID (appended at tail)      |
                        |  [0,1,0,1] anchor                |
                        |  ...behaviour...                 |
                        |  jmp_t FORAGE_LOOP_HEAD  ========+
                        +==================================+
                              (bounces to the real anchor at 94)
```

The behaviour fires once per forage step — frequent, and therefore *visible*.

> **Why not LOOP_HEAD?** The very first version anchored plasmids to LOOP_HEAD
> `[1,1,1,1]`, the label the host jumps to only when it finishes a whole forage
> cycle to retry replication. That happens once every ~128 steps, so the
> behaviour fired about twice in five thousand steps — invisible. Anchoring to
> the per-iteration FORAGE_LOOP_HEAD is the whole fix. Pick the jump that fires
> at the frequency you want your trait to express.

Two discipline rules make or break a plasmid:

**1. Stack neutrality.** The host's forage loop keeps values on the stack
between steps; if your plasmid leaves junk behind, it corrupts the host's
arithmetic. Push and pop in balance.

**2. A trailing separator (this one is easy to forget and fatal).** The plasmid
is appended at the very end of the host's codeome ring, so its final `jmp_t`
template is immediately followed — across the wrap back to position 0 — by the
host's LOOP_HEAD anchor, which is *also* nops (`[1,1,1,1]`). The template
extractor reads a run of nops up to 8 long; with no break between your final
template and LOOP_HEAD it reads 8 nops instead of 4, computes the wrong
complement, and the bounce-back jump lands in the host's replication setup
instead of FORAGE_LOOP_HEAD. The host then loops through replication forever,
never forages, and starves in place — it looks frozen. **Always end a plasmid
with a single non-nop opcode** (a `:push0` is conventional, exactly as the
Minimal Replicator does at the end of its own codeome). That one byte breaks
the nop run across the wrap and is never executed (the preceding `jmp_t` jumps
past it).

---

## 4. Plasmid #1 dissected: Twitch (on the Minimal Replicator)

Twitch makes the host turn a random 90° left or right on every forage step,
producing the jittery, space-filling walk you see from a seeded Minimal
Replicator. It is 32 opcodes:

```
# == pos 0..3: INTERCEPT anchor = FORAGE_LOOP_HEAD pattern [0,1,0,1] ============
:nop_0, :nop_1, :nop_0, :nop_1,

# == pos 4..8: push a random bit - pushN mod 2 ==================================
:pushN, :push1, :push1, :add, :mod,

# == pos 9..13: jz_t TURN_LEFT_BR (template [1,0,0,0] -> anchor [0,1,1,1]) ======
:jz_t, :nop_1, :nop_0, :nop_0, :nop_0,

# == pos 14: turn_right (taken when the random bit was 1) =======================
:turn_right,

# == pos 15..19: jmp_t FORAGE_LOOP_HEAD (template [1,0,1,0]) ====================
:jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

# == pos 20: separator (keeps the template above from merging into the anchor) ==
:push0,

# == pos 21..24: TURN_LEFT_BR anchor [0,1,1,1] ==================================
:nop_0, :nop_1, :nop_1, :nop_1,

# == pos 25: turn_left (taken when the random bit was 0) ========================
:turn_left,

# == pos 26..30: jmp_t FORAGE_LOOP_HEAD (template [1,0,1,0]) ====================
:jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

# == pos 31: trailing separator (mandatory - breaks the nop run across
#            the ring wrap into LOOP_HEAD; never executed) ==
:push0
```

Reading it as a flow:

1. The host's per-step `jnz_t` lands here (pos 0..3 is the hijack anchor).
2. `pushN; push1; push1; add; mod` computes `pushN mod 2` — a fair coin, `0`
   or `1`, on the stack. (`push1; push1; add` is the cheapest way to put the
   literal `2` on the stack; Chapter 5 covers building constants.)
3. `jz_t TURN_LEFT_BR` consumes the bit. If it was `0`, jump to the
   `turn_left` branch (anchor `[0,1,1,1]` at pos 21). Otherwise fall through.
4. Fall-through: `turn_right`, then `jmp_t FORAGE_LOOP_HEAD` bounces back to the
   real forage body.
5. Left branch: `turn_left`, then the same bounce.

Net stack effect: zero (the random bit is created and consumed within the
plasmid). Exactly one turn per forage step, direction chosen fairly. Because the
direction is random, the host never settles into a closed loop — it wanders and
keeps finding fresh resource. That last point matters; see §6.

A trace of a seeded Minimal Replicator confirms it: over 5000 interpreter steps
the plasmid fired ~160 turns while eat and move continued normally.

---

## 5. Plasmid #2 dissected: Sprint (on the Carnivore)

Sprint makes the host take a second step and a second bite each forage
iteration, so it covers ground roughly twice as fast. It needs no internal
branch, so it is only 12 opcodes:

```
# == pos 0..3: INTERCEPT anchor = FORAGE_LOOP_HEAD pattern [0,1,0,1] ==
:nop_0, :nop_1, :nop_0, :nop_1,

# == pos 4..5: an extra step and an extra bite ========================
:move, :eat,

# == pos 6..10: jmp_t FORAGE_LOOP_HEAD (template [1,0,1,0]) ===========
:jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

# == pos 11: trailing separator (mandatory) ===========================
:push0
```

The host's `jnz_t` diverts here, the plasmid does `move; eat`, then bounces back
to the real forage body which does its own `sense; eat; move`. Two cells of
travel and two bites per iteration. Because every cell it crosses is eaten, the
extra step is self-funding as long as the field is not bare — contrast Twitch,
where the turns cost energy but win nothing directly (their payoff is staying
out of grazed-over patches).

Sprint is the template to copy when your trait is a straight-line *addition* to
the forage body: do X extra, then bounce. Twitch is the template when your trait
needs a *decision*: compute, branch to one of two anchored blocks, bounce from
each.

---

## 6. Writing your own conjugable plasmid

You now have everything you need. Here is the recipe, then a worked example that
has been verified end to end.

**The golden rule.** Your payload must:

1. **begin** with an anchor matching a jump the host performs at the frequency
   you want — for any Minimal-Replicator-derived host that is FORAGE_LOOP_HEAD,
   `[0,1,0,1]`, hit every forage step;
2. **do its work** in between, leaving the stack as it found it;
3. **end** with `jmp_t FORAGE_LOOP_HEAD` (template `[1,0,1,0]`) to return control
   to the real forage body;
4. **then add one trailing non-nop separator** (`:push0`) as the very last
   opcode — see rule 2 in §3. Without it the final template merges with the
   host's LOOP_HEAD across the ring wrap and the bounce-back lands in
   replication setup, freezing the host. This byte is never executed; it just
   breaks the nop run.

**Making it conjugable.** A custom codeome cannot pre-load a plasmid buffer
through the editor, so you give yourself one at runtime:

1. Place the payload as a contiguous region inside your own codeome.
2. Run `make_plasmid` with that region's `start_addr` and `length` to copy it
   into your buffer.
3. Run `conjugate` (typically inside your forage loop) to spread it to
   neighbours.

### Worked example: the "Veer" plasmid

The simplest payload that visibly changes movement is a single turn. Eleven
opcodes (ten of behaviour plus the mandatory trailing separator):

```
# == pos 0..3: FORAGE_LOOP_HEAD anchor [0,1,0,1] ============
:nop_0, :nop_1, :nop_0, :nop_1,

# == pos 4: the trait - one left turn =======================
:turn_left,

# == pos 5..9: jmp_t FORAGE_LOOP_HEAD (template [1,0,1,0]) ==
:jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

# == pos 10: trailing separator (mandatory - rule 4) ========
:push0
```

Suppose this sits at positions 40..50 of your codeome. Somewhere your code runs:

```
:push1, ...            # build the literal 40 into start_addr on the stack
...                    # (see Chapter 5 for building constants)
:push1, ...            # build the literal 11 into length on the stack
:make_plasmid,         # carve codeome[40..50] into the buffer; pushes 1
:drop,                 # discard the success flag
...
:conjugate,            # in your forage loop: infect the Lenie ahead
:drop                  # discard the success flag
```

Carving and expression are both verified: `make_plasmid 40 11` copies exactly
those eleven opcodes, and once conjugated into a Minimal Replicator the
`turn_left` fires on every forage step (≈87 turns matched by 87 eats and 87
moves over 2000 steps in a trace — the bounce-back returns cleanly to the
forage body, so the host keeps eating and moving).

### The viability lesson

Veer *works* — but a host that turns left on every step walks in a 2×2 square,
re-grazing four exhausted cells until it starves. The mechanism is correct; the
*trait* is maladaptive.

This is the difference between "does my plasmid express?" (an addressing
question — answered by the anchor) and "does my plasmid help its host?" (a design
question — answered by selection). Twitch solves the viability problem by making
the turn *random*: a host that turns a fair coin each step performs a
random walk, never closing into a starving loop, and keeps reaching fresh
resource. If you want a turning plasmid that survives, randomize it the way
Twitch does (§4) rather than turning the same way every time.

And remember the host-compatibility caveat: a plasmid expresses **only** in a
host that performs the jump your anchor hijacks. Conjugate Veer into a creature
with no FORAGE_LOOP_HEAD `[0,1,0,1]` run and it lands as dead code — carried and
copied, never executed.

---

## 7. Costs, sustainability, and pitfalls

- **Carry/copy tax.** A plasmid lengthens the host's codeome, so each
  replication copies more opcodes (the copy loop costs roughly 6.8 energy per
  opcode), and `divide` charges an extra `0.5 × plasmid_size` for the plasmid
  itself. The 32-opcode Twitch plasmid adds 16 energy per generation (0.5 × 32) plus the copy cost.
  Budget for it (Chapter 8).
- **Per-step cost.** Twitch adds ~1.8 energy to each forage step (the random
  bit, the branch, the turn, the bounce); Sprint adds ~4.4 (an extra move and
  eat) but the extra bite pays it back. A plasmid that costs energy without
  returning any — like Veer's bare turn — is a net drain unless the *behaviour*
  earns its keep indirectly (fresh grazing).
- **The 1000-opcode cap.** Conjugation refuses to append if it would push the
  recipient past the codeome length bound. The once-per-encounter rule keeps the
  same plasmid from stacking, but **distinct** plasmids accumulate; a host can
  only absorb so many before it hits the cap.
- **Symmetric conjugation.** Two carriers facing each other both calling
  `conjugate` is now safe (§2) — neither dies — but neither transfer completes
  that tick. In dense fields this is just a small amount of wasted effort.
- **Watch it happen.** When a conjugation succeeds the dashboard flashes both
  cells and updates the conjugation indicator next to the *World* header — a
  live events/sec rate with a short sparkline of recent activity and the name of
  the last plasmid transferred. This is the quickest way to confirm your custom
  plasmid is actually spreading.

---

## 8. Try it

1. Open the codeome editor (**+ New Seed** on the dashboard, or the editor
   page).
2. Build a Minimal-Replicator-style forage loop, or start from the Minimal
   Replicator and edit it. Insert a `conjugate` followed by a `drop` into the
   forage body (after `move`), so the creature tries to infect whatever is
   ahead each step.
3. Append a Veer payload — anchor `nop_0 nop_1 nop_0 nop_1`, then `turn_left`,
   then `jmp_t` with template `nop_1 nop_0 nop_1 nop_0`, then `:push0`
   (separator) — to the end of the codeome. Note its start position and length
   (11).
4. Before the forage loop, push that start position and `11`, then add
   `make_plasmid` and `drop` to load the payload into the buffer.
5. Save the seed, give it a colour, and spawn one copy next to a plain Minimal
   Replicator (spawn the built-in seed first, pause, then spawn yours adjacent —
   or spawn several of each and let them mingle).
6. Resume and watch the conjugation log. When your seed conjugates the plain
   replicator, the recipient's codeome grows by eleven opcodes and it begins
   veering — you will see a previously straight-walking Lenie start curving.
7. Now swap `turn_left` for the Twitch random-turn block (§4) and observe the
   difference in how long the converted hosts survive.

---

## 9. Where this fits

Conjugation sits on top of two earlier chapters: template addressing
([Chapter 4](04-loops-and-templates.md)) is the entire basis of the anchor
hijack, and the replication skeleton ([Chapter 7](07-replication.md),
dissected in [Chapter 9](09-minimal-replicator.md)) is the host structure whose
FORAGE_LOOP_HEAD you are hijacking. If a plasmid does not express, re-read
Chapter 4's account of forward search and confirm your anchor matches the host's
jump template; if it expresses but the host dies, re-read Chapter 8 and make the
trait pay for itself.

You can now move a trait sideways across a population, not just down a lineage.
Combine it freely with everything else: a random-branch plasmid (Pattern 2 from
the Cookbook) that spreads a counter-driven behaviour (Pattern 4) is a perfectly
natural thing to build. Infect responsibly.
