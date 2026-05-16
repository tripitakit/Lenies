# Chapter 1 — VM Anatomy

Every Lenie runs inside a small stack-based virtual machine. This chapter
describes exactly what that machine is made of, how time passes inside it,
and what it can return to the outside world. All claims here are tied
directly to `Lenies.Interpreter.State` and `Lenies.Interpreter`.

---

## 1. The Execution State

The full runtime state of one Lenie is a struct with eight fields.

| Field        | Type                          | Meaning                                                      |
|--------------|-------------------------------|--------------------------------------------------------------|
| `ip`         | non-neg integer               | Instruction pointer; wraps modulo codeome size               |
| `stack`      | list of integers, max 16      | Top is the head; pushing beyond 16 drops the oldest element  |
| `slots`      | `%{0..3 => integer}`          | 4 named memory slots; slot index wraps mod 4                 |
| `dir`        | `:n \| :e \| :s \| :w`        | Facing direction (cardinal compass)                          |
| `energy`     | float                         | Decreases on every opcode; Lenie dies when it reaches ≤ 0   |
| `age`        | non-neg integer               | Incremented once per K-instruction batch (metabolic tick)    |
| `pos`        | `{x, y}`                      | Grid coordinates (both non-neg integers)                     |
| `call_stack` | list of non-neg integers, max 32 | Return IPs saved by `call_t`; consumed by `ret`           |

### `ip` — instruction pointer

`ip` is an index into the codeome. After every opcode the interpreter calls
`State.advance_ip/3`, which computes `rem(ip + delta, codeome_size)`. The
result is always non-negative, so the codeome is a ring: execution never
falls off the end.

### `stack` — the data stack

The stack holds up to 16 integers. The head of the list is the top. When a
push would make the length exceed 16, `Enum.take(new_stack, 16)` keeps the
16 youngest values and silently drops the oldest (the bottom). Popping an
empty stack returns `0` without error — this is intentional; mutations can
produce code that pops more than it pushes, and the VM must survive that.

### `slots` — local memory

Four integer registers indexed 0–3. `State.store/3` and `State.load/2` both
call `Integer.mod(slot_idx, 4)` before accessing the map, so an index of 5
resolves to slot 1, an index of -1 resolves to slot 3, and so on. All four
slots are initialized to 0.

### `dir` — facing direction

The atom `:n`, `:e`, `:s`, or `:w`. The opcodes `turn_left` and
`turn_right` rotate through the four values in compass order. `dir` is used
by world-interaction opcodes (`move`, `sense_front`, `attack`, `allocate`)
to determine which adjacent cell is targeted.

### `energy` — fuel

A float that decreases by the cost of every executed opcode. The cost is
looked up from `Lenies.Codeome.Costs`. After every opcode (or after the
world-interaction opcodes finish charging), the interpreter checks
`energy <= 0`; if true it emits `{:halt, :starvation, state}`. Energy is
never automatically replenished by the VM itself — the Lenie must execute
`eat` to gain energy from the world.

### `age` — metabolic tick counter

An integer that the Lenie process increments by 1 each time `run_k_instructions/3`
completes a full batch. It is not touched by the interpreter directly; it
represents how many scheduling rounds the Lenie has survived, not how many
individual opcodes it has executed.

### `pos` — grid position

A `{x, y}` tuple. The VM itself never writes `pos`; the World GenServer
writes it back after a successful `move`. The interpreter reads `pos` when
building world-interaction messages (e.g., `{:sense_front, pos, dir}`).

### `call_stack` — subroutine return addresses

A list of IPs, capped at 32 entries. `call_t` pushes the return IP onto this
list (dropping the oldest if the cap is reached). `ret` pops it. An empty
`call_stack` on `ret` causes a fall-through rather than a crash.

---

## 2. The Codeome as a Ring

A codeome is a fixed-length sequence of opcodes. The instruction pointer
wraps modulo the codeome size, making it a closed ring.

```
  codeome of size 12, ip = 3
  ┌────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┐
  │  0 │  1 │  2 │  3 │  4 │  5 │  6 │  7 │  8 │  9 │ 10 │ 11 │
  └────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘
                       ▲
                      ip
  execution continues:  4 → 5 → 6 → … → 11 → 0 → 1 → 2 → 3 → …
```

**Why the ring matters for template search.**  Jump opcodes (`jmp_t`,
`jz_t`, `jnz_t`, `call_t`) locate their targets by scanning for a
complement template — a bit-flipped mirror of the nop sequence that follows
the opcode. The scan is bounded by a configurable radius (default 256 cells)
but it wraps around the ring boundary. A template that starts near cell 11
and whose complement sits near cell 0 is found correctly because every index
is computed with `Integer.mod(pos, size)`.

**Negative indices** do not appear at runtime — `Integer.mod` in Elixir
(unlike `rem`) always returns a non-negative result — but this guarantee is
important for mutation tools that may compute `ip - k` before wrapping.

---

## 3. The Execution Loop

`step/2` executes exactly one opcode and returns a three-tuple tagged with
the outcome. `run_k_instructions/3` calls `step/2` repeatedly, stopping as
soon as any outcome other than `:cont` appears.

```
step(state, codeome):
  if codeome is empty:
    return {:halt, :empty_codeome, state}

  op = codeome[state.ip]           # fetch

  new_state = apply opcode logic   # decode + execute
            + deduct energy cost   # charge
            + advance ip by delta  # advance

  if new_state.energy <= 0:
    return {:halt, :starvation, new_state}

  if op requires world interaction:
    return {:wait_world, action_term, new_state}

  return {:cont, new_state}


run_k_instructions(state, codeome, k):
  repeat up to k times:
    result = step(state, codeome)
    if result is {:cont, new_state}:
      state = new_state
    else:
      return result          # :wait_world or :halt bubbles up immediately
  return {:cont, state}
```

The energy check and IP advance happen for **all** opcodes, including the
world-interaction group. By the time `{:wait_world, …}` is returned, the
energy has already been deducted and the IP has already advanced past the
opcode — the Lenie process only needs to call the World GenServer and handle
the reply.

---

## 4. The Three Outcomes

| Outcome        | When                                        | Examples                                                    |
|----------------|---------------------------------------------|-------------------------------------------------------------|
| `:cont`        | Ordinary opcode finished successfully       | `push0`, `push1`, `add`, `swap`, `jmp_t`, `sense_self`     |
| `:wait_world`  | Opcode needs to call the World GenServer    | `move`, `eat`, `sense_front`, `attack`, `defend`, `allocate`, `write_child`, `divide` |
| `:halt`        | Lenie is dead                               | starvation (`energy <= 0`), empty codeome                  |

`:wait_world` carries an action term that describes what the Lenie wants to
do — for example `{:move, pos, dir}` or `{:eat, pos}`. The Lenie process
forwards this to the World GenServer as a synchronous call, receives the
result, writes any updated fields (energy, pos, …) back into the state, and
then calls `run_k_instructions` again for the next batch.

`:halt` is terminal. The Lenie process removes the Lenie from the world and
the scheduler.

---

## 5. Defensive Semantics

The VM is designed to survive any codeome that mutation can produce. No
sequence of opcodes causes a crash or an invalid state.

- **Empty-stack pop returns 0.** `State.pop/1` pattern-matches on `[]` and
  returns `{0, state}`. Code that pops more than it pushed gets zeros.

- **`mod` by zero returns 0.** The `:mod` dispatch checks `if a == 0, do: 0`
  before calling `Integer.mod`. Division by zero is silently swallowed.

- **Slot index wraps mod 4.** `State.store/3` and `State.load/2` both call
  `Integer.mod(slot_idx, 4)`. Any integer is a valid slot index.

- **Unknown opcode treated as `:nop_0`.** The catch-all dispatch clause
  `defp dispatch(_unknown, state, _c, size)` calls
  `advance_and_charge(:nop_0, state, size, 1)`. An unrecognised byte wastes
  one unit of energy and advances the IP by one — nothing more.

- **Failed template search falls through.** If `Template.find_complement`
  returns `:not_found`, the jump target is set to `skip_to` (the cell
  immediately after the template), not to any special error state. Execution
  just continues past the template.

- **`ret` on empty call stack falls through.** `State.pop_call/1` returns
  `{nil, state}` when the call stack is empty. The interpreter recognises
  `nil` and advances the IP by 1, treating `ret` as a no-op.

The overarching invariant: **mutations never produce syntax errors.** The
worst a random mutation can do is waste energy — and a Lenie that wastes
energy starves naturally.

---

## 6. Stack Diagrams

Tracing `push5 ; push7 ; swap ; drop` step by step. Each column shows the
stack contents from bottom to top (top of stack at the top of the box).

```
  │   │   │ 5 │   │ 7 │   │ 5 │   │ 5 │
  │   │   │   │   │ 5 │   │ 7 │   │   │
  └───┘   └───┘   └───┘   └───┘   └───┘
  start   push5   push7    swap    drop
```

Stack effects in `( before -- after )` notation:

| Opcode  | Stack effect          |
|---------|-----------------------|
| `push5` | `( -- 5 )`            |
| `push7` | `( -- 7 )`            |
| `swap`  | `( a b -- b a )`      |
| `drop`  | `( a -- )`            |

After `push5` the stack is `[5]`. After `push7` it is `[7, 5]` (7 is the new
top). `swap` exchanges the two top elements to give `[5, 7]`. `drop` removes
the top to leave `[7]`.

---

→ Next: Chapter 2, the full opcode reference. ([02-opcode-reference.md](02-opcode-reference.md))
