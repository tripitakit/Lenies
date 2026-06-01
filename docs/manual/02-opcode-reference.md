# Chapter 2 — Opcode Reference

Source of truth: `lib/lenies/codeome/opcodes.ex`, `lib/lenies/codeome/costs.ex`,
and `lib/lenies/interpreter.ex`.

---

## 1. Notation Primer

Stack effects are written as `( before -- after )`. The rightmost element is the
top of the stack; items left of `--` are consumed, items right are produced.

- `push0  ( -- 0 )` — pushes one value, consumes nothing.
- `add  ( b a -- b+a )` — `a` is the top, `b` one below; both consumed, sum pushed.
- `drop  ( a -- )` — top consumed, nothing pushed.
- `( -- )` — no stack effect.

An empty stack is safe: popping it returns `0` without crashing.

---

## 2. The 13 Categories

| Category | Count | Purpose |
|---|---|---|
| Template / no-op | 2 | Encode anchors and template values |
| Stack | 6 | Manipulate values on the data stack |
| Arithmetic | 4 | Integer math |
| Control flow | 5 | Branching, subroutine calls, returns |
| Sense (local) | 4 | Read self-state without touching the world |
| Sense (world) | 1 | Query the cell directly in front |
| Orientation | 2 | Rotate facing direction 90° |
| Action (world) | 2 | Move into or eat from a cell |
| Predation | 2 | Attack a neighbour, signal defence |
| Self-inspection | 3 | Read own instruction pointer or codeome |
| Replication | 3 | Allocate child buffer, write opcodes, divide |
| Memory | 2 | Slot store / load |
| Horizontal transfer | 2 | Carve a plasmid, conjugate it to a neighbour |

**Total: 38 opcodes.** Verified against `@opcodes` in `opcodes.ex`. The two
horizontal-transfer opcodes (`make_plasmid`, `conjugate`) are covered in depth
in [Chapter 10](10-conjugation-and-plasmids.md).

---

## 3. Per-Opcode Reference

Opcodes are listed in `@opcodes` order from `opcodes.ex`.

---

### Template / No-op

### `nop_0`

**Stack:** `( -- )`
**Cost:** `0.1`
**Description:** No operation at the interpreter level. Its role is as template
bit 0: sequences of `nop_0`/`nop_1` form the labels that jump instructions scan
for their complement. Unknown opcodes introduced by mutation are decoded as
`nop_0`. See Chapter 4 for template addressing details.

### `nop_1`

**Stack:** `( -- )`
**Cost:** `0.1`
**Description:** Identical runtime behaviour to `nop_0`; bit value is 1 in a
template sequence. Together these two opcodes are the only valid template bits.

---

### Stack

### `push0`

**Stack:** `( -- 0 )`
**Cost:** `0.1`
**Description:** Pushes the integer `0`.

### `push1`

**Stack:** `( -- 1 )`
**Cost:** `0.1`
**Description:** Pushes the integer `1`.

### `pushN`

**Stack:** `( -- r )`
**Cost:** `0.1`
**Description:** Pushes a uniformly distributed random integer in 0..255. A
50/50 coin flip idiom: `pushN; push1; push1; add; mod` computes `r mod 2`.
See [07-replication.md](07-replication.md).

### `dup`

**Stack:** `( a -- a a )`
**Cost:** `0.1`
**Description:** Duplicates the top of the stack. Useful before a conditional
branch that must also retain the original value.

### `drop`

**Stack:** `( a -- )`
**Cost:** `0.1`
**Description:** Discards the top of the stack. Dropping from an empty stack
costs energy but has no other effect.

### `swap`

**Stack:** `( b a -- a b )`
**Cost:** `0.1`
**Description:** Exchanges the top two stack elements. `swap; sub` reverses the
subtraction direction.

---

### Arithmetic

All cost `0.2`. Pop `a` (top) and `b` (below), push one result.

### `add`

**Stack:** `( b a -- b+a )`
**Cost:** `0.2`
**Description:** Pushes `b + a`.

### `sub`

**Stack:** `( b a -- b-a )`
**Cost:** `0.2`
**Description:** Pushes `b - a`. The top (`a`) is subtracted from the value
below it (`b`).

### `mul`

**Stack:** `( b a -- b*a )`
**Cost:** `0.2`
**Description:** Pushes `b * a`.

### `mod`

**Stack:** `( b a -- b mod a )`
**Cost:** `0.2`
**Description:** Pushes `Integer.mod(b, a)` — non-negative remainder. If
`a == 0`, pushes `0` (defensive, no crash).

---

### Control Flow

Template-based opcodes read the trailing `nop_0`/`nop_1` run as a template (≤ 8
cells) and search 256 positions for its bitwise complement. Cost:
`0.2 + 0.05 × template_len` (minimum `0.2` with empty template).

### `jmp_t`

**Stack:** `( -- )`
**Cost:** `0.2 + 0.05 × template_len`
**Description:** Unconditional jump to the position after the complement of the
following template. Falls through to the instruction after the template if no
complement is found.

### `jz_t`

**Stack:** `( c -- )`
**Cost:** `0.2 + 0.05 × template_len`
**Description:** Pops `c` (always consumed), then jumps if `c == 0`. Falls
through if `c != 0` or no complement is found.

### `jnz_t`

**Stack:** `( c -- )`
**Cost:** `0.2 + 0.05 × template_len`
**Description:** Pops `c` (always consumed), then jumps if `c != 0`. Mirror
image of `jz_t`.

### `call_t`

**Stack:** `( -- )`
**Cost:** `0.2 + 0.05 × template_len`
**Description:** Pushes the return address (`ip + 1 + template_len`) onto the *call stack* (not the data stack), then jumps to the position right after the complement of the following template. If no complement is found, the return address is NOT pushed and execution simply falls through to the instruction after the template — the call stack stays untouched.

### `ret`

**Stack:** `( -- )`
**Cost:** `0.2`
**Description:** Pops the call stack and sets the instruction pointer to the
return address. If the call stack is empty, falls through (no-op with cost).

---

### Sense (local)

Cost `0.5` each; never yield to the world.

### `sense_self`

**Stack:** `( -- 1 )`
**Cost:** `0.5`
**Description:** Always pushes `1`. A creature cannot execute code after death,
so this is an invariant true. Useful to distinguish self-sensing intent from a
literal `push1`.

### `sense_energy`

**Stack:** `( -- e )`
**Cost:** `0.5`
**Description:** Pushes current energy truncated to an integer via `trunc/1`.

### `sense_age`

**Stack:** `( -- a )`
**Cost:** `0.5`
**Description:** Pushes the creature's age in world ticks.

### `sense_size`

**Stack:** `( -- n )`
**Cost:** `0.5`
**Description:** Pushes the codeome length. Same stack effect as `get_size` but
costs `0.5` instead of `0.3`; prefer `get_size` inside tight replication loops.

---

### Sense (world)

### `sense_front`

**Stack:** `( -- k )`
**Cost:** `0.5`
**Description:** Yields with action `{:sense_front, pos, dir}`. The world
returns a value describing the front cell (`:empty`, `{:resource, n}`, or
`{:lenie, id}`); the Lenie process pushes the encoded result as `k`. IP and
cost are applied before the yield; `:starvation` is possible before yielding.

---

### Orientation

### `turn_left`

**Stack:** `( -- )`
**Cost:** `0.5`
**Description:** Rotates facing 90° counter-clockwise: N → W → S → E → N.
Effect is immediate; no world yield.

### `turn_right`

**Stack:** `( -- )`
**Cost:** `0.5`
**Description:** Rotates facing 90° clockwise: N → E → S → W → N.

---

### Action (world)

Cost `2.0` each; both yield to the world. No integer pushed onto the data stack.

### `move`

**Stack:** `( -- )`
**Cost:** `2.0`
**Description:** Yields with `{:move, pos, dir}`. World replies `:moved` with
the new position, or `:blocked`. The Lenie process updates `pos` on success.

### `eat`

**Stack:** `( -- )`
**Cost:** `2.0`
**Description:** Yields with `{:eat, pos}`. World replies `{:ate, amount}`;
the Lenie process adds `amount` to energy. Amount is `0` for an empty cell.

---

### Predation

### `attack`

**Stack:** `( -- )`
**Cost:** `5.0`
**Description:** Yields with `{:attack, pos, dir}`. World resolves combat
against the creature in the front cell. Profitable only if the target holds
enough energy to transfer. Starvation before the yield is possible.

### `defend`

**Stack:** `( -- )`
**Cost:** `2.0`
**Description:** Yields with the atom `:defend`. Signals a defensive posture;
the world may reduce incoming damage (world policy). No value pushed.

---

### Self-inspection

Cost `0.3` each.

### `get_ip`

**Stack:** `( -- ip )`
**Cost:** `0.3`
**Description:** Pushes the current instruction pointer (index of `get_ip`
itself, before advance). Used in position-relative arithmetic for copy loops.

### `get_size`

**Stack:** `( -- n )`
**Cost:** `0.3`
**Description:** Pushes the codeome length. Cheaper than `sense_size` (`0.3`
vs `0.5`); prefer this inside replication counter arithmetic.

### `read_self`

**Stack:** `( a -- op_int )`
**Cost:** `0.3`
**Description:** Pops address `a`, reads the opcode at `codeome[a mod size]`,
and pushes its integer encoding (`Opcodes.encode/1`). The address wraps so
out-of-range values are safe. Used with `write_child` to copy the parent
codeome into a child buffer.

---

### Replication

### `allocate`

**Stack:** `( n -- )`
**Cost:** `5.0 + 0.05 × n`
**Description:** Pops `n`, yields with `{:allocate, n, pos, dir}`. World
reserves a child buffer of size `n` in the front cell. Cost scales with `n` to
discourage large allocations. The pending child handle is stored for subsequent
`write_child` calls; nil on failure.

### `write_child`

**Stack:** `( child_addr op_int -- )`
**Cost:** `1.0`
**Description:** Pops `op_int` (top) and `child_addr` (below), yields with
`{:write_child, op_int, child_addr}`. World writes the decoded opcode into the
pending child buffer at `child_addr mod child_size`. Typical copy pipeline:
`push addr; read_self; push dest; swap; write_child`. See
[03-first-codeome.md](03-first-codeome.md) for a worked example.

### `divide`

**Stack:** `( -- )`
**Cost:** `10.0`
**Description:** Yields with `{:divide, post_cost_energy, pos, dir}`. World
spawns a new Lenie from the pending child buffer and splits energy between
parent and child. Child buffer is cleared. No-op if no buffer is allocated.

---

### Memory

Cost `0.5` each; slots are per-creature integers persisting across execution bursts.

### `store`

**Stack:** `( v s -- )`
**Cost:** `0.5`
**Description:** Pops slot index `s` (top) and value `v`, writes `v` into
slot `s`. Out-of-range indices do not crash.

### `load`

**Stack:** `( s -- v )`
**Cost:** `0.5`
**Description:** Pops slot index `s`, pushes the value of slot `s`. Unwritten
slots return `0`.

---

### Horizontal transfer

### `make_plasmid`

**Stack:** `( start_addr length -- 1|0 )`
**Cost:** `2.0 + 0.05 × length` on success, `2.0` on a validation failure.
**Description:** Carves `codeome[start_addr .. start_addr+length-1]` (with
toroidal wrap, like every codeome read) and **appends** it to this creature's
*plasmid buffer* (multiple plasmids can be carried simultaneously). `length` must be in `[1, 64]`; an invalid
length pushes `0` and leaves the buffer untouched. On success pushes `1`. The
plasmid buffer is not executed — it is the payload that `conjugate` transfers.
Pure VM operation (no world round-trip). See Chapter 10.

### `conjugate`

**Stack:** `( -- 1|0 )`
**Cost:** `4.0 + 0.05 × plasmid_size` on success, `4.0` on any failure path.
**Description:** Selects one plasmid uniformly at random from this creature's plasmid buffer and transfers its opcodes to the Lenie in the cell directly ahead: the plasmid opcodes are appended to the recipient's
codeome and become its plasmid buffer too (so it can re-conjugate). Pushes `1`
on success, `0` if there is no plasmid, no Lenie ahead, the recipient is full
(would exceed the codeome length bound), or the recipient is busy. The transfer
uses a short timeout and is deadlock-safe; re-sending the same plasmid to an
already-carrying recipient is a no-op. See Chapter 10.

---

## 4. World-Yielding Opcodes Summary

Every opcode that returns `{:wait_world, action, state}` from the interpreter,
and the exact action shape emitted (from `dispatch/4` in `interpreter.ex`):

| Opcode | World action |
|---|---|
| `sense_front` | `{:sense_front, pos, dir}` |
| `move` | `{:move, pos, dir}` |
| `eat` | `{:eat, pos}` |
| `attack` | `{:attack, pos, dir}` |
| `defend` | `:defend` |
| `allocate` | `{:allocate, req_size, pos, dir}` |
| `write_child` | `{:write_child, opcode_int, child_addr}` |
| `divide` | `{:divide, energy, pos, dir}` |
| `conjugate` | `{:conjugate, pos, dir, plasmid_opcodes}` |

`pos` and `dir` are the values at the moment the opcode fires (before IP
advance). `energy` in `divide` is post-cost remaining energy. `make_plasmid`
is *not* in this table — it is a pure VM opcode that completes in-process
without a world round-trip.

---

→ Next: Chapter 3 puts the first few opcodes to work. ([03-first-codeome.md](03-first-codeome.md))
