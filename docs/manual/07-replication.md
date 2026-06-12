# Chapter 7 — Replication

You have built creatures that move, sense, and eat — Reflex and the Stepper. Now you will teach a Lenie to reproduce.
Replication is the centrepiece of the Lenies simulator: it is the mechanism through which
codeomes are inherited, mutated, and selected. This chapter covers the three opcodes that
make it possible — `allocate`, `write_child`, and `divide` — and walks you through two
complete replicators of increasing sophistication.

---

## 7.1  The replication protocol

Reproduction in Lenies is a three-step protocol, not a single instruction. The parent lenie
must cooperate with the World at each step.

```
Step 1: allocate(N)
        Parent pops N, asks World to reserve a child buffer of size N
        in the cell directly in front of the parent.
        World replies on the stack:
          1  - buffer reserved (ok)
          0  - front cell occupied / off-grid / already reserved (no_target)

Step 2: write_child(addr, op_int)   [repeated N times]
        Parent pops op_int (top), pops addr.
        World writes decode(op_int) into buffer[addr mod N].
        Mutations may occur here (substitution / insertion / deletion).
        World replies:
          1  - written
          0  - no pending buffer (write silently ignored)

Step 3: divide
        Parent asks World to spawn a child from the pending buffer
        in the front cell.
        World gives the child energy/2; parent retains the other half.
        No value is pushed on the stack.
```

**Step 1 — Reserve space.** The parent declares how large the child should be. The World
checks the front cell (the cell immediately ahead in the direction the parent is facing). If it
is empty and within the grid, the World creates a pending buffer of that size and pushes `1`.
If the front cell is occupied, out of bounds, or a buffer is already pending for this parent,
the World pushes `0`. The buffer persists until `divide` consumes it.

**Step 2 — Fill the buffer.** The parent iterates over every address from 0 to N-1 and calls
`write_child` once per address. The opcode is passed as an integer (the integer encoding
described in section 7.5). The World decodes the integer, applies probabilistic copy errors,
and writes the result into the buffer. A failed or missing allocation causes `write_child` to be
a silent no-op (the World replies `0`, and the parent should `:drop` that reply).

**Step 3 — Spawn.** `divide` triggers the actual birth. The World constructs a new Lenie from
the buffer, places it in the front cell, and splits energy: the child gets half, the parent keeps
half. If there is no pending buffer (allocation failed and the parent divided anyway), `divide`
is a no-op — the parent still pays the 10.0 energy cost.

---

## 7.2  `allocate(N)`

**Stack effect:** `( n -- 1|0 )`

```
pop  n        <- number of opcodes in the child codeome
send {:allocate, n, pos, dir} to World
push 1        <- if the front cell is free and on-grid
push 0        <- otherwise
```

The cost formula from `Lenies.Codeome.Costs`:

```elixir
def cost(:allocate, size_arg), do: 5.0 + 0.05 * size_arg
```

So allocating a 43-op child costs `5.0 + 0.05 × 43 = 7.15`. Allocating a 121-op codeome costs
`5.0 + 0.05 × 121 = 11.05`. Larger children cost proportionally more to reserve.

The World can reject the request for several reasons:

- The front cell is already occupied by another lenie.
- The front cell is off the grid edge.
- This parent already has a pending allocation (only one pending child per parent).
- The requested size is outside the codeome length bounds (`{5, 1024}` by default) — sizes
  below 5 or above 1024 are rejected as `:invalid_size`.

In all failure cases the World pushes `0`. A well-written replicator checks the return value
and skips the copy loop if allocation failed. The mini-replicator in section 7.7 deliberately
does not — we will see what happens.

---

## 7.3  `write_child(addr, op_int)`

**Stack effect:** `( addr op_int -- 1|0 )`

```
pop  op_int   <- integer encoding of the opcode to write (top of stack)
pop  addr     <- position in the child buffer (second from top)
send {:write_child, op_int, addr} to World
push 1        <- written ok
push 0        <- no pending buffer (allocation failed or not yet called)
```

The World:

1. Computes the effective address as `addr mod N` (where N is the reserved buffer size),
   so you never need to bounds-check manually.
2. Decodes `op_int` via `Lenies.Codeome.Opcodes.decode/1`. Integers outside `0..39` decode
   to `:nop_0` defensively.
3. Applies probabilistic copy errors before writing: substitution (replace with a random
   opcode), insertion (shift subsequent opcodes right), or deletion (shift left). Rates are
   configured in `config/runtime.exs`. This is the primary source of heritable variation.

Cost: **1.0 per call**, regardless of N. Copying a 43-op codeome costs 43.0 in `write_child`
calls alone, before allocation and divide overhead.

Because `write_child` always pushes a reply (1 or 0), you must `:drop` it after each call
unless you want to accumulate replies on the data stack.

---

## 7.4  `divide`

**Stack effect:** `( -- )` — no value pushed.

```
send {:divide, energy, pos, dir} to World
```

Cost: **10.0**.

The World checks whether this parent has a pending allocation buffer. If yes:

- A new Lenie is constructed from the buffer and placed in the front cell.
- Energy is split: the child receives `parent.energy / 2`, the parent retains the other half.
  (The 10.0 cost is deducted before the split, from the parent's current energy.)

If there is no pending buffer (allocation never called, or it failed):

- `divide` is a silent no-op. The parent pays 10.0 and nothing happens.

After `divide` the instruction pointer advances normally to the next instruction. There is no
automatic halt — the parent keeps running. This is important: what happens next is entirely
up to the codeome.

---

## 7.5  `read_self(addr)`

**Stack effect:** `( addr -- op_int )`

```
pop  addr
push encode(codeome[addr mod size])
```

Cost: **0.3**.

`read_self` lets a lenie inspect its own codeome at runtime. It is the mechanism by which a
self-replicator reads its own instructions to copy them into the child buffer.

The return value is an **integer encoding** of the opcode, not the opcode atom. The encoding
is the index of the opcode in the whitelist defined in `Lenies.Codeome.Opcodes`:

The full 40-entry whitelist (from `Lenies.Codeome.Opcodes`):

```
nop_0(0),  nop_1(1),  push0(2),  push1(3),  pushN(4),   dup(5),   drop(6),  swap(7),
add(8),    sub(9),    mul(10),   mod(11),
jmp_t(12), jz_t(13), jnz_t(14), call_t(15), ret(16),
sense_front(17), sense_self(18), sense_energy(19), sense_age(20), sense_size(21),
move(22),  turn_left(23), turn_right(24), eat(25),
attack(26), defend(27),
get_ip(28), get_size(29), read_self(30),
allocate(31), write_child(32), divide(33),
store(34), load(35), make_plasmid(36), conjugate(37),
jlt_t(38), jgt_t(39)
```

40 entries (indices 0–39). Out-of-range integers decode to `:nop_0` (index 0).

---

## 7.6  Why the integer encoding matters

When you copy a codeome you operate in integer space, not atom space. `read_self` returns
an integer; `write_child` consumes an integer. You never manipulate opcode atoms at runtime.

This has two important consequences:

**Arithmetic on opcodes is possible** (though usually not useful): you could add 1 to an
opcode integer before writing it to shift from `:nop_0` to `:nop_1`, or from `:store` to
`:load`. This opens the door to codeomes that self-modify or deliberately corrupt children.

**Out-of-range integers are safe.** If a mutation corrupts an opcode integer to 99, the World
decodes it as `:nop_0`. The child still runs; it just does nothing at that position. This is
why codeome mutations never crash the VM — there are no illegal instructions, only less
useful ones.

The World handles all encoding and decoding transparently. Your replicator just needs to
read integers and write integers.

---

## 7.7  Mini-replicator (one-shot)

Before building the full sustainable replicator, we start with the simplest possible version:
copy once, divide, then see what happens. This is intentionally incomplete — understanding
why it fails motivates the forage cycle in section 7.9.

### The skeleton

```elixir
[
  # == pos 0..3   LOOP_HEAD anchor [1,1,1,1] ================================
  :nop_1, :nop_1, :nop_1, :nop_1,

  # == pos 4..6   get own size N, store in slot[0] ==========================
  :get_size, :push0, :store,

  # == pos 7..9   load N, request allocation ================================
  :push0, :load, :allocate,

  # == pos 10     drop the allocate reply (1 or 0) - we ignore it ===========
  :drop,

  # == pos 11..13 init copy counter: slot[1] = 0 ============================
  :push0, :push1, :store,

  # == pos 14..17 COPY_LOOP anchor [1,0,0,1] ================================
  :nop_1, :nop_0, :nop_0, :nop_1,

  # == pos 18..20 read_self at counter (slot[1]) -> op_int on stack =========
  :push1, :load, :read_self,

  # == pos 21..25 write_child at counter ====================================
  # Stack before: [op_int]
  # write_child needs (addr op_int --), addr on second, op_int on top.
  # Push counter (addr), then swap so [addr op_int] -> write_child -> drop reply.
  :push1, :load, :swap, :write_child, :drop,

  # == pos 26..31 increment counter: slot[1] += 1 ===========================
  :push1, :load, :push1, :add, :push1, :store,

  # == pos 32..36 loop condition: N - counter -> 0 means done ===============
  :push0, :load, :push1, :load, :sub,

  # == pos 37..41 jnz_t back to COPY_LOOP ===================================
  :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

  # == pos 42     divide ====================================================
  :divide
]
```

Length: **43 opcodes**.

### Walk-through

**LOOP_HEAD (pos 0–3):** Four `:nop_1` form the anchor. A `jmp_t` elsewhere in the codeome
would jump here by searching for the complement template `[0,0,0,0]`. The mini-replicator has
no such jump — the anchor is present only as forward compatibility for the sustainable version.

**Get size (pos 4–6):** `get_size` pushes the lenie's own codeome length (43 in this case).
`push0` pushes the slot index 0. `:store` pops `0` (slot index, top) then pops `43` (value,
second) and stores 43 in `slot[0]`. Now we know N = 43.

**Allocate (pos 7–10):** `push0` + `load` loads `slot[0]` (= 43). `allocate` pops 43,
requests a child buffer of size 43 in the front cell, and the World pushes 1 (ok) or 0
(blocked) onto the stack. `:drop` discards the reply — this replicator has no failure handling.

**Init counter (pos 11–13):** `push0` (value 0) + `push1` (slot index 1) + `:store` writes
0 into `slot[1]`. This is the copy-loop counter, tracking which opcode we are currently
writing to the child.

**COPY_LOOP (pos 14–17):** Anchor `[1,0,0,1]`. The `jnz_t` at pos 37 searches for the
complement `[0,1,1,0]` — wait, no. `jnz_t` reads the template *after itself* (pos 38–41:
`[0,1,1,0]`) and searches for the complement `[1,0,0,1]`. That complement matches the
anchor at pos 14–17. Correct.

**Read and write (pos 18–25):** This is the heart of the copy loop.

```
pos 18: push1        -> stack: [1]
pos 19: load         -> pops 1, pushes slot[1] (the counter)  -> stack: [counter]
pos 20: read_self    -> pops counter, pushes encode(codeome[counter mod 43]) -> stack: [op_int]
pos 21: push1        -> stack: [op_int, 1]
pos 22: load         -> pops 1, pushes slot[1] (counter again) -> stack: [op_int, counter]
pos 23: swap         -> stack: [counter, op_int]
pos 24: write_child  -> pops op_int (top), pops counter (addr), writes to child -> pushes 1|0
pos 25: drop         -> discards the write_child reply
```

After pos 25 the stack is empty (as at the start of the loop body).

**Increment counter (pos 26–31):**

```
push1 + load    -> push slot[1] (counter)        -> stack: [counter]
push1           -> push 1                         -> stack: [counter, 1]
add             -> pops both, pushes counter+1    -> stack: [counter+1]
push1 + store   -> pops 1 (slot), pops counter+1, stores in slot[1]
```

**Loop condition (pos 32–36):**

```
push0 + load    -> push slot[0] (= N = 43)        -> stack: [N]
push1 + load    -> push slot[1] (counter)          -> stack: [N, counter]
sub             -> pops counter (top), pops N, pushes N - counter
```

When counter = N, `N - counter = 0`, so `jnz_t` does not jump and execution falls through
to `divide`. When counter < N, `N - counter > 0`, so `jnz_t` jumps back to COPY_LOOP.

**Divide (pos 42):** The World spawns a child from the pending buffer, splits energy, and
the parent continues to the next instruction — which wraps around the ring to pos 0.

### The deliberate failure mode

After `:divide`, the instruction pointer advances to position 43 — which does not exist. The
codeome is a circular ring, so the ip wraps to position 0 and the parent re-enters LOOP_HEAD.

The parent now tries to allocate again. But the front cell is occupied by the child it just
spawned. The World replies with 0 (no_target) and pushes 0 onto the stack. `:drop` discards
it. The parent then enters the copy loop — but there is no pending allocation, so every
`write_child` call is a silent no-op (though it still costs 1.0 each). After the loop the
parent calls `divide` again — another no-op, another 10.0 wasted.

Across this wasted cycle the parent spends:

- 43 × 1.0 (write_child no-ops) = 43.0
- 10.0 (divide no-op)
- overhead (load, store, add, sub, jnz_t...) ≈ 20+

Around 73 energy per wasted iteration, with zero income. Within a few cycles the parent
starves and dies. The child, having inherited no forage logic either, also starves quickly.

**This is intentional.** The mini-replicator shows you the mechanism in its simplest form.
Section 7.9 adds the forage cycle that makes replication sustainable.

---

## 7.8  Stack-effect cheat sheet for `write_child`

The `write_child` stack effect is the trickiest part for newcomers. Here it is explicitly:

```
write_child  ( addr op_int -- 1|0 )
             pops op_int (top of stack)
             pops addr   (second from top)
             pushes 1 (written) or 0 (no pending buffer)
```

To write opcode integer `X` into the child buffer at address `A`:

```elixir
# Method 1 - push addr first, then op_int (natural order)
:push0        # or however you get A onto the stack
              # ... A is now on top
:push1        # or however you get X
              # stack: [A, X] - X on top, A on second
:write_child  # pops X, pops A, writes codeome[A] = decode(X)
:drop         # discard the reply
```

```elixir
# Method 2 - op_int already on stack, push addr and swap
              # ... op_int (X) is already on top from read_self
:push1        # push counter (which is A)
:load         # stack: [X, A] - A on top, X on second
:swap         # stack: [A, X] - X on top, A on second
:write_child  # pops X, pops A
:drop
```

The mini-replicator uses **Method 2**: `read_self` leaves `op_int` on the stack. We then
push the counter twice (once as the `read_self` address, once as the `write_child` address),
reload it, swap to put `op_int` back on top, and call `write_child`.

The swap is necessary because `read_self` has consumed the counter from the stack (it pops
`addr`). When we reload the counter for `write_child` it lands on top, but `write_child`
expects `op_int` on top and `addr` below. `:swap` fixes the order.

---

## 7.9  Sustainable replicator

The sustainable replicator adds a forage cycle between divisions. After dividing, instead of
immediately wrapping back to LOOP_HEAD, the parent turns randomly, then runs K = 64 iterations
of `eat`+`move` to replenish its energy before attempting the next replication.

### Algorithm outline

```
LOOP_HEAD:
  get_size -> store in slot[0]        (N = own codeome size)
  push0; load; allocate              (request child buffer of size N)
  drop                               (ignore allocate reply)
  push0; push1; store                (init copy counter slot[1] = 0)

COPY_LOOP:
  push1; load; read_self             (read opcode at counter)
  push1; load; swap; write_child     (write it to child at counter)
  drop                               (discard write_child reply)
  push1; load; push1; add; push1; store   (slot[1] += 1)
  push0; load; push1; load; sub     (N - counter)
  jnz_t [0,1,1,0]                   (-> COPY_LOOP while counter < N)

  divide

  (fall through to random turn block)

TURN_BLOCK:
  pushN; push1; push1; add; mod     (random r in 0..1 via r mod 2)
  jz_t [template -> TURN_LEFT]       (if r == 0 go left)
  turn_right
  jmp_t [template -> AFTER_TURN]
  [separator :push0]
TURN_LEFT:
  turn_left
AFTER_TURN:                          (both branches converge here)

FORAGE_INIT:
  push1; dup; add; dup; add; dup; add; dup; add; dup; add; dup; add   (build 64)
  push0; store                       (slot[0] = 64)

FORAGE_LOOP:
  sense_front; drop                  (sense but ignore result)
  eat                                (eat current cell)
  move                               (move forward)
  push0; load; push1; sub; push0; store   (slot[0] -= 1)
  push0; load                        (push counter for check)
  jnz_t [template -> FORAGE_LOOP]    (loop if counter != 0)

  jmp_t [template -> LOOP_HEAD]      (back to top for next replication)
```

### Anchor table

Template-based jumps use a 4-bit nop pattern. The `jnz_t` / `jmp_t` / `jz_t` opcode reads
the nops immediately following it as the jump template, then searches for the **complement**
(flip every `nop_0 ↔ nop_1`) to find the target label.

| Label          | Anchor (in codeome)    | Jump template (complement) |
|:---------------|:-----------------------|:---------------------------|
| LOOP_HEAD      | `[1,1,1,1]`            | `[0,0,0,0]`                |
| COPY_LOOP      | `[1,0,0,1]`            | `[0,1,1,0]`                |
| TURN_LEFT      | `[0,1,0,1]`            | `[1,0,1,0]`                |
| AFTER_TURN     | `[1,0,1,1]`            | `[0,1,0,0]`                |
| FORAGE_LOOP    | `[1,1,0,1]`            | `[0,0,1,0]`                |

No two anchors in this table are complements of each other, so no jump can accidentally
land on the wrong label. Verify: complement of `[1,1,1,1]` is `[0,0,0,0]` — not in the
anchor list. Complement of `[1,0,0,1]` is `[0,1,1,0]` — not in the list. And so on.

### Two required separators

The template-extractor reads consecutive nops until it hits a non-nop or reaches
`template_max_len` (default 8). If two nop blocks are adjacent in the codeome (or wrap
around the ring into each other) the extractor will read too many nops and the wrong
complement will be computed.

Two separators — a `:push0` in dead (unreachable) code — are needed:

1. **Between the `jmp_t` to AFTER_TURN and the TURN_LEFT anchor.** The `jmp_t` template
   (4 nops) ends immediately before TURN_LEFT's 4-nop anchor. Without a separator the
   extractor would read 8 nops.

2. **Between the final `jmp_t` to LOOP_HEAD and the LOOP_HEAD anchor at position 0.**
   The codeome is circular. The `jmp_t` template ends at the last position; LOOP_HEAD
   starts at position 0. Without a separator the wrap makes the extractor see 8 nops.

Both separators are `:push0` and are never executed (control flow always jumps past them).

### Complete codeome listing

```elixir
[
  # == pos 0..3    LOOP_HEAD anchor [1,1,1,1] ================================
  :nop_1, :nop_1, :nop_1, :nop_1,

  # == pos 4..6    get own size N, store in slot[0] ==========================
  :get_size, :push0, :store,

  # == pos 7..9    load N, allocate child buffer =============================
  :push0, :load, :allocate,

  # == pos 10      drop allocate reply =======================================
  :drop,

  # == pos 11..13  init copy counter slot[1] = 0 =============================
  :push0, :push1, :store,

  # == pos 14..17  COPY_LOOP anchor [1,0,0,1] ================================
  :nop_1, :nop_0, :nop_0, :nop_1,

  # == pos 18..20  read_self at counter ======================================
  :push1, :load, :read_self,

  # == pos 21..25  write_child at counter, drop reply ========================
  :push1, :load, :swap, :write_child, :drop,

  # == pos 26..31  slot[1] += 1 ==============================================
  :push1, :load, :push1, :add, :push1, :store,

  # == pos 32..36  loop condition: N - counter ===============================
  :push0, :load, :push1, :load, :sub,

  # == pos 37..41  jnz_t -> COPY_LOOP while N - counter != 0 =================
  :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

  # == pos 42      divide ====================================================
  :divide,

  # == pos 43..47  random turn: pushN; (push1; push1; add) builds 2; mod =====
  # Computes r = pushN mod 2 -> 0 or 1
  :pushN, :push1, :push1, :add, :mod,

  # == pos 48..52  jz_t -> TURN_LEFT if r == 0 ===============================
  :jz_t, :nop_1, :nop_0, :nop_1, :nop_0,

  # == pos 53      turn_right (r == 1 branch) ================================
  :turn_right,

  # == pos 54..58  jmp_t -> AFTER_TURN =======================================
  :jmp_t, :nop_0, :nop_1, :nop_0, :nop_0,

  # == pos 59      separator (dead code) =====================================
  :push0,

  # == pos 60..63  TURN_LEFT anchor [0,1,0,1] ================================
  :nop_0, :nop_1, :nop_0, :nop_1,

  # == pos 64      turn_left (r == 0 branch) =================================
  :turn_left,

  # == pos 65..68  AFTER_TURN anchor [1,0,1,1] ===============================
  :nop_1, :nop_0, :nop_1, :nop_1,

  # == pos 69..81  build K=64 on stack: push1, then 6 doublings ==============
  # push1 -> 1; dup+add -> 2; dup+add -> 4; ... dup+add -> 64
  :push1,
  :dup, :add,
  :dup, :add,
  :dup, :add,
  :dup, :add,
  :dup, :add,
  :dup, :add,

  # == pos 82..83  store 64 in slot[0] =======================================
  :push0, :store,

  # == pos 84..87  FORAGE_LOOP anchor [1,1,0,1] ==============================
  :nop_1, :nop_1, :nop_0, :nop_1,

  # == pos 88..91  forage body: sense, drop, eat, move =======================
  :sense_front, :drop, :eat, :move,

  # == pos 92..97  slot[0] -= 1 ==============================================
  :push0, :load, :push1, :sub, :push0, :store,

  # == pos 98..99  load counter for jnz_t check ==============================
  :push0, :load,

  # == pos 100..104 jnz_t -> FORAGE_LOOP while counter != 0 ==================
  :jnz_t, :nop_0, :nop_0, :nop_1, :nop_0,

  # == pos 105..109 jmp_t -> LOOP_HEAD for next replication ==================
  :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,

  # == pos 110     separator (dead code) =====================================
  # Prevents template-extractor from reading jmp_t template + LOOP_HEAD anchor
  # through the ring wrap as a single 8-nop run.
  :push0
]
```

Total length: **111 opcodes**.

### Walk-through of the sustainable replicator

**LOOP_HEAD to divide (pos 0–42):** Identical to the mini-replicator. Get size, allocate,
drop reply, copy loop, divide. The only change is that allocation failure is still silently
ignored — in a real evolutionary setting you might add a `jz_t` to skip the copy loop, but
for this tutorial we keep it simple.

**Random turn (pos 43–64):** After dividing, the parent is still facing the front cell —
which is now occupied by the child. If the parent tries to move forward it will be blocked.
The random turn sidesteps this:

- `pushN` pushes a random integer in 0..255.
- `push1; push1; add` builds 2 (since there is no `push2` opcode, we add 1+1).
- `mod` computes `random mod 2` → either 0 or 1.
- `jz_t` with template `[1,0,1,0]` jumps to TURN_LEFT anchor `[0,1,0,1]` if top is 0.
- If the jump does not happen (value is 1), `turn_right` executes, then `jmp_t` to
  AFTER_TURN skips over the left-turn branch.
- The separator `:push0` at pos 59 prevents the template extractor from merging the
  `jmp_t` template with the TURN_LEFT anchor.

This is the same random-turn pattern from Chapter 5. If you built the Wanderer, this is
already familiar.

**Build K=64 (pos 69–83):** `push1` puts 1 on the stack (pos 69). Then six rounds of
`dup; add` (pos 70–81) double it: 2, 4, 8, 16, 32, 64. `push0; store` (pos 82–83) saves 64
in `slot[0]`, overwriting the N that was stored there during the replication phase. The two
uses of `slot[0]` do not overlap: by the time we reach this code, N is no longer needed.

**FORAGE_LOOP (pos 84–104):** The body runs 64 times:

1. `sense_front` pushes a value describing the cell ahead; `:drop` discards it (we eat
   regardless of what is there).
2. `eat` consumes resources from the current cell (not the front cell — the lenie eats
   where it stands).
3. `move` advances one step forward.
4. `slot[0] -= 1` decrements the forage counter.
5. `push0; load` reloads the counter.
6. `jnz_t` loops back to FORAGE_LOOP while the counter is non-zero.

After 64 iterations the counter reaches 0 and `jnz_t` does not jump.

**Return to LOOP_HEAD (pos 105–110):** `jmp_t` with template `[0,0,0,0]` searches for the
complement `[1,1,1,1]` — which is the LOOP_HEAD anchor at pos 0. The match lands at pos 4
(just past the 4-nop anchor), where `get_size` begins the next replication cycle. The
separator at pos 110 ensures the template extractor reads exactly 4 nops from the template
and does not bleed into the anchor through the ring wrap.

---

## 7.10  Why the forage cycle

Without forage, the parent dies after one division. Divide costs 10.0, plus the entire copy
loop (~N × 1.0 + setup ≈ N + 20). For a 111-op replicator that is about 130 energy per
replication — all spent before the child is even born. After the split, each lenie has
roughly half of whatever was left, and neither has enough energy to replicate again.

With K = 64 iterations of eat+move, the parent earns roughly `K × (eat_gain − cost_per_step)`
energy per cycle. At the default `eat_amount = 20` and per-step cost of about 6.6 (sense 0.5
+ drop 0.1 + eat 2.0 + move 2.0 + counter arithmetic ~2.0), the net gain is approximately
`64 × (20 − 6.6) ≈ 858` energy per forage cycle. That comfortably covers the ~130-unit
replication cost and leaves energy for the next generation. Chapter 8 does the full budget
analysis.

---

## 7.11  Try it

### Mini-replicator

1. Open the Codeome Editor (the palette icon in the toolbar).
2. Enter the 43-opcode list from section 7.7.
3. Save as `mini-replicator-v1`.
4. Spawn one instance with 10 000 energy on a default world.

What to expect:

- Within a second or two you will see a second coloured dot appear next to the first
  (the child has been born).
- Both dots will stop moving almost immediately — neither parent nor child has any forage
  logic.
- Within about 30 seconds both dots will disappear as they starve.

The world returns to silence. This is the expected outcome.

### Sustainable replicator

1. Open the Codeome Editor.
2. Enter the 111-opcode list from section 7.9.
3. Save as `sustainable-replicator-v1`.
4. Spawn one instance with 10 000 energy on a default world.

What to expect:

- The parent moves around, eating. After a few seconds of foraging it pauses (the replication
  cycle starts), and a child appears adjacent to it.
- The parent turns and continues foraging; the child does the same.
- Population should reach 5–10 within about a minute, depending on resource density.
- If resources are plentiful the colony grows; if the world is sparse the population
  stabilises or slowly declines until all individuals happen to be facing empty cells
  (a common early-extinction pattern).

If you see the population plateau at 1–2 rather than growing, the most likely cause is that
the front cell is always occupied when `allocate` is called. Try adding a `jz_t` after
`allocate` to skip the copy loop on failure, matching the pattern in the full
`Ancestor` implementation (chapter 9).

---

## 7.12  What's next

The sustainable replicator works, but by how much? Chapter 8 builds the energy balance model
that tells you whether a given codeome design will thrive, stagnate, or collapse — and how
to tune K, N, and forage strategy to hit a target population size.

→ Next: [Chapter 8 — Energy Economy](08-energy-economy.md)
