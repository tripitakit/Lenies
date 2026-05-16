# Chapter 5 — Memory and Arithmetic

In chapter 4 you built a Forager that reacts to what the cell ahead contains. The Forager's decision is purely local: sense, branch, eat-or-turn, repeat. But most interesting codeomes need something more — a counter that tracks how many steps have elapsed, an index into a sequence, or a constant that controls behaviour across many iterations. The stack is perfect for short-lived computation, but a value pushed onto the stack during one pass through the loop is gone by the next time the `jmp_t` fires. You need persistent storage.

Lenies gives each codeome four **memory slots**, numbered 0 through 3. They are initialised to 0 when the codeome starts and survive for the entire lifetime of the creature, across every jump, every iteration, every branch. Think of them as hardware registers: small in number, fast to access, and always available.

This chapter covers the slot instructions, the arithmetic you need to manipulate slot values, how to build numeric constants from the limited push palette, and how `:pushN` injects randomness. Then you build two new codeomes: a Counter-walker that turns right every 8 steps, and a Turning Forager that picks its turning direction at random each cycle.

---

## 1 — Why slots and constants

Consider trying to count to 8 using only the stack. You push 8 at the top of the loop, decrement inside the body, and check whether the result is zero. On the next iteration the loop jumps back to the top — and immediately pushes 8 again, overwriting the counter you just decremented. The loop runs forever regardless.

The slot system breaks this deadlock. You write the counter into a slot once, read it back on each iteration, modify it, and write it back. The slot value persists across the backward jump without any extra machinery.

You might also need the constant 8 itself. The only push instructions available are `:push0` (pushes 0) and `:push1` (pushes 1). Larger constants have to be built by combining those, which is covered in section 3.

---

## 2 — Slot semantics

### Instructions

| Instruction | Stack effect | Description |
|-------------|-------------|-------------|
| `:store`    | `( v s -- )` | pops slot index `s` (top), pops value `v`, writes `slots[s mod 4] = v` |
| `:load`     | `( s -- v )` | pops slot index `s`, pushes `slots[s mod 4]` |

Both cost **0.5 energy** per execution.

### Order matters: slot index is on top

`:store` pops the slot index **first** (it is on top), then pops the value. This catches nearly every beginner — intuitively you might think you push the slot index first and the value on top, but the instruction interprets it the other way around.

A reliable mnemonic: _"the slot index is the most recent thing you pushed, so it sits on top."_ In English you would say "store into slot 0" — `push <value>` first, then `push 0`, then `:store`.

```
# Write 42 into slot 0
:push1, :dup, :add, ...   # any method that leaves 42 on top
:push0                    # push slot index (0)  ← on top
:store                    # pops 0 (slot idx), pops 42 (value) → slot[0] = 42
```

### Example trace

```
Instruction     Stack before    Stack after     Slots
push 42         []              [42]            {0:0, 1:0, 2:0, 3:0}
push 0          [42]            [42, 0]         {0:0, 1:0, 2:0, 3:0}
store           [42, 0]         []              {0:42, 1:0, 2:0, 3:0}
push 0          []              [0]             {0:42, 1:0, 2:0, 3:0}
load            [0]             [42]            {0:42, 1:0, 2:0, 3:0}
```

### Index wrapping

Slot indices wrap modulo 4, using Elixir's `Integer.mod/2`, which always returns a non-negative result. This means any integer — including negative values — is a valid slot index:

- index 4 → slot 0
- index 5 → slot 1
- index -1 → slot 3 (because `Integer.mod(-1, 4) == 3`)

In practice you will almost always use the constants 0, 1, 2, 3 directly via `:push0` and small arithmetic.

---

## 3 — Building constants

### 3.1 — The doubling chain

You have `:push1` (pushes 1) and `:dup` / `:add`. Doubling a value costs one `:dup` and one `:add`.

| Sequence | Result | Instruction count | Energy cost |
|----------|--------|-------------------|-------------|
| `:push1` | 1 | 1 | 0.1 |
| `:push1, :dup, :add` | 2 | 3 | 0.1 + 0.1 + 0.2 = 0.4 |
| `:push1, :dup, :add, :dup, :add` | 4 | 5 | 0.6 |
| `:push1, :dup, :add, :dup, :add, :dup, :add` | 8 | 7 | 0.8 |
| + one more `:dup, :add` | 16 | 9 | 1.0 |
| + one more `:dup, :add` | 32 | 11 | 1.2 |
| + one more `:dup, :add` | 64 | 13 | 1.4 |
| + one more `:dup, :add` | 128 | 15 | 1.6 |

Pattern: to build 2^k, use `push1` then k doublings. Energy = `0.1 + k × 0.3` (push + k doublings at 0.2 each, plus k dups at 0.1 each).

You can combine doublings with additions and subtractions to reach non-powers-of-two, but for this chapter you only need 8.

### 3.2 — Arithmetic opcodes

| Instruction | Stack effect | Description | Cost |
|-------------|-------------|-------------|------|
| `:add` | `( a b -- a+b )` | pops `b` (top), pops `a`, pushes `a + b` | 0.2 |
| `:sub` | `( a b -- a-b )` | pops `b` (top), pops `a`, pushes `a - b` | 0.2 |
| `:mul` | `( a b -- a*b )` | pops `b` (top), pops `a`, pushes `a * b` | 0.2 |
| `:mod` | `( a b -- b mod a )` | pops `a` (top), pops `b`, pushes `b mod a`; if `a == 0`, pushes 0 | 0.2 |

The **right operand** (divisor for `:mod`, subtrahend for `:sub`) is popped first because it is on top. Push the left operand first, push the right operand on top, then execute.

### 3.3 — Random values with `:pushN`

```
:pushN    ( -- r )    pushes a uniform random integer in 0..255    cost 0.1
```

`:pushN` is your source of entropy. Each call independently samples a fresh value. Use it when you want unpredictability — a random turn direction, a random wait time, stochastic sensing. Do not use it when you need a specific constant; for that, use the doubling chain.

---

## 4 — The decrement-and-test loop pattern

This is the canonical idiom for "run the body N times then exit":

```elixir
# ── Phase 1: initialise the counter ─────────────────────────────────────────
<build N on stack>       # whatever sequence produces N
:push0, :store           # slot[0] = N   (push0 is the slot index)

# ── LOOP_HEAD anchor ────────────────────────────────────────────────────────
:nop_X, :nop_Y, :nop_Z, :nop_W,   # 4-nop anchor, e.g. [1,1,1,1]

# ── Phase 2: body ────────────────────────────────────────────────────────────
# ... whatever the loop does each iteration ...

# ── Phase 3: decrement and test ──────────────────────────────────────────────
:push0, :load,           # push slot[0] onto stack    stack: [counter]
:push1, :sub,            # subtract 1                  stack: [counter-1]
:push0, :store,          # slot[0] = counter-1         stack: []
:push0, :load,           # re-read for test             stack: [counter-1]
:jnz_t, <template>,      # if non-zero, jump to LOOP_HEAD; else fall through
```

**Why re-read after storing?** `:store` consumes the value — after the store the stack is empty. You need the value on the stack to test it, so you load it back.

**Cost per iteration** (excluding the body):

| Instruction | Cost |
|-------------|------|
| `push0, load` (read counter) | 0.1 + 0.5 = 0.6 |
| `push1, sub` (decrement) | 0.1 + 0.2 = 0.3 |
| `push0, store` (write back) | 0.1 + 0.5 = 0.6 |
| `push0, load` (re-read for test) | 0.1 + 0.5 = 0.6 |
| `jnz_t` with 4-nop template | 0.2 + 0.05×4 = 0.4 |
| **Total** | **2.5 per iteration** |

The init phase (building N and storing it) is a one-time cost, paid only when the outer loop restarts.

---

## 5 — Counter-walker

A Walker that takes exactly 8 steps, then turns right, then repeats. The counter lives in slot 0.

### Design

```
INIT_HEAD [0,0,0,0]:
  build 8 on stack (push1; dup; add × 3)
  store into slot[0]

STEP_HEAD [1,1,1,1]:
  eat
  move
  load slot[0]; push1; sub; store slot[0]   # decrement
  load slot[0]                               # test value
  jnz_t [0,0,0,0]                           # → STEP_HEAD if counter > 0
  # fall through: counter hit zero
  turn_right
  jmp_t [0,1,1,1]                           # → INIT_HEAD to reset
```

Wait — `:jmp_t [0,1,1,1]` searches for anchor `[1,0,0,0]`, which does not exist. We need a template that finds INIT_HEAD `[0,0,0,0]`. The complement of `[0,0,0,0]` is `[1,1,1,1]`. So `:jmp_t :nop_1 :nop_1 :nop_1 :nop_1` goes to INIT_HEAD.

But STEP_HEAD is also a 4-nop block (`[1,1,1,1]`), which means the complement `[0,0,0,0]` is the template that finds it. And `jnz_t` carries `[0,0,0,0]` (four `:nop_0` after the jump) to find STEP_HEAD `[1,1,1,1]`. The final `jmp_t` carries `[1,1,1,1]` to find INIT_HEAD `[0,0,0,0]`. These two anchors are complements of each other — that is fine because they are distinct positions in the codeome. The forward/backward search priority ensures each jump finds the right one as long as we put STEP_HEAD between INIT_HEAD and the end of the body.

### Full codeome listing

```elixir
[
  # ── 0..3   INIT_HEAD anchor [0,0,0,0] ─────────────────────────────────────
  :nop_0, :nop_0, :nop_0, :nop_0,

  # ── 4..10  build 8: push1; dup; add × 3 ───────────────────────────────────
  :push1, :dup, :add,    # → 2
          :dup, :add,    # → 4
          :dup, :add,    # → 8

  # ── 11..12  store 8 in slot[0] ─────────────────────────────────────────────
  :push0, :store,

  # ── 13..16  STEP_HEAD anchor [1,1,1,1] ─────────────────────────────────────
  :nop_1, :nop_1, :nop_1, :nop_1,

  # ── 17..18  body: eat and move ─────────────────────────────────────────────
  :eat, :move,

  # ── 19..24  decrement slot[0] ──────────────────────────────────────────────
  :push0, :load,         # push slot[0]
  :push1, :sub,          # subtract 1
  :push0, :store,        # write back

  # ── 25..26  reload for the test ────────────────────────────────────────────
  :push0, :load,

  # ── 27..31  jnz_t → STEP_HEAD (template [0,0,0,0] finds anchor [1,1,1,1]) ─
  :jnz_t, :nop_0, :nop_0, :nop_0, :nop_0,

  # ── 32     separator (non-nop) prevents extractor from reading into TURN ───
  :push0,

  # ── 33     turn right when counter reached zero ────────────────────────────
  :turn_right,

  # ── 34..38  jmp_t → INIT_HEAD (template [1,1,1,1] finds anchor [0,0,0,0]) ─
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1
]
```

**Op count**: 39 instructions (indices 0–38). Non-nop count: `push1, add, add, add, dup, dup, dup, push0, store, eat, move, push0, load, push1, sub, push0, store, push0, load, jnz_t, push0, turn_right, jmp_t` = 23 non-nops. Well above the minimum.

### One full cycle, step by step

**Init phase (runs once per cycle, ip starts at 0):**

1. ip 0–3: four `:nop_0` — advance to ip 4.
2. ip 4–10: build 8 on the stack. Stack = `[8]`.
3. ip 11–12: `:push0, :store` — pops 0 (slot idx), pops 8 (value). Slot[0] = 8. Stack = `[]`.
4. ip 13–16: four `:nop_1` — STEP_HEAD is now behind us in the ring.

**Step phase (repeats 8 times):**

Each pass: `:eat`, `:move`, load slot[0], subtract 1, store back, reload, test with `jnz_t`. The `jnz_t` carries template `[0,0,0,0]`, complement `[1,1,1,1]`. It does not find four `:nop_1` ahead but does find STEP_HEAD behind (positions 13–16). Jumps to ip 17, repeating the body.

After 8 passes slot[0] = 0.

**Turn phase:**

The `jnz_t` tests 0 — falls through. `:push0` (separator) executes harmlessly. `:turn_right` rotates direction. `:jmp_t` carries template `[1,1,1,1]`, complement `[0,0,0,0]`, wraps around and finds INIT_HEAD at positions 0–3. Lands at ip 4. The cycle restarts from a new direction.

---

## 6 — Random branches

### Generating a fair coin

`:pushN` pushes a uniform integer in 0..255. To reduce this to a binary value (0 or 1), divide by 2 and keep the remainder:

```elixir
:pushN,               # stack: [r]  where r ∈ 0..255
:push1, :push1, :add, # stack: [r, 2]  (there is no push2; build 2 from 1+1)
:mod,                 # pops a=2 (top), pops b=r, pushes r mod 2
                      # stack: [coin]  where coin ∈ {0, 1}, each with prob 0.5
```

Total cost: 0.1 (pushN) + 0.1 + 0.1 + 0.2 (build 2) + 0.2 (mod) = **0.7 energy**.

### Routing on the coin

Once the coin is on the stack, use `:jz_t` (jump if top == 0) or `:jnz_t` (jump if top ≠ 0) to branch:

```elixir
# coin on stack
:jz_t, :nop_A, :nop_B, ...   # jump to anchor [complement(A,B,...)] if coin == 0
# fall-through path: coin was 1
...
```

One branch is explicit (the jump target); the other is the fall-through. Design which path the "turn right" vs "turn left" decision lands on.

### Mod is defensive against zero

If `:pushN` somehow pushed 0 (which cannot happen — the range is 0..255 so 0 is a valid value — but imagine building the divisor with arithmetic), the `:mod` implementation returns 0 rather than crashing. The rule: if the divisor `a` is 0, the result is 0. Keep this in mind if you use `:mod` with a dynamically computed divisor.

---

## 7 — Turning Forager

The Turning Forager is the Forager from chapter 4 with its unconditional `:turn_right` replaced by a random left/right decision. The structure extends the Forager's two-state machine (LOOP, TURN) into a four-state machine:

```
LOOP_HEAD:
    sense_front
    jz_t → TURN_HEAD         # empty ahead → time to turn
    eat
    move
    jmp_t → LOOP_HEAD

TURN_HEAD:
    pushN; push1; push1; add; mod   # fair coin
    jz_t → TURN_LEFT_HEAD           # coin=0 → turn left
    turn_right                       # coin=1 → fall through, turn right
    jmp_t → AFTER_TURN_HEAD

TURN_LEFT_HEAD:
    turn_left

AFTER_TURN_HEAD:
    jmp_t → LOOP_HEAD
```

### Anchor assignments

We need four distinct anchors, no two of which are complements of each other (to avoid a jump accidentally matching the wrong target):

| Label | Anchor | Template to jump here |
|-------|--------|----------------------|
| LOOP_HEAD | `[0,0,0,0]` | `[1,1,1,1]` |
| TURN_HEAD | `[0,1,0,1]` | `[1,0,1,0]` |
| TURN_LEFT_HEAD | `[1,1,0,0]` | `[0,0,1,1]` |
| AFTER_TURN_HEAD | `[1,0,1,1]` | `[0,1,0,0]` |

Verification: none of these four anchors is the bitwise complement of another:
- `[0,0,0,0]` ↔ complement is `[1,1,1,1]` — not in the list.
- `[0,1,0,1]` ↔ complement is `[1,0,1,0]` — not in the list.
- `[1,1,0,0]` ↔ complement is `[0,0,1,1]` — not in the list.
- `[1,0,1,1]` ↔ complement is `[0,1,0,0]` — not in the list.

All templates used are also mutually distinct. Search uniqueness holds.

### Full codeome listing

```elixir
[
  # ── 0..3    LOOP_HEAD [0,0,0,0] ────────────────────────────────────────────
  :nop_0, :nop_0, :nop_0, :nop_0,

  # ── 4       sense the cell ahead ───────────────────────────────────────────
  :sense_front,

  # ── 5..9    jz_t → TURN_HEAD if cell ahead is empty ───────────────────────
  #            template [1,0,1,0] searches for anchor [0,1,0,1]
  :jz_t, :nop_1, :nop_0, :nop_1, :nop_0,

  # ── 10..11  cell is occupied: eat and move ──────────────────────────────────
  :eat, :move,

  # ── 12..16  jmp_t → LOOP_HEAD (template [1,1,1,1] finds [0,0,0,0]) ─────────
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,

  # ── 17      separator: non-nop to stop extractor from bleeding into TURN ───
  :push0,

  # ── 18..21  TURN_HEAD anchor [0,1,0,1] ─────────────────────────────────────
  :nop_0, :nop_1, :nop_0, :nop_1,

  # ── 22..26  fair coin: pushN; push1; push1; add; mod ───────────────────────
  :pushN, :push1, :push1, :add, :mod,

  # ── 27..31  jz_t → TURN_LEFT_HEAD if coin == 0 ─────────────────────────────
  #            template [0,0,1,1] searches for anchor [1,1,0,0]
  :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

  # ── 32      coin was 1 → turn right ────────────────────────────────────────
  :turn_right,

  # ── 33..37  jmp_t → AFTER_TURN_HEAD (template [0,1,0,0] finds [1,0,1,1]) ──
  :jmp_t, :nop_0, :nop_1, :nop_0, :nop_0,

  # ── 38      separator ───────────────────────────────────────────────────────
  :push0,

  # ── 39..42  TURN_LEFT_HEAD anchor [1,1,0,0] ────────────────────────────────
  :nop_1, :nop_1, :nop_0, :nop_0,

  # ── 43      coin was 0 → turn left ─────────────────────────────────────────
  :turn_left,

  # ── 44      separator ───────────────────────────────────────────────────────
  :push0,

  # ── 45..48  AFTER_TURN_HEAD anchor [1,0,1,1] ───────────────────────────────
  :nop_1, :nop_0, :nop_1, :nop_1,

  # ── 49..53  jmp_t → LOOP_HEAD (template [1,1,1,1] finds [0,0,0,0]) ─────────
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1
]
```

**Op count**: 54 instructions (indices 0–53). Non-nop count: `sense_front, jz_t, eat, move, jmp_t, push0, pushN, push1, push1, add, mod, jz_t, turn_right, jmp_t, push0, turn_left, push0, jmp_t` = 18 non-nops, well above the minimum of 10.

### Walk-through: one turn decision

Cell ahead is empty. At ip 4, `:sense_front` pushes 0. The `jz_t` at ip 5 fires (template `[1,0,1,0]`, complement `[0,1,0,1]`), landing at ip 22 (inside TURN_HEAD).

`:pushN` pushes, say, 173. `:push1, :push1, :add` builds 2. `:mod` computes `173 mod 2 = 1` (odd → coin = 1). The `jz_t` at ip 27 does not fire (coin ≠ 0); fall-through reaches `:turn_right` at ip 32. Then `:jmp_t` (template `[0,1,0,0]`, complement `[1,0,1,1]`) finds AFTER_TURN_HEAD at positions 45–48 and lands at ip 49. The final `jmp_t` (template `[1,1,1,1]`) wraps back to ip 4. The creature resumes sensing, now pointing right.

If `:pushN` had returned an even number, coin = 0, and the `jz_t` at ip 27 would have fired (template `[0,0,1,1]`, complement `[1,1,0,0]`), landing at TURN_LEFT_HEAD (ip 43), executing `:turn_left` instead.

---

## 8 — Stack trace for one counter-walker cycle

The table below shows the state at the **end of each iteration** of the step loop (after the `jnz_t` fires back to ip 17). Energy figures are approximate and assume the creature starts each iteration with enough energy to complete it.

```
Iter  slot[0] before decrement  Action              slot[0] after  jnz_t fires?
----  -------------------------  ------------------  -------------  ------------
  1   8                          eat + move          7              yes (7 ≠ 0)
  2   7                          eat + move          6              yes (6 ≠ 0)
  3   6                          eat + move          5              yes (5 ≠ 0)
  4   5                          eat + move          4              yes (4 ≠ 0)
  5   4                          eat + move          3              yes (3 ≠ 0)
  6   3                          eat + move          2              yes (2 ≠ 0)
  7   2                          eat + move          1              yes (1 ≠ 0)
  8   1                          eat + move          0              no  (0 == 0)
```

On iteration 8 the `jnz_t` falls through. The `:push0` separator executes (pushing a harmless 0), `:turn_right` rotates the creature, and `:jmp_t` returns to INIT_HEAD where slot[0] is reset to 8 and the cycle begins again.

Below is a more detailed trace of the decrement/test subsequence for iteration 8 (going from slot[0]=1 to slot[0]=0):

```
ip    Instruction   Stack before   Stack after   slot[0]
19    push0         []             [0]           1
20    load          [0]            [1]           1
21    push1         [1]            [1, 1]        1
22    sub           [1, 1]         [0]           1
23    push0         [0]            [0, 0]        1
24    store         [0, 0]         []            0
25    push0         []             [0]           0
26    load          [0]            [0]           0
27    jnz_t (test)  [0]            []            0     ← 0 == 0, falls through
32    push0         []             [0]           0
33    turn_right    [0]            [0]           0     ← direction rotates
34    jmp_t         [0]            [0]           0     ← jumps to ip 4
```

---

## 9 — Try it

### Register the codeomes

Add both codeomes to your project's codeome registry. Suggested names:

**counter-walker-v1**

```elixir
def counter_walker_v1 do
  [
    :nop_0, :nop_0, :nop_0, :nop_0,
    :push1, :dup, :add, :dup, :add, :dup, :add,
    :push0, :store,
    :nop_1, :nop_1, :nop_1, :nop_1,
    :eat, :move,
    :push0, :load, :push1, :sub, :push0, :store,
    :push0, :load,
    :jnz_t, :nop_0, :nop_0, :nop_0, :nop_0,
    :push0,
    :turn_right,
    :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1
  ]
end
```

**turning-forager-v1**

```elixir
def turning_forager_v1 do
  [
    :nop_0, :nop_0, :nop_0, :nop_0,
    :sense_front,
    :jz_t, :nop_1, :nop_0, :nop_1, :nop_0,
    :eat, :move,
    :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,
    :push0,
    :nop_0, :nop_1, :nop_0, :nop_1,
    :pushN, :push1, :push1, :add, :mod,
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,
    :turn_right,
    :jmp_t, :nop_0, :nop_1, :nop_0, :nop_0,
    :push0,
    :nop_1, :nop_1, :nop_0, :nop_0,
    :turn_left,
    :push0,
    :nop_1, :nop_0, :nop_1, :nop_1,
    :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1
  ]
end
```

### Spawn and observe

Spawn 5 of each in a 64×64 world with `food_density: 0.3` and run for 2 000 steps.

**What to look for:**

- Counter-walkers leave straight trails of length ~8, then turn — forming a zigzag or loose spiral.
- Turning foragers trace irregular random-walk paths. Because the turn direction is independent each cycle, they do not systematically return to depleted areas and may outlast the deterministic Forager in sparse food fields.

---

## 10 — What's next

The creatures in this chapter still cannot communicate with each other or reuse common logic. A longer codeome will inevitably repeat idioms — the coin-flip block, the decrement loop — verbatim. Chapter 6 introduces subroutines: the `:call_t` and `:ret` instructions, which let one part of a codeome invoke another part by template search, returning cleanly when done.

→ Next: Chapter 6 introduces subroutines via `:call_t` / `:ret`. ([06-procedures.md](06-procedures.md))
