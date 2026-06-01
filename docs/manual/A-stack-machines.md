# Appendix: Stack Machines and Stack-Based Languages

You have read the whole manual. You know that a Lenie runs on a small
stack-based virtual machine — a data stack, a call stack, 38 opcodes, a ring
codeome, and the defensive rule that mutations never produce a syntax error.
What you may not yet know is that this machine is not an isolated curiosity:
it is a member of a large and venerable family. Stack machines underlie page
description languages, portable bytecode formats, the implementations of major
programming languages, and a whole school of "concatenative" languages where
program text and function composition are the same thing.

This appendix steps outside the simulator to situate the Lenies VM in that
wider family. We start from first principles — what a stack machine actually
is — then tour a curated set of stack languages, mainstream and niche, and
finish by pinning down exactly where Lenies fits and where it deliberately
breaks ranks. None of this is required to write codeomes. It is here because
once you understand the Lenies VM, you understand a surprising amount of how a
great deal of real software is built — and the few places where Lenies is
genuinely unlike anything else are worth seeing clearly.

---

## 1. What is a stack machine?

A **stack machine** is a computer — physical or virtual — that takes its
operands implicitly from the top of a stack rather than from named registers.
An instruction like "add" does not name what to add: it pops the top two
values, adds them, and pushes the result. The operands are wherever the stack
left them.

This is most precisely seen through the **operand-count taxonomy** of
instruction sets. Count how many operands an instruction names explicitly:

- **0-operand** — a pure stack machine. `add` names nothing; operands are on
  the stack.
- **1-operand** — an accumulator machine. One operand is named; the other is
  the implicit accumulator.
- **2- or 3-operand** — a register machine. `add r1, r2, r3` names its sources
  and destination.

([Stack machine — Wikipedia](https://en.wikipedia.org/wiki/Stack_machine))

The Lenies VM sits at the 0-operand end: `add`, `swap`, `dup`, and the rest
say nothing about where their data lives, because it always lives on the data
stack.

### Reverse Polish notation

Stack evaluation is natural because it is exactly the shape of **reverse
Polish (postfix) notation**, where the operator follows its operands. You
write `5 3 +` rather than `5 + 3`. Given that each operator has a fixed
arity, postfix needs no parentheses at all: the expression `(2 + 3) * 4`
becomes simply `2 3 + 4 *`. Reading left to right, you push `2`, push `3`,
apply `+` (leaving `5`), push `4`, apply `*` (leaving `20`). The stack does
all the bookkeeping that parentheses do in infix notation.
([Reverse Polish notation — Wikipedia](https://en.wikipedia.org/wiki/Reverse_Polish_notation))

Every codeome you have written is reverse Polish notation in disguise. When
Chapter 5 built the constant 2 with `push1; push1; add`, that was `1 1 +`.

### One stack or two?

A pure data stack is enough to evaluate expressions, but real machines almost
always want a second stack. The classic design is the **two-stack model**: a
**data (parameter) stack** that holds operands, and a separate **return
stack** that holds return addresses and temporaries. Keeping return addresses
off the data stack means a subroutine can leave the data stack arranged purely
for parameter passing, without a saved return address buried in the middle of
its working values.
([Stack Computers, §3.3 — Koopman](https://users.ece.cmu.edu/~koopman/stack_computers/sec3_3.html))

Lenies follows this design exactly: a data stack (max 16, top is the head) and
a separate `call_stack` (max 32) used by `call_t` and `ret`.

### Why virtual machines like stacks

Stack VMs are everywhere as bytecode and compiler targets, for reasons that
are largely about engineering convenience:

- **Compact encoding.** Because operands are implicit, an instruction is often
  just an opcode byte with no operand fields. Bytecode stays small.
- **No register allocation.** A compiler front-end emitting stack code never
  has to solve the register-allocation problem — it just emits pushes and
  operations in evaluation order.
- **Easy to implement and port.** A stack interpreter is a tight dispatch
  loop over a single array. There is little machine-specific state to model.

Forth is the classic archetype here: a stack language whose implementation is
built from "threaded code," where execution is little more than walking a list
of addresses of further routines.

### The register-machine trade-off

Stacks are not free of cost. Because every value flows through the top of the
stack, stack code tends to execute more push/pop instructions than equivalent
register code, which can name a value once and reuse it in place. This is why
some implementations migrate the other way: **Lua 5.0 was the first widely
used register-based VM**, and it switched away from a stack VM specifically to
issue fewer instructions and avoid the push/pop churn.
([The Implementation of Lua 5.0 (PDF)](https://www.lua.org/doc/jucs05.pdf))
The trade-off has been studied directly — see
[The Case for Virtual Register Machines, Gregg et al. (PDF)](https://www.scss.tcd.ie/David.Gregg/papers/Gregg-SoCP-2005.pdf)
and
[Virtual Machine Showdown: Stack Versus Registers](https://dl.acm.org/doi/abs/10.1145/1328195.1328197).

Lenies pays this cost happily. A codeome that evolved under mutation is not
optimized for instruction count, and the simplicity of a 0-operand stack
machine is exactly what makes random mutation survivable.

---

## 2. A tour of stack languages

What follows is a curated walk through the family, in rough historical order,
ending with a cluster of "concatenative" languages that take the stack idea
furthest. Each entry gives the origin, the use-case, the number of stacks, a
short snippet, a source, and a one-line note on how Lenies relates.

### Forth

Forth was created by **Chuck Moore** in the late 1960s — he dates the
invention to 1968, with wider external use following by around 1970. It is the
archetypal stack language: minimal, interactive, and built on threaded code,
and it remains a staple of embedded, firmware, and real-time systems. Forth
uses **two stacks**, a data stack and a return stack, and it is the source of
the `( before -- after )` stack-effect comments this manual borrows.

```forth
: SQUARE ( n -- n' ) DUP * ;
5 SQUARE .   \ prints 25
```

([Forth — Wikipedia](<https://en.wikipedia.org/wiki/Forth_(programming_language)>))

**Lenies parallel.** Lenies is structurally Forth-shaped: two stacks, postfix
operators, and the very same `( before -- after )` notation. The big
difference is naming — `SQUARE` is a named word; a Lenie subroutine has no
name and is reached by template search.

### PostScript

PostScript came out of **Adobe** (John Warnock, Charles Geschke, and others),
developed across 1982–84 and debuting in the Apple LaserWriter in 1985. It is
both a page-description language and a complete, Turing-complete stack
programming language. It runs on **three stacks**: an operand stack, a
dictionary stack, and an execution stack.

```postscript
2 3 add 4 mul =
```

That computes `(2 + 3) * 4` and prints `20`.
([PostScript — Wikipedia](https://en.wikipedia.org/wiki/PostScript))

**Lenies parallel.** PostScript shows a stack language scaled up with
auxiliary stacks for names and control. Lenies stays at the opposite extreme:
two stacks, no dictionary, no names at all.

### JVM bytecode

The Java Virtual Machine was introduced by **Sun Microsystems** with Java 1.0
in 1995. Compiled Java runs from `.class` files containing bytecode. Each call
frame has **one operand stack** plus a local-variable array; the frames
themselves live on the JVM stack. Computing `2 + 3` looks like:

```text
iconst_2
iconst_3
iadd
```

([The Java Virtual Machine, JVMS SE8 §3](https://docs.oracle.com/javase/specs/jvms/se8/html/jvms-3.html))

**Lenies parallel.** The per-frame operand stack mirrors the Lenies data
stack, and `iconst_2; iconst_3; iadd` is precisely the reverse-Polish shape of
a Lenies snippet. But JVM bytecode is **verified** before it runs — Lenies
verifies nothing.

### CLR / .NET CIL

Microsoft's Common Language Runtime first shipped in 2002 and is standardized
as ECMA-335. Its Common Intermediate Language (CIL) is the shared compilation
target for C#, F#, and VB.NET. Each method executes on a per-method evaluation
stack. The CIL for `2 + 3`:

```text
ldc.i4.2
ldc.i4.3
add
```

([Common Intermediate Language — Wikipedia](https://en.wikipedia.org/wiki/Common_Intermediate_Language))

**Lenies parallel.** CIL is the JVM story told again on a different runtime: a
per-method stack, postfix arithmetic, and a managed runtime that validates the
code. Same stack core as Lenies, opposite stance on validation.

### WebAssembly

WebAssembly reached W3C Recommendation status in 2019. It is a portable,
near-native compile target for the web and beyond. Each function runs on an
operand stack — but a **typed** one, **statically validated** before
execution, and it uses **structured control flow** (`block`, `loop`, `if`,
and `br` with relative branch depths) rather than arbitrary jumps. The text
format (WAT) for `(2 + 3) * 4`:

```wat
(func (result i32)
  i32.const 2
  i32.const 3
  i32.add      ;; -> 5
  i32.const 4
  i32.mul)     ;; -> 20
```

([Understanding the WebAssembly text format — MDN](https://developer.mozilla.org/en-US/docs/WebAssembly/Guides/Understanding_the_text_format))

**Lenies parallel.** WebAssembly is the sharpest possible contrast. Its
operand stack is the same idea, but everything else is the inverse of Lenies:
types are checked, programs are validated, and control flow is structured with
relative branch depths instead of Lenies' free-roaming template jumps.

### RPN calculators and Unix `dc`

The most direct everyday descendants of postfix evaluation are RPN
calculators. On Unix, `dc` ("desk calculator") is one of the oldest utilities,
written by **Robert Morris and Lorinda Cherry** at Bell Labs; it is an
arbitrary-precision postfix calculator working on a single value stack. The
consumer analog is the line of HP RPN/RPL calculators.

```sh
echo "2 3 + 4 * p" | dc    # prints 20
```

([Reverse Polish notation — Wikipedia](https://en.wikipedia.org/wiki/Reverse_Polish_notation))

**Lenies parallel.** `dc` is a stack machine stripped to nearly nothing: one
stack, postfix, a handful of operators. A Lenie's arithmetic core (`push1`,
`add`, `mul`, `dup`) is the same minimal calculator with a body wrapped around
it.

### The concatenative niche

A distinct branch of the family takes the stack idea to its logical
conclusion. In a **concatenative** language, juxtaposing two programs is the
same as composing the two functions they denote — there are no variables in
the usual sense; data flows entirely through the stack, and quoted programs
are themselves values you can push and later run. This is where stack-based
design becomes a programming paradigm rather than an implementation strategy.

**Joy** is the touchstone. Created by **Manfred von Thun** at La Trobe
University and first appearing in 2001, Joy is a purely functional
concatenative language in which program concatenation *is* function
composition, and **quotations** — quoted programs — are first-class values on
a single data stack.

```joy
DEFINE square == dup * .
```

([Joy — Wikipedia](<https://en.wikipedia.org/wiki/Joy_(programming_language)>))

**Factor**, by **Slava Pestov**, arrived in 2003 — it began as JFactor on the
JVM and later became self-hosting. It is a modern, practical, dynamically
typed concatenative language built around words, quotations, and combinators;
it is Forth-influenced and stack-based.

```factor
: square ( n -- n ) dup * ;
5 square .   ! prints 25
```

([Factor — Wikipedia](<https://en.wikipedia.org/wiki/Factor_(programming_language)>))

**Cat**, by **Christopher Diggins** (mid-2000s), takes Joy's concatenative
ideas and adds a static type system, producing a statically typed, point-free
concatenative language.
([cat-language on GitHub](https://github.com/cdiggins/cat-language))

**Kitten**, by Jon Purdy (GitHub handle `evincarofautumn`), is a statically
typed, stack-based, concatenative systems language. It draws on Forth and Joy
for its concatenative core and on Rust and Haskell for its static typing and
generics.

```kitten
"meow" say
```

([Kitten language](https://kittenlang.org/))

**Lenies parallel.** This branch is, conceptually, Lenies' closest kin: data
flows through the stack, and (in Joy and Factor) quoted programs can be pushed
as values. The decisive divergences are that the concatenative languages
identify code by *name* (`square`, `say`) where Lenies uses template search,
and that Cat and Kitten are *statically typed* where a Lenie has no type system
and no validation at all.

---

## 3. Where Lenies fits

Lenies is unmistakably a member of this family, and just as unmistakably an
outlier within it. Four points locate it.

**It is a two-stack machine, like Forth.** A data stack (max 16, top is the
head) carries operands; a separate `call_stack` (max 32) carries return
addresses for `call_t` and `ret`. This is the same data/return split that
Koopman describes and that Forth made famous. The manual's `( before -- after )`
stack-effect notation is borrowed directly from that Forth/PostScript
tradition — Chapter 1 and the README say as much.

**It has no names or labels — control flow is Tierra-style template/complement
addressing.** Where every mainstream stack language reaches a subroutine or a
branch target by name (a Forth word, a JVM method, a CIL label) or by relative
depth (WebAssembly's `br`), Lenies reaches a target by *search*. A jump or
call opcode is followed by a run of `nop_0`/`nop_1` "bits"; the VM scans the
ring for the bit-flipped **complement** of that run and lands just after it.
There are no named words and no labels anywhere in the system. This mechanism
is not borrowed from any mainstream stack language — it comes from Tom Ray's
**Tierra** artificial-life system, and it exists because evolvable code cannot
afford a symbol table that mutation would corrupt.

**The codeome is a ring.** The instruction pointer wraps modulo the codeome
size, so execution never falls off the end and template search wraps around
the boundary. Mainstream stack VMs run linear instruction streams with a
defined end; a Lenie's program has no end.

**Mutations never produce a syntax error — and this is the punchline.** This is
the single feature that separates Lenies from every language surveyed here.
Because a codeome is genetic material that random mutation must never be able
to crash, the Lenies VM is relentlessly defensive: popping an empty stack
returns `0`, mod-by-zero returns `0`, an unknown opcode behaves as `nop_0`, a
failed template search simply falls through, and `ret` on an empty call stack
is a no-op. *No* other language in this appendix shares that stance:

- WebAssembly, the JVM, and the CLR **validate or verify** their bytecode and
  **reject** invalid programs before they run.
- Cat and Kitten are **statically typed** and reject ill-typed programs at
  compile time.
- Forth, PostScript, Factor, Joy, and `dc` are permissive by comparison, but
  they still **error** on stack underflow or type misuse at runtime.

Every one of these languages has some notion of an invalid program. Lenies, by
design, has none. There is no input the VM rejects, no opcode sequence it
refuses to run, no state it calls an error. That is what makes a codeome a
genome rather than a program — and it is the deepest sense in which Lenies,
for all its Forth-shaped familiarity, is not like the others.

---

## 4. Comparison table

| Language       | # stacks            | Control flow                          | Typing / validation                    | One-line note                                              |
| -------------- | ------------------- | ------------------------------------- | -------------------------------------- | ---------------------------------------------------------- |
| Forth          | 2 (data + return)   | Named words                           | Runtime errors on underflow/misuse     | The archetype; source of `( -- )` notation                 |
| PostScript     | 3 (operand/dict/exec) | Named procedures via dictionary     | Runtime errors                         | Page-description language that is also a full stack language |
| JVM bytecode   | 1 operand stack/frame | Branch instructions                 | Verified before execution; rejects bad code | Compiled Java target                                  |
| CLR / CIL      | 1 evaluation stack/method | Branch instructions             | Validated; rejects bad code            | Shared target for C#/F#/VB.NET                              |
| WebAssembly    | 1 operand stack/function | Structured (`block`/`loop`/`if`/`br`) | Typed + statically validated         | Portable near-native target; relative branch depths        |
| `dc` / RPN     | 1 value stack       | Macros / minimal                      | Runtime errors                         | One of the oldest Unix utilities; postfix calculator       |
| Joy            | 1 data stack        | Named words; quotations               | Runtime errors                         | Purely functional concatenative; quotations first-class    |
| Factor         | 1 data stack        | Words, quotations, combinators        | Dynamically typed; runtime errors      | Modern practical concatenative, Forth-influenced           |
| Cat            | stack-based         | Concatenative composition             | Statically typed                       | Joy's ideas plus a static type system; point-free          |
| Kitten         | stack-based         | Concatenative composition             | Statically typed (generics)            | Concatenative systems language; Forth/Joy + Rust/Haskell   |
| **Lenies**     | **2 (data + call)** | **Template/complement search (Tierra)** | **None — defensive, never errors**   | **Ring codeome; mutations never produce a syntax error**   |

---

→ Back to the manual: [README](README.md)

→ See also [Chapter 1 — VM Anatomy](01-vm-anatomy.md), where the data stack, the
call stack, the ring, and the defensive semantics summarized here are defined
against the source.
