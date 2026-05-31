# Chapter 0 — Introduction

Welcome to the Lenies programming manual. By the end of this book you will
be able to write, reason about, and improve codeomes from scratch — starting
with a handful of opcodes that do little more than wander and eat, and
finishing with a self-replicating creature capable of sustaining a lineage
across dozens of generations.

This chapter gives you the big picture: what Lenies are, the world they live
in, how they spend and earn energy, and a bird's-eye view of the virtual
machine (VM) that runs them.

---

## What is a Lenie?

A Lenie is a digital organism. It lives, it moves, it eats, and — if you
program it right — it replicates.

Its *body* and *behaviour* are both defined by a single thing: its
**codeome**. There is no separate "DNA" and "body plan". The codeome is
simultaneously the genome (the heritable sequence that gets copied and
mutated during reproduction) and the executable program (the instructions
the organism runs tick after tick).

Under the hood, each Lenie is an independent BEAM process — a lightweight
concurrent unit of execution running on the Erlang virtual machine. Thousands
of Lenies can coexist and run in parallel on a single laptop, each executing
its own codeome without interfering with the others at the process level.

When a Lenie's process starts, it is handed its codeome and an initial energy
budget. From that moment on, the codeome drives every decision: where to move,
when to eat, whether to try to reproduce. There is no external controller.

One practical consequence: a Lenie can die unexpectedly. The runtime enforces
a hard ceiling on how much memory each process is allowed to use. If a buggy
codeome causes the internal state to balloon (for example by pushing to the
stack in a tight loop without ever popping), the BEAM will kill the process
without warning. You will see the Lenie simply disappear from the world. This
is intentional — it keeps runaway organisms from consuming all available
memory — but it is worth knowing about when you are debugging a new codeome
that seems to vanish for no obvious reason.

---

## What is a codeome?

A codeome is a list of **opcodes** — named instructions drawn from a fixed
whitelist of 38 atoms. An opcode is just a symbol like `:move`, `:eat`, or
`:push1`. Every Lenie runs exactly one codeome, and the codeome can be
anywhere from 5 to 1000 opcodes long.

The same list of opcodes serves two roles at once:

- **As a program.** The VM reads the codeome sequentially, executing each
  opcode in turn. When it reaches the end it wraps back to the beginning
  automatically (more on that in the VM section below).

- **As a genome.** When a Lenie replicates, it copies its codeome — opcode
  by opcode — into a buffer allocated for the child. Copying is imperfect:
  there is a small probability of a substitution, insertion, or deletion at
  each position. This is how mutations arise, and how evolution happens.

Two Lenies with identical codeomes belong to the same **species**. The
simulator computes a species ID by hashing the opcode sequence with
`:erlang.phash2` — the same sequence always produces the same ID, a
fingerprint that lets the world track lineages across time.

The 38 opcodes are grouped into categories you will learn gradually:
template/nop bits, stack manipulation, arithmetic, control flow, sensing,
movement, eating, predation, self-inspection, replication, memory slots,
and horizontal transfer (plasmid conjugation, Chapter 11).
Chapter 2 ([02-opcode-reference.md](02-opcode-reference.md)) is the complete
reference; for now, just know the whitelist exists and any unknown atom is
silently treated as a no-op.

---

## The world

All Lenies share a single **world**: a 256 × 256 grid of cells. The grid
wraps at every edge — moving north off the top brings you out at the bottom,
moving east off the right edge brings you out at the left. Topologically it
is a torus, like the surface of a donut. There is no boundary, no corner, no
privileged position.

Each cell holds at most one of the following:

- **Nothing.** An empty cell a Lenie can move into.
- **Resource.** A pool of energy that Lenies can eat. Resources accumulate
  from radiation (see below) and are depleted by `:eat`.
- **Detritus.** The remains of a Lenie that has died. Detritus contains
  energy — roughly half of what the dead Lenie had left — and can also be
  eaten. Detritus yields energy 1:1 per unit consumed, the same as raw
  resource; no bonus multiplier applies, so the total energy in the world is
  conserved. Over time detritus decays and disappears.
- **A Lenie.** A living organism occupying the cell.

A cell can hold resource *and* detritus simultaneously, but only one Lenie
at a time.

**Radiation** is the primary energy source for the entire ecosystem. Every
world tick, the simulator deposits resource across the grid — mostly to
slowly-drifting hotspot regions, with a smaller uniform component. Think of
it as sunlight: unevenly distributed, continuously falling. A Lenie that
sits still will eventually exhaust its local resource even if the overall
grid is rich.

---

## Energy in, energy out

Every opcode you execute costs energy. The cost depends on the opcode:
cheap operations (no-ops, stack shuffles, arithmetic) cost around 0.1 to 0.2
units each; sensing and memory access cost 0.5; movement and eating cost 2.0;
predation and replication operations cost 5 to 10 or more. Every step of
execution drains the energy reservoir.

The **only** opcode that *adds* energy is `:eat`. When `:eat` executes, the
Lenie consumes up to a fixed portion of whatever resource (or detritus) is in
its current cell and converts it into energy. If the cell is empty, `:eat`
still costs its 2.0 units but gains nothing.

When a Lenie's energy falls to zero or below, it dies. There is no recovery
from zero — you cannot borrow against future eating. The corollary is that a
Lenie that executes expensive instructions without eating will die no matter
how rich the surrounding cells are.

This tension — you must execute code to move and eat, but executing code costs
energy — is the central design constraint you will wrestle with throughout
this manual. Every codeome you write is implicitly a bet that the energy gained
from eating will outpace the energy spent on all the instructions in between.

---

## The VM in one paragraph

The Lenies VM is **stack-based**: operands are pushed onto a stack and opcodes
pop their inputs from there, pushing results back. The stack is 16 entries
deep; if you push beyond that, the oldest (bottom) value is silently dropped.
There are also **4 named memory slots** — numbered 0 through 3 — that you can
use to store and retrieve integers across iterations of a loop. The
**instruction pointer** (IP) tracks which opcode executes next and advances by
one after each step; when it reaches the end of the codeome it wraps back to
position 0, so the codeome is effectively a ring. Each Lenie has a **direction**
(north, east, south, or west) that determines where it moves and what cell it
senses in front of it. Jumping and calling subroutines work via **template
addressing**: instead of hard-coded line numbers, a jump opcode reads the
sequence of `:nop_0` and `:nop_1` symbols that follow it in the codeome, then
searches for the bit-flipped complement of that pattern elsewhere in the
codeome. This is the most distinctive feature of the Lenies VM and the one
that takes the most getting used to — chapter 4
([04-loops-and-templates.md](04-loops-and-templates.md)) is dedicated to it.

---

## What this manual will teach you

The manual is structured as a pyramid of progressively capable codeomes. Each
chapter introduces one new idea and builds a concrete working organism that
demonstrates it:

- **Chapter 3** — Your first codeome: a Walker that moves and eats in a
  simple loop.
- **Chapter 4** — Loops and template addressing: a Forager that senses its
  surroundings and turns when blocked.
- **Chapter 5** — Memory slots and arithmetic: a Counter-walker that counts
  steps before turning, and a Turning forager that picks a random direction.
- **Chapter 6** — Subroutines: factoring repeated code into callable
  procedures with `call_t` and `ret`.
- **Chapter 7** — Replication: the three-opcode protocol (`allocate`,
  `write_child`, `divide`) that lets a Lenie copy itself. You will build a
  Mini-replicator and then a Sustainable replicator that can actually survive
  long enough to have grandchildren.
- **Chapter 8** — Energy economy: the maths behind break-even replication,
  and how to dimension your forage cycles.
- **Chapter 9** — Annotated dissection of the canonical `MinimalReplicator`
  (121 opcodes, hand-tuned for sustainable populations) and of `Carnivore`,
  which adds predation to the same body plan.
- **Chapter 10** — A cookbook of six recurring idioms you can copy and
  adapt.

If you are in a hurry, chapters 3 through 7 are the essential path. The rest
are reference and enrichment.

---

## Prerequisites

You need to be comfortable with three ideas: what a **stack** is and how push
and pop work; what a **loop** is; and what a **condition** (if/else) is.
No Elixir, no assembly, no knowledge of the simulator internals required.

To set up the simulator and follow along with the examples, see the project's
top-level `README.md`. Once it is running you will have a live world canvas
and a codeome editor where you can drag-and-drop opcodes, save seeds, and
spawn organisms.

---

→ Next: Chapter 1, [The VM Anatomy](01-vm-anatomy.md).
