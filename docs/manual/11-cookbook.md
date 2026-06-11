# Chapter 11 — Cookbook

This chapter is the consolidated recipe book for the codeome programmer.
Every idiom here is short, costed, and ready to paste into the editor.
The recipes assume you have read chapters 0–9: stacks and templates from
chapter 4, slot memory from chapter 5, the replicator anatomy from
chapters 7 and 9, and the energy economy from chapter 8.  Where a recipe
condenses material developed earlier, it points back rather than repeating
the derivation.

A note on notation.  Stack diagrams use the manual's convention
`( before -- after )` with the **top of the stack on the right**, and
bracket-stack snapshots like `[a, b, c]` likewise place the top on the
right (so `[a, b, c]` means `c` is on top).  Costs are taken from
`Lenies.Codeome.Costs`.  Template lengths are written in square brackets
after the jump opcode, e.g. `jnz_t[4]`.

The recipes are grouped by theme: constants, control flow, loops,
slots, stack manipulation, self-inspection, world-yielding utilities,
and anchor hygiene.  Mix freely — a random branch inside a counter loop
inside a replicator skeleton is a perfectly natural composition.

---

## 1. Constants and arithmetic

### 1.1 — Doubling chain (build a specific power of two)

**Stack effect:** `( -- 2^k )`

**When to use:** You need a specific power of 2 on the stack.  There is
no `:push N` opcode for arbitrary N — `:pushN` produces a *random*
integer in 0..255 — so deterministic constants must be constructed.

**Code (build 32 = 2^5):**

```elixir
[:push1,             # -> [1]
 :dup, :add,         # -> [2]
 :dup, :add,         # -> [4]
 :dup, :add,         # -> [8]
 :dup, :add,         # -> [16]
 :dup, :add]         # -> [32]
```

**Stack trace:**

```
before:        [ ]
push1     ->    [1]
dup       ->    [1, 1]
add       ->    [2]            ; 1 + 1
dup       ->    [2, 2]
add       ->    [4]            ; 2 + 2
dup       ->    [4, 4]
add       ->    [8]            ; 4 + 4
dup       ->    [8, 8]
add       ->    [16]           ; 8 + 8
dup       ->    [16, 16]
add       ->    [32]           ; 16 + 16
```

**Cost:** `0.1 + 0.3k` energy for 2^k (initial `:push1` plus k
repetitions of `:dup + :add`).

| k  | 2^k | cost |
|----|-----|------|
| 1  | 2   | 0.40 |
| 3  | 8   | 1.00 |
| 5  | 32  | 1.60 |
| 7  | 128 | 2.20 |
| 8  | 256 | 2.50 |

**Discussion:** For non-power-of-2 constants, chain additions after the
doubling.  To build 5: `:push1, :dup, :add` (→ 2), then `:push1, :add`
(→ 3), `:push1, :add` (→ 4), `:push1, :add` (→ 5), at total cost 1.30.
The single most common mistake is omitting the leading `:push1` and
opening with `:dup, :add`, which merely doubles whatever was already on
top of the stack — a lurking bug that only surfaces when that
pre-existing value changes.

### 1.2 — Coin flip (uniform 0 or 1 on the stack)

**Stack effect:** `( -- 0 or 1 )`

**When to use:** You want a fair binary random value, typically as the
predicate of a 50/50 branch.

**Code:**

```elixir
[:pushN,                # -> [r]        r uniform in 0..255
 :push1, :push1, :add,  # -> [r, 2]     build the divisor
 :mod]                  # -> [r mod 2]  0 if r even, 1 if r odd
```

**Trace** (assuming `:pushN` happens to draw 137):

```
pushN      ->   [137]
push1      ->   [137, 1]
push1      ->   [137, 1, 1]
add        ->   [137, 2]
mod        ->   [1]              ; 137 mod 2  (mod: second mod top)
```

**Cost:** `pushN (0.10) + push1 (0.10) + push1 (0.10) + add (0.20) +
mod (0.20) = 0.70` energy.

**Discussion:** `:mod` pops `a` (top), then pops `b`, and pushes
`b mod a`.  With 2 on top, the computation is `pushN mod 2`.  The coin
is fair because `:pushN` draws uniformly from 0..255, an even-length
range — exactly 128 of those 256 values are even.  The most common
mistake is reversing operand order so the computation becomes
`2 mod r`, which is 2 for almost all r and breaks the coin entirely.
See section 2.1 below for how to wire this into an actual branch.

---

## 2. Control flow

### 2.1 — Random branch 50/50

**When to use:** You want behaviour to differ randomly between two paths
with equal probability.

**Code:**

```elixir
:pushN,                                  # -> [r]   uniform random in 0..255
:push1, :push1, :add,                    # -> [r, 2]
:mod,                                    # -> [r mod 2]  in {0, 1}

# Jump to PATH_A if coin == 0; fall through to PATH_B otherwise.
:jz_t, :nop_0, :nop_0, :nop_1, :nop_1,   # template [0,0,1,1] -> searches [1,1,0,0]

# --- PATH_B code ---
# ...

# --- PATH_A anchor ---
:nop_1, :nop_1, :nop_0, :nop_0,
# --- PATH_A code ---
```

**Cost:** `pushN (0.10) + push1 (0.10) + push1 (0.10) + add (0.20) +
mod (0.20) + jz_t[4] (0.40) = 1.10` energy for the coin-flip machinery
itself, not counting the body of either path.

**Discussion:** Reusing the coin-flip computation from recipe 1.2, the
key addition is the `:jz_t` instruction with a 4-bit template
complementing the anchor before PATH_A.  The most common mistake here is
not the arithmetic but anchor placement — see recipe 8.1 on separators.

### 2.2 — If-else with `jz_t` (binary branch on a condition)

**When to use:** Choose between two paths based on a stack value —
anything that produces 0 vs nonzero.  The cleanest predicates come from
`:sense_front` (0 = empty cell), arithmetic differences (`:sub` of two
values), or remaining counters.

**Structure:**

```
<condition>                  ; pushes a value
jz_t [TEMPLATE_A]            ; if value == 0, jump to anchor A
<TRUE block>                 ; runs when value != 0
jmp_t [TEMPLATE_B]           ; skip the FALSE block
<anchor A>                   ; landing for the FALSE branch
<FALSE block>                ; runs when value == 0
<anchor B>                   ; join point after both branches
```

**Code (if the front cell is occupied, attack; else defend):**

The VM has no comparison opcode.  The cleanest binary predicates are the
ones that produce 0 vs nonzero **naturally** — `:sense_front` returns 0
for an empty cell and a positive integer for an occupied one.

```elixir
[# == CONDITION: sense the front cell ==============================
 :sense_front,                              # -> [k]  0 if empty, >0 if occupied

 # == BRANCH: jz_t to anchor A (the FALSE / "empty" block) ==========
 :jz_t, :nop_1, :nop_1, :nop_0, :nop_0,     # template [1,1,0,0] -> searches [0,0,1,1]

 # == TRUE block: front is occupied -> attack =======================
 :attack,

 # == SKIP THE FALSE BLOCK ==========================================
 :jmp_t, :nop_0, :nop_1, :nop_1, :nop_0,    # template [0,1,1,0] -> searches [1,0,0,1]

 # == SEPARATOR (prevent extractor swallowing anchor A) =============
 :push0,

 # == anchor A [0,0,1,1] (FALSE landing) ============================
 :nop_0, :nop_0, :nop_1, :nop_1,

 # == FALSE block: front is empty -> defend =========================
 :defend,

 # == anchor B [1,0,0,1] (join point) ===============================
 :nop_1, :nop_0, :nop_0, :nop_1]
```

**Stack trace (TRUE path, front cell value 15):**

```
sense_front              ->   [15]
jz_t [1,1,0,0]            tests 15 != 0 -> no jump; pops 15
                       ->   [ ]
attack                    yields {:attack, pos, dir}
jmp_t [0,1,1,0]           searches for [1,0,0,1] -> finds anchor B
                          ip lands just after anchor B
```

**Stack trace (FALSE path, k = 0):**

```
sense_front              ->   [0]
jz_t [1,1,0,0]            tests 0 == 0 -> jump fires; pops 0
                       ->   [ ]
                          searches for [0,0,1,1] -> finds anchor A
                          ip lands just after anchor A
defend                    yields :defend
```

**Cost (TRUE path):** `sense_front (0.50) + jz_t[4] (0.40) + attack
(5.00) + jmp_t[4] (0.40) = 6.30` energy plus the nop tail through
anchor B (4 × 0.10 = 0.40) = **6.70** total.

**Cost (FALSE path):** `sense_front (0.50) + jz_t[4] (0.40) + defend
(2.00) + 4 nops for anchor B (0.40) = 3.30` energy.

**Discussion — anchor choice:** Two distinct anchor patterns are
essential so that the FALSE-skip jump and the join jump cannot collide.
Any two patterns that are NOT complements of each other work.  If you
reuse the same bit pattern for both anchors, the join jump may land at
the wrong place.  The `:push0` separator before anchor A is the standard
precaution (see section 8.1).

### 2.3 — Wait until condition (spin until the world changes)

**When to use:** Sit in a tight loop until the world changes — e.g., a
cell becomes empty, or a sensor crosses a threshold.

**Code (spin until the front cell is empty):**

```elixir
[# == WAIT_HEAD anchor [0,0,0,0] ==================================
 :nop_0, :nop_0, :nop_0, :nop_0,

 # == sense; if non-zero, loop back ===============================
 :sense_front,
 :jnz_t, :nop_1, :nop_1, :nop_1, :nop_1,   # template -> anchor [0,0,0,0]
 :push0]                                    # separator: stops the greedy
                                            # template read from wrapping
                                            # into the head anchor
```

**Trace** (cell occupied, k = 5):

```
sense_front      ->   [5]
jnz_t [1,1,1,1]   tests 5 != 0 -> jump fires; pops 5
                  searches for anchor [0,0,0,0] -> lands after the nops
```

**Cost per spin iteration:** `4 × nop_0 (0.40) + sense_front (0.50) +
jnz_t[4] (0.40) = 1.30` energy.

The trailing `:push0` is a separator (section 8.1): because the
`:jnz_t` template is the last thing in the codeome, without it the
greedy template read would wrap past the end and swallow the four
`:nop_0` of the head anchor, producing an 8-bit template that matches
nothing.  The separator stops the read at four bits.  It executes only
once, on loop exit, so it is not part of the per-spin cost below.

**Beware:** this is a busy loop.  On an empty grid with a stable
obstruction in front, this drains energy at roughly 1.3 per iteration
with no productive work.  Use only when you have reason to expect the
wait to be short.

---

## 3. Loops

### 3.1 — Fixed-count loop (do something N times)

**When to use:** You want a body to execute exactly N times, where N is
a compile-time constant or a value already on the stack.

**Code (execute body exactly 4 times):**

```elixir
[# == SETUP: counter = 4 in slot 1 =================================
 :push1, :dup, :add, :dup, :add,    # -> [4]   (1 -> 2 -> 4 via doubling)
 :push1, :store,                    # slot[1] = 4  (pops slot_idx=1 then value=4)

 # == LOOP_HEAD anchor [0,0,0,0] ===================================
 :nop_0, :nop_0, :nop_0, :nop_0,

 # == BODY (replace with your code) ================================
 :sense_front, :drop,               # placeholder body

 # == DECREMENT AND TEST ===========================================
 :push1, :load,                     # -> [counter]
 :push1, :sub,                      # -> [counter - 1]   (sub: second - top)
 :push1, :store,                    # slot[1] = counter - 1
 :push1, :load,                     # -> [counter - 1]   (reload for jnz_t)
 :jnz_t, :nop_1, :nop_1, :nop_1, :nop_1]   # template -> anchor [0,0,0,0]
```

**Setup trace (build the counter):**

```
push1      ->   [1]
dup        ->   [1, 1]
add        ->   [2]
dup        ->   [2, 2]
add        ->   [4]
push1      ->   [4, 1]
store      ->   [ ]                  ; slot[1] = 4
```

Note: `:push1, :dup, :add` only doubles to 2.  To get 4 you must double
**again** with another `:dup, :add`.  A common slip-up is reading the
doubling pattern as "push1 then dup+add gives me my power of 2",
forgetting the `k` repetitions in recipe 1.1's formula.

**First-iteration trace (body and decrement):**

```
sense_front      ->   [k]                    ; some sensed value k
drop             ->   [ ]
push1            ->   [1]
load             ->   [4]                    ; slot[1] before decrement
push1            ->   [4, 1]
sub              ->   [3]                    ; 4 - 1   (sub: second - top)
push1            ->   [3, 1]
store            ->   [ ]                    ; slot[1] = 3
push1            ->   [1]
load             ->   [3]
jnz_t [1,1,1,1]  ->   [ ]   pops 3; non-zero, jumps to LOOP_HEAD anchor
```

After three more iterations slot[1] is 0; `:jnz_t` sees 0 (popped), does
**not** jump, and execution falls through past the template.

**Cost per iteration (overhead only, excluding the body):**
`push1 (0.10) + load (0.50) + push1 (0.10) + sub (0.20) + push1 (0.10) +
store (0.50) + push1 (0.10) + load (0.50) + jnz_t[4] (0.40) = 2.50`
energy.

**Slot index convention:** any slot index 0..3 works.  This manual uses
**slot 0 for replication state** (size, offsets, child-size) and **slot
1 for loop counters** by convention.  There are only four slots — keep
their roles distinct or you will overwrite a counter when storing an
unrelated value.

**Discussion:** The reload after `:store` is needed because `:store`
consumes both operands; the decremented value is no longer on the stack
when `:jnz_t` runs.  A common shortcut is to `:dup` the decremented
value just before `:store`, saving a `:push1, :load` pair (0.60 energy)
per iteration — but the explicit load-twice pattern shown here is
easier to read and debug.  This pattern is the inner loop of the
sustainable replicator from chapter 7.

### 3.2 — Env-driven loop (count proportional to a sensor)

**When to use:** You want the loop bound to depend on the world, not a
compile-time constant.  The classic case: "spend a fraction of my
energy foraging, then go replicate".

**Code (loop `E mod 8` times — counter in 0..7 derived from energy):**

The VM has `:mod` but no `:div`, so the easiest env-derived bound is
"sensor modulo a power of 2".

```elixir
[# == COMPUTE BOUND: E mod 8 =======================================
 :sense_energy,                     # -> [E]
 :push1, :dup, :add,                # -> [E, 2]
 :dup, :add,                        # -> [E, 4]
 :dup, :add,                        # -> [E, 8]
 :mod,                              # -> [E mod 8]   (mod: second mod top)
 :push1, :store,                    # slot[1] = E mod 8

 # == LOOP_HEAD anchor [0,0,0,0] ===================================
 :nop_0, :nop_0, :nop_0, :nop_0,

 # == BODY =========================================================
 :move,

 # == DECREMENT AND TEST (identical to recipe 3.1) =================
 :push1, :load,
 :push1, :sub,
 :push1, :store,
 :push1, :load,
 :jnz_t, :nop_1, :nop_1, :nop_1, :nop_1]
```

**Cost (setup only):** `sense_energy (0.50) + push1 (0.10) + 3 ×
(dup+add) (0.90) + mod (0.20) + push1 (0.10) + store (0.50) = 2.30`
energy.

**Discussion:** Any `:sense_*` opcode works as the source.  Replace
`:sense_energy` with `:sense_age` for an age-modulated loop, or
`:sense_size` for "loop once per opcode in my codeome".

A note about scale: at 10 000 starting energy `E mod 8` is `0`, which
means the loop runs zero times on the first outer iteration.  If you
want a non-zero floor, add 1 before storing:

```elixir
[:sense_energy,
 :push1, :dup, :add, :dup, :add, :dup, :add,   # -> [E, 8]
 :mod,                                          # -> [E mod 8]
 :push1, :add,                                  # -> [E mod 8 + 1]  (1..8)
 :push1, :store]                                # slot[1] = 1..8
```

For an actual "spend a fraction of my energy" pattern, use the modulo
as a *seed* rather than a direct count and let the loop body's
per-iteration energy cost determine how far the Lenie actually gets
before starvation.  See chapter 8 for energy-economy considerations.

---

## 4. Memory (slots)

Slots are four per-creature integers indexed 0..3.  They persist across
opcode bursts and start at 0.  `:store` costs 0.5; `:load` costs 0.5.
The critical detail (chapter 5 § "Order matters: slot index is on
top"): `:store` pops the **slot index first** (top), then the value
(second).

### 4.1 — Save a value into a slot

**Stack effect:** `( v -- )`, side effect: `slot[s] = v`.

```elixir
[:push1, :store]      # slot[1] = v
```

Trace, assuming the stack starts as `[42]`:

```
before:        [42]
push1     ->    [42, 1]
store     ->    [ ]                ; slot[1] = 42 (top=slot_idx, second=value)
```

**Cost:** `push1 (0.10) + store (0.50) = 0.60` energy.

If you write `:store, :push1` thinking you will specify the slot
afterward, you have already corrupted state — `:store` already ran with
whatever was on top.  This is the most-forgotten detail in the VM.

### 4.2 — Load a slot value

**Stack effect:** `( -- v )`.

```elixir
[:push1, :load]       # -> [slot[1]]
```

**Cost:** `push1 (0.10) + load (0.50) = 0.60` energy.

### 4.3 — Increment a slot by 1

**Stack effect:** `( -- )`, side effect: `slot[s] += 1`.

```elixir
[:push1, :load,       # -> [counter]
 :push1, :add,        # -> [counter + 1]
 :push1, :store]      # slot[1] = counter + 1
```

Trace, assuming `slot[1] = 7`:

```
push1      ->   [1]
load       ->   [7]
push1      ->   [7, 1]
add        ->   [8]
push1      ->   [8, 1]
store      ->   [ ]              ; slot[1] = 8
```

**Cost:** `push1 (0.10) + load (0.50) + push1 (0.10) + add (0.20) +
push1 (0.10) + store (0.50) = 1.50` energy per increment.

### 4.4 — Bounded counter (wrap on overflow)

**When to use:** You want a counter that cycles 0 → 1 → ... → max-1 →
0 → ... rather than growing unbounded.

**Code (counter mod 8 in slot 1):**

```elixir
[:push1, :load,       # -> [counter]
 :push1, :add,        # -> [counter + 1]
 :push1, :dup, :add,  # -> [counter+1, 2]
 :dup, :add,          # -> [counter+1, 4]
 :dup, :add,          # -> [counter+1, 8]
 :mod,                # -> [(counter+1) mod 8]
 :push1, :store]      # slot[1] = result
```

**Cost:** `push1+load (0.60) + push1+add (0.30) + push1+3×(dup+add)
(1.00) + mod (0.20) + push1+store (0.60) = 2.70` energy per cycle.

**Discussion:** `:mod` is `second mod top`, so the modulus (8) must be
on top of the stack when `:mod` runs.  Build the counter first, then
the modulus on top — if you build the modulus first and load the
counter after, you get `8 mod (counter+1)`, which is 0 for counter ≥ 8
and otherwise small — not what you want.

### 4.5 — Accumulator (running sum)

**When to use:** Aggregate a value over time — total energy harvested,
sum of sensed values, etc.

**Code (add new value `v` on top to slot 1):**

```elixir
[# pre: stack = [v]
 :push1, :load,       # -> [v, sum]
 :add,                # -> [v + sum]
 :push1, :store]      # slot[1] = v + sum
```

Trace, assuming `slot[1] = 30` and stack top is `5`:

```
before:       [5]
push1     ->   [5, 1]
load      ->   [5, 30]
add       ->   [35]              ; 5 + 30
push1     ->   [35, 1]
store     ->   [ ]               ; slot[1] = 35
```

**Cost:** `push1+load (0.60) + add (0.20) + push1+store (0.60) = 1.40`
energy per accumulation.

### 4.6 — Swap two slot values

**When to use:** Rare, but occasionally useful — e.g., swap "current
target" and "next target".

**Code (swap slot 0 and slot 1):**

```elixir
[:push0, :load,       # -> [A]            A = slot[0]
 :push1, :load,       # -> [A, B]         B = slot[1]
 :swap,               # -> [B, A]
 :push1, :store,      # slot[1] = A;  -> [B]
 :push0, :store]      # slot[0] = B
```

Trace, assuming `slot[0] = 10, slot[1] = 99`:

```
push0      ->   [0]
load       ->   [10]              ; slot[0]
push1      ->   [10, 1]
load       ->   [10, 99]          ; slot[1]
swap       ->   [99, 10]
push1      ->   [99, 10, 1]
store      ->   [99]              ; slot[1] = 10
push0      ->   [99, 0]
store      ->   [ ]               ; slot[0] = 99
```

After: `slot[0] = 99, slot[1] = 10`.

**Cost:** `push0+load (0.60) + push1+load (0.60) + swap (0.10) +
push1+store (0.60) + push0+store (0.60) = 2.50` energy.

**Discussion:** Operand order is the trap.  After `:swap` the stack is
`[B, A]` with A on top; pushing slot index `1` and storing writes A
into slot 1.  Drawing the stack beside each opcode is the only reliable
way to get this right on the first try.

---

## 5. Stack manipulation

The VM gives you only `:dup`, `:drop`, and `:swap`.  Anything more
complex must be composed — and beyond depth 2 it gets painful.  Prefer
slots (section 4) when the dance starts looking acrobatic.

### 5.1 — Duplicate top (keep a copy before consuming)

**Stack effect:** `( a -- a a )`

```elixir
[:dup]                  # -> [a, a]      cost 0.10
```

Use it before any opcode that consumes the value you want to read
again.  A classic pairing is `:dup` before `:jz_t` or `:jnz_t`: the
conditional jump pops its test value regardless of branch, so without
the `:dup` the value is gone afterwards.

### 5.2 — Drop-second (remove the value below the top)

**Stack effect:** `( b a -- a )`

```elixir
[:swap,      # -> [a, b]      top and second swap
 :drop]      # -> [a]         drop the new top (was b)
```

**Cost:** `swap (0.10) + drop (0.10) = 0.20` energy.

Use it to discard a value you no longer need that is sitting *below*
the value you do need — for example, the `1` or `0` result of
`:make_plasmid` when the value above it is still useful.

### 5.3 — 2-deep peek (look at the second-from-top value)

**Stack effect (the useful framing):** preserve the second value into a
slot, then keep going.

A pure stack-only solution is awkward because the VM lacks `:over`.  The
honest version is to swap the value into reach, duplicate it, and
either consume it immediately or use it briefly before restoring order:

```elixir
# pre:    [b, a]
[:swap,      # -> [a, b]
 :dup,       # -> [a, b, b]
 # ... opcode that consumes the top b (e.g., :jz_t or arithmetic) ...
 :swap]      # -> [b, a]    restores original order, assuming consumer
             #             left one value on top
```

**Cost:** `swap (0.10) + dup (0.10) + swap (0.10) = 0.30` energy for
the peek-and-restore frame.

If you need 2-deep access often, **storing the value in a slot
(recipe 4.1) is cheaper and clearer.**

### 5.4 — Anything beyond depth 2: use slots

A pure-stack reverse of three values `( c b a -- a b c )` requires
parking values in slots.  Two slots are not enough — you need three
(slots 0, 1, and 2):

```elixir
# pre:    [c, b, a]
[:push0, :store,     # slot[0] = a
 :push1, :store,     # slot[1] = b
 :push1, :dup, :add, # -> [c, 2]
 :store,             # slot[2] = c

 # now load in the order we want:
 :push0, :load,      # -> [a]
 :push1, :load,      # -> [a, b]
 :push1, :dup, :add, # -> [a, b, 2]
 :load]              # -> [a, b, c]
```

**Cost:** three stores + three loads + arithmetic to build slot index 2
twice ≈ `3 × 0.50 + 3 × 0.50 + 2 × (0.10 + 0.10 + 0.20) = 3.80` energy.

The lesson is twofold: prefer slots for any manipulation beyond depth
2, and question whether you really need a three-element reverse in the
first place.

---

## 6. Self-inspection and replication

### 6.1 — Defensive front sense (yield-and-drop)

**When to use:** You need to yield a World tick (allowing the World
GenServer to step) but do not need the cell's actual contents.

**Code:**

```elixir
:sense_front,   # yields to World; pushes a small integer for the front cell
:drop           # discard the result - keep the stack clean
```

**Cost:** `sense_front (0.50) + drop (0.10) = 0.60` energy.

**Discussion:** `:sense_front` is the cheapest way to hand control back
to the World scheduler, which matters when your codeome must cooperate
with other cells running concurrently.  If you immediately follow
`:sense_front` with `:eat` or `:move` unconditionally, the sensed value
is irrelevant — dropping it prevents it from corrupting later
arithmetic or conditional tests.  The chapter-3 Crawler uses this idiom
in its main loop.  The common mistake is forgetting the `:drop`,
leading to a stack that slowly fills with cell-type integers; a
subsequent `:mod` or `:sub` then operates on the wrong values entirely.

### 6.2 — Read your own opcode at a position

**Stack effect:** `( addr -- op_int )`.  Cost: 0.30.

`:read_self` pops the address from the top of the stack and pushes the
**integer encoding** of the opcode found at `codeome[addr mod size]`.
It does NOT push the opcode atom name — it pushes a small integer
(0..37).  The canonical encoding map:

```
0  :nop_0          14 :jnz_t          28 :get_ip
1  :nop_1          15 :call_t         29 :get_size
2  :push0          16 :ret            30 :read_self
3  :push1          17 :sense_front    31 :allocate
4  :pushN          18 :sense_self     32 :write_child
5  :dup            19 :sense_energy   33 :divide
6  :drop           20 :sense_age      34 :store
7  :swap           21 :sense_size     35 :load
8  :add            22 :move           36 :make_plasmid
9  :sub            23 :turn_left      37 :conjugate
10 :mul            24 :turn_right
11 :mod            25 :eat
12 :jmp_t          26 :attack
13 :jz_t           27 :defend
```

If the address falls outside `0..size-1` it is wrapped (`addr mod
size`), so out-of-range arithmetic is safe.

**Code (read opcode at position 5):**

```elixir
[:push1, :dup, :add, :dup, :add,     # -> [4]   (1 -> 2 -> 4 via doubling)
 :push1, :add,                        # -> [5]   (+1)
 :read_self]                          # -> [op_int_at_pos_5]
```

### 6.3 — Copy-one-cell snippet (read self, write child)

```elixir
[:push1, :load,        # -> [i]            current address (also child dest)
 :read_self,           # -> [op_int]       reads codeome[i]
 :push1, :load,        # -> [op_int, i]    child_addr
 :swap,                # -> [i, op_int]    swap to put child_addr below op_int
 :write_child]         # writes op_int -> child[i]; pops both
```

**Why the swap?** `:write_child` pops `op_int` (top) THEN `child_addr`
(second).  After `:read_self` the stack is `[op_int]` and after the
second `:push1, :load` it is `[op_int, i]` — but `i` is now on top and
`:write_child` would read it as the opcode.  The swap restores the
correct order: `[i, op_int]`, with `op_int` on top.

**Cost of one copy step:** `push1+load (0.60) + read_self (0.30) +
push1+load (0.60) + swap (0.10) + write_child (1.00) = 2.60` energy
per opcode copied.

### 6.4 — Skeleton copy loop (full replication cycle)

**When to use:** You are writing a new replicator from scratch and need
a working starting point for the self-copy cycle.  This combines
recipe 3.1 (counter loop) with recipes 6.2 and 6.3 (self-inspection and
child write).

**Code:**

```elixir
[
  # == OUTER LOOP HEAD anchor [1,1,1,1] ======================================
  :nop_1, :nop_1, :nop_1, :nop_1,

  # == GET AND STORE OWN SIZE ================================================
  :get_size,                           # -> [size]           cost 0.30
  :push0, :store,                      # slot[0] = size     cost 0.60

  # == ALLOCATE CHILD ========================================================
  :push0, :load,                       # -> [size]           cost 0.60
  :allocate,                           # -> [ok/no_target]   cost 5.0 + 0.05xsize
  :drop,                               # discard reply      cost 0.10

  # == INIT COPY COUNTER =====================================================
  :push0,                              # -> [0]              cost 0.10
  :push1, :store,                      # slot[1] = 0        cost 0.60

  # == COPY LOOP HEAD anchor [1,0,0,1] =======================================
  :nop_1, :nop_0, :nop_0, :nop_1,

  # == COPY BODY: read self[i], write child[i], i++ ==========================
  :push1, :load,                       # -> [i]              cost 0.60
  :read_self,                          # -> [opcode_int]     cost 0.30
  :push1, :load,                       # -> [opcode_int, i]  cost 0.60
  :swap,                               # -> [i, opcode_int]  cost 0.10
  :write_child,                        # writes opcode_int at child[i]
                                       #                    cost 1.00
  :push1, :load,                       # -> [i]              cost 0.60
  :push1, :add,                        # -> [i+1]            cost 0.30
  :push1, :store,                      # slot[1] = i+1      cost 0.60

  # == CONDITION: remaining = size - counter =================================
  :push0, :load,                       # -> [size]           cost 0.60
  :push1, :load,                       # -> [size, i+1]      cost 0.60
  :sub,                                # -> [size - (i+1)]   cost 0.20

  # == LOOP BACK IF NOT DONE =================================================
  :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,   # complement of [1,0,0,1] is [0,1,1,0]
                                              # cost 0.40

  # == DIVIDE (spawn child) ==================================================
  :divide,                             # cost 10.0

  # ===========================================================================
  # YOUR FORAGE / TURN / RESTART CODE GOES HERE
  # After foraging, jump back to the outer LOOP HEAD anchor [1,1,1,1]:
  #   :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0   (complement of [1,1,1,1])
  # ===========================================================================
]
```

**Cost (replication cycle, skeleton only, excluding forage):**

| Phase              | Formula               | Example (N=100) |
|--------------------|-----------------------|-----------------|
| init + allocate    | `0.60 + 5.0 + 0.05N`  | 10.60           |
| copy body × N      | `N × 4.10`            | 410.00          |
| condition + jnz_t  | `N × 1.80`            | 180.00          |
| divide             | `10.0`                | 10.00           |
| **total**          | `≈ 5.95N + 15.60`     | **610.60**      |

Per-iteration copy-body breakdown: `push1+load (0.60) + read_self
(0.30) + push1+load (0.60) + swap (0.10) + write_child (1.00) +
push1+load (0.60) + push1+add (0.30) + push1+store (0.60) = 4.10`
energy.  Condition overhead: `push0+load (0.60) + push1+load (0.60) +
sub (0.20) + jnz_t[4] (0.40) = 1.80` energy.  Combined per body
iteration: 5.90 energy; the `5.95N` figure also amortises allocate's
per-byte cost over each iteration.

**Discussion:** This skeleton is intentionally minimal — it will not
survive long without a forage block, because each replication cycle at
N=100 costs roughly 590 energy while a bare `:eat` only recovers 2.0.
To make it sustainable, add a turn-and-eat loop after `:divide` and
before the `:jmp_t` that restarts the outer loop; see chapter 7 for the
full pattern.  The `:drop` after `:allocate` is non-negotiable:
without it the ok/no_target reply (1 or 0) stays on the stack and
poisons the arithmetic in the copy loop.  The separator between the
outer anchor and the allocate block is implicit here because
`:get_size` is a non-nop opcode; add an explicit separator (section
8.1) if you place a second anchor-run immediately after any anchor.

---

## 7. Movement utilities

### 7.1 — Random walk

```elixir
[:pushN,                                    # -> [r]      0..255
 :push1, :dup, :add, :dup, :add,            # -> [r, 4]
 :mod,                                       # -> [r mod 4]  0..3 -> direction index
 :push1, :store,                            # slot[1] = r mod 4

 # == turn_left counter times ===================================
 :nop_0, :nop_0, :nop_0, :nop_0,            # loop anchor
 :push1, :load,
 :jz_t, :nop_1, :nop_1, :nop_0, :nop_0,    # if 0, skip turn_left
 :turn_left,
 :push1, :load, :push1, :sub, :push1, :store,
 :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,    # back to anchor
 :push0,
 :nop_0, :nop_0, :nop_1, :nop_1,            # skip-target anchor
 :move]
```

**Directed walk:** simply `:move` repeatedly inside a loop with no
turn.  The Crawler from chapter 3 is the canonical example of a directed walk;
chapters 4–5 add foraging and turning.  The random walk above costs
~5–10 energy per step (depending on `r mod 4`); a directed walk costs
only the 2.0 of `:move`.  Random walks explore more area but starve
faster.

---

## 8. Anchor and template hygiene

### 8.1 — Separator placement (between adjacent anchor runs)

**When to use:** Two anchor-runs are adjacent in the codeome, or an
anchor-run immediately follows the nop-template of a jump instruction.

**Bad code:**

```elixir
# jmp_t uses a 4-bit template [0,0,0,0]; the very next instruction begins
# the anchor for the next jump target [1,1,1,1].
..., :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
:nop_1, :nop_1, :nop_1, :nop_1, <next code>
```

**Good code:**

```elixir
..., :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
:push0,                                        # <- SEPARATOR (any non-nop opcode)
:nop_1, :nop_1, :nop_1, :nop_1, <next code>
```

**Cost:** `0.10` energy for the separator (`:push0` is cheapest); add
`:drop (0.10)` if the extra 0 on the stack would be disruptive.

**Discussion:** The template extractor reads consecutive `:nop_0` /
`:nop_1` atoms greedily up to `template_max_len = 8`.  Without the
separator, the jump's template is 8 bits `[0,0,0,0,1,1,1,1]` instead of
the intended 4 bits `[0,0,0,0]`.  The search then looks for the
complement `[1,1,1,1,0,0,0,0]`, which almost certainly does not exist
in the codeome, so the jump falls through rather than branching — a
silent correctness bug.  Any non-nop opcode breaks the greedy read;
`:push0` is preferred because it costs only 0.10 and produces a 0 that
is harmless in dead-code positions.  If the extra stack value matters,
append `:drop`.  Ancestor (chapter 9) contains two
separators — at positions 49 and 99 — for exactly this reason.

---

## General guidelines

- **Slots are precious.**  With only four, dedicate them deliberately.
  This manual uses slot 0 for replication state and slot 1 for loop
  counters, leaving slot 2 and slot 3 for application-specific data.
- **Templates cost per bit.**  4-bit templates (cost 0.40 per jump) are
  the sweet spot; 8-bit templates (cost 0.60) are rarely worth it
  unless you need many distinct anchors in a long codeome.
- **`:push0` is the cheapest no-op-with-side-effect.**  Use it as a
  separator and as padding to meet the validator's 10-non-nop minimum.
- **When in doubt, store and load.**  Pure-stack juggling beyond depth
  2 is fragile; slots are cheap (0.5 each) and dramatically more
  readable.
- **Draw the stack beside every opcode.**  The trace is always more
  honest than your intuition about what the stack looks like —
  especially after a `:jz_t` or a `:store` where operand order is easy
  to misread.

---

## Closing words

You now have the full toolkit.  You know the VM anatomy, the opcode
costs, the template-based control flow, the slot memory model, and the
energy economy.  You have built every canonical codeome in the pyramid
— the Crawler, Reflex, the Stepper, the Wanderer, and a sustainable replicator
— and you have dissected Ancestor at the byte level.  The
recipes in this chapter are the mortar that holds those structures
together.  Mix them freely.  A random branch (section 2.1) inside a
counter loop (section 3.1) inside a replication skeleton (section 6.4)
is a perfectly natural composition.

When something does not work, Ancestor
(`docs/manual/09-ancestor.md`) is your best reference for a
known-good example of every idiom used together under real energy
pressure.  For the underlying mechanics see chapter 4 (templates),
chapter 5 (memory), chapter 7 (replication), and chapter 8 (energy
economy).

Experiment.  Break things.  Measure the cost.  Then fix it.

Happy hacking.
