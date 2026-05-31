# Lenies Programming Manual

A programmer-friendly introduction to writing codeomes for the Lenies simulator.
From your first 16-opcode walker to a self-tuning replicator and horizontal
gene transfer, with every VM concept, opcode, and idiom explained from first
principles.

---

## How to read this manual

Reading the chapters in linear order is recommended for first-time readers;
each chapter assumes the vocabulary and concepts introduced before it. That
said, chapters are self-contained enough to serve as a lookup reference once
you are familiar with the basics — the opcode table in Chapter 2, for instance,
is designed to be consulted in isolation. The pyramid of codeomes in Chapters
3–7 is the exception: each builds directly on the previous one, so reading
those chapters out of order will leave gaps that make the later examples harder
to follow.

---

## Prerequisites

You should be comfortable with general programming concepts: what a stack is,
how a loop works, and what a conditional branch does. No Elixir knowledge is
required to write codeomes, though it helps when reading the source. Before
starting Chapter 3, set up the simulator and confirm it runs — follow the
instructions in the top-level project README at
[../../README.md](../../README.md).

---

## Table of contents

- [Chapter 0 — Introduction](00-introduction.md) — what a Lenie is, the world it lives in
- [Chapter 1 — VM Anatomy](01-vm-anatomy.md) — execution state and the ring
- [Chapter 2 — Opcode Reference](02-opcode-reference.md) — all 38 opcodes
- [Chapter 3 — Your First Codeome: The Walker](03-first-codeome.md)
- [Chapter 4 — Loops and Templates](04-loops-and-templates.md) — the Forager
- [Chapter 5 — Memory and Arithmetic](05-memory-and-arithmetic.md) — Counter-walker, Turning forager
- [Chapter 6 — Procedures](06-procedures.md) — call_t/ret, Subroutine forager
- [Chapter 7 — Replication](07-replication.md) — Mini-replicator, Sustainable replicator
- [Chapter 8 — Energy Economy](08-energy-economy.md) — budget, break-even, copy errors
- [Chapter 9 — The MinimalReplicator Dissected](09-minimal-replicator.md) — the canonical hand-tuned replicator
- [Chapter 10 — Cookbook](10-cookbook.md) — six recurring idioms
- [Chapter 11 — Conjugation and Plasmids](11-conjugation-and-plasmids.md) — horizontal gene transfer; writing your own conjugable plasmid
- [Chapter 12 — Recipes](12-recipes.md) — beginner-friendly idioms (loops, if-else, stack/storage patterns)
- [Appendix: LLM Knowledge Base](LLM-APPENDIX.md) — single-file reference for AI coding agents writing Lenies codeomes

---

## Conventions

**Code listings** are Elixir atom lists. Each listing is divided into named
sections with a comment header of the form:

```
# ── pos X..Y: description ──
```

The positions refer to the zero-based index of the opcode in the codeome ring.

**Stack effects** are written `( before -- after )`, with the top of the stack
on the right. For example, `( b a -- b+a )` means: pop `a` (top), pop `b`,
push their sum. An empty side means no operands consumed or produced.

**Stack state** (the concrete contents of the stack at a moment in time) is
written in square brackets, **also with the top on the right**: `[a, b, c]`
means bottom=`a`, second-from-top=`b`, **top=`c`**. Pushing 5 then 7 onto
an empty stack yields `[5, 7]` (top=7), never `[7, 5]`. The Elixir source
internally uses head=top lists; the manual deliberately reverses this for
display so that "stack grows rightward" matches how you read.

The same notation rules are restated at the start of [Chapter 1, §1](01-vm-anatomy.md)
where the stack is first defined, so readers who skip the README still
encounter them before any worked example.

**Anchor bit patterns** are written as a list such as `[0,1,0,1]`, where `0`
stands for `:nop_0` and `1` stands for `:nop_1`. The complement of
`[0,1,0,1]` is `[1,0,1,0]`. When a jump opcode is followed by the template
`[0,1,0,1]` the VM searches the codeome for the run `[1,0,1,0]` and jumps
to the instruction immediately after it.

**"Try it" boxes** give exact UI steps for the codeome editor — palette group
name, drag target, and toolbar button — so you can reproduce each example
without leaving the browser.

---

## Where to ask questions / report errors

See the GitHub link in the top-level project README at
[../../README.md](../../README.md).
