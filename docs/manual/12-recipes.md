# Chapter 12 — Recipes

This chapter is for the programmer who has read chapters 0–4 (or skimmed the
opcode reference in chapter 2), understands stacks and loops in the abstract,
and now wants concrete copy-paste idioms to drop into the codeome editor.
Each recipe is short, costed, and self-contained.

If chapter 10 (Cookbook) is the reference distilled from the canonical
codeomes, this chapter is the beginner's complement: it walks more slowly,
shows fuller traces, and explains the *why* behind each opcode placement.
For deeper, replicator-grade idioms see chapter 10; for the underlying
mechanics see chapter 4 (templates), chapter 5 (memory), and the opcode
reference in chapter 2.

Stack effects use the manual's convention `( before -- after )` with the
**top of the stack on the right**. All costs are taken from
`Lenies.Codeome.Costs`.

---

## Recipe 1 — Build a specific constant (doubling chain)

**Stack effect:** `( -- 2^k )`

**When to use:** You need a specific power of 2 on the stack and there is no
suitable value already there. There is no `:push N` for arbitrary N — `:pushN`
gives a *random* integer in 0..255 — so deterministic constants must be
constructed.

**Code (build 32 = 2^5):**

```elixir
[:push1,            # → [1]
 :dup, :add,         # → [2]
 :dup, :add,         # → [4]
 :dup, :add,         # → [8]
 :dup, :add,         # → [16]
 :dup, :add]         # → [32]
```

**Stack trace:**

```
before:        [ ]
push1     →    [1]
dup       →    [1, 1]
add       →    [2]            ; 1 + 1
dup       →    [2, 2]
add       →    [4]            ; 2 + 2
dup       →    [4, 4]
add       →    [8]            ; 4 + 4
dup       →    [8, 8]
add       →    [16]           ; 8 + 8
dup       →    [16, 16]
add       →    [32]           ; 16 + 16
```

**Cost:** `0.1 + 0.3k` energy for 2^k. Building 32 (k=5) costs
`0.1 + 0.3 × 5 = 1.60` energy: one `:push1` (0.1) plus five rounds of
`:dup` (0.1) + `:add` (0.2).

**Discussion:** This is Pattern 1 from chapter 10, fully traced. For
non-power-of-2 constants, chain additions afterwards — to build 5 do
`:push1, :dup, :add` (→ 2), then `:push1, :add` (→ 3), `:push1, :add`
(→ 4), `:push1, :add` (→ 5), at total cost 0.80. The single most common
mistake is omitting the leading `:push1` and opening with `:dup, :add`,
which silently doubles whatever was already on top of the stack. See
[chapter 10 § Pattern 1](10-cookbook.md) for cost tables at higher k.

---

## Recipe 2 — Fixed-count loop (do something N times)

**When to use:** You want a body to execute a known number of times.

**Code (execute body exactly 4 times):**

```elixir
[# ── SETUP: counter = 4 in slot 1 ─────────────────────────────────
 :push1, :dup, :add, :dup, :add,    # → [4]    (1 → 2 → 4 via doubling)
 :push1, :store,                    # slot[1] = 4   (pops slot_idx=1 then value=4)

 # ── LOOP_HEAD anchor [0,0,0,0] ───────────────────────────────────
 :nop_0, :nop_0, :nop_0, :nop_0,

 # ── BODY (replace with your code) ────────────────────────────────
 :sense_front, :drop,               # placeholder body

 # ── DECREMENT AND TEST ───────────────────────────────────────────
 :push1, :load,                     # → [counter]
 :push1, :sub,                      # → [counter - 1]   (sub: second − top)
 :push1, :store,                    # slot[1] = counter - 1
 :push1, :load,                     # → [counter - 1]   (reload for jnz_t)
 :jnz_t, :nop_1, :nop_1, :nop_1, :nop_1]   # template → searches anchor [0,0,0,0]
```

**Setup trace (build the counter):**

```
push1      →   [1]
dup        →   [1, 1]
add        →   [2]
dup        →   [2, 2]
add        →   [4]
push1      →   [4, 1]
store      →   [ ]                  ; slot[1] = 4
```

Note: `:push1, :dup, :add` only doubles to 2. To get 4 you must double
**again** with another `:dup, :add`. A common slip-up is reading the
doubling pattern as "push1 then dup+add gives me my power of 2", forgetting
the `k` repetitions in recipe 1's formula.

**First-iteration trace (body and decrement):**

```
sense_front      →   [k]                    ; some sensed value k
drop             →   [ ]
push1            →   [1]
load             →   [4]                    ; slot[1] before decrement
push1            →   [4, 1]
sub              →   [3]                    ; 4 − 1   (sub: second − top)
push1            →   [3, 1]
store            →   [ ]                    ; slot[1] = 3
push1            →   [1]
load             →   [3]
jnz_t [1,1,1,1]  →   [ ]   pops 3; non-zero, jumps to LOOP_HEAD anchor
```

After three more iterations slot[1] is 0; `:jnz_t` sees 0 (popped), does
**not** jump, and execution falls through past the template.

**Cost (per iteration, body excluded):**
`push1 (0.1) + load (0.5) + push1 (0.1) + sub (0.2) + push1 (0.1) + store
(0.5) + push1 (0.1) + load (0.5) + jnz_t[4] (0.4) = 2.50` energy.

**Slot index convention:** any slot index 0..3 works; this manual uses
**slot 0 for replication state** (offsets, child-size) and **slot 1 for
loop counters** by convention. There are only four slots — keep their roles
distinct or you will overwrite a counter when storing an unrelated value.

**Discussion:** This is Pattern 4 from chapter 10 with a worked initialiser.
The reload after `:store` is needed because `:store` consumes both operands;
the decremented value is no longer on the stack when `:jnz_t` runs. A common
shortcut is to `:dup` the decremented value just before `:store`, saving a
`:push1, :load` pair (0.6 energy) per iteration — but the explicit
load-twice pattern shown here is easier to read and debug.

---

## Recipe 3 — Env-driven loop (count proportional to current energy)

**When to use:** You want the loop bound to depend on the world, not a
compile-time constant. The classic case: "spend a fraction of my energy
foraging, then go replicate".

**Code (loop `E mod 8` times — a counter in 0..7 derived from energy):**

The VM has `:mod` but no `:div`, so the easiest energy-derived bound is
"E modulo some power of 2". This gives a counter in `0..N-1` rather than
"proportional to E", but it has the useful property that the loop length
shifts as energy fluctuates.

```elixir
[# ── COMPUTE BOUND: E mod 8 ───────────────────────────────────────
 :sense_energy,                     # → [E]
 :push1, :dup, :add,                # → [E, 2]
 :dup, :add,                        # → [E, 4]
 :dup, :add,                        # → [E, 8]
 :mod,                              # → [E mod 8]   (mod: second mod top)
 :push1, :store,                    # slot[1] = E mod 8

 # ── LOOP_HEAD anchor [0,0,0,0] ───────────────────────────────────
 :nop_0, :nop_0, :nop_0, :nop_0,

 # ── BODY ─────────────────────────────────────────────────────────
 :move,

 # ── DECREMENT AND TEST (same as recipe 2) ────────────────────────
 :push1, :load,
 :push1, :sub,
 :push1, :store,
 :push1, :load,
 :jnz_t, :nop_1, :nop_1, :nop_1, :nop_1]
```

**What this does:** `:sense_energy` reads the current energy (truncated to
an integer), and `:mod` reduces it modulo 8 to produce a counter in 0..7.
The loop body (here `:move`) then runs that many times before falling
through. Because `E mod 8` shifts as the Lenie eats and spends energy, the
loop length varies over the creature's lifetime in a chaotic-but-bounded
way.

**Cost (setup only):** `sense_energy (0.5) + push1 (0.1) + 3 × (dup+add)
(3 × 0.3 = 0.9) + mod (0.2) + push1 (0.1) + store (0.5) = 2.30` energy.

**Discussion:** The body and decrement are identical to recipe 2 — only the
setup changes. Any sense_* opcode works as the source: replace
`:sense_energy` with `:sense_age` for an age-modulated loop, or
`:sense_size` for "loop once per opcode in my codeome".

A note about scale: at 10 000 starting energy `E mod 8` is `0`, which means
the loop runs zero times on the first iteration of the outer cycle (the
`:jnz_t` immediately falls through). If you want a non-zero floor, add 1
before storing:

```elixir
[:sense_energy,
 :push1, :dup, :add, :dup, :add, :dup, :add,   # → [E, 8]
 :mod,                                          # → [E mod 8]
 :push1, :add,                                  # → [E mod 8 + 1]  (1..8)
 :push1, :store]                                # slot[1] = 1..8
```

For an actual "spend a fraction of my energy" pattern, the cleanest
practice is to use the modulo as a *seed*, not a direct count, and let the
loop body's per-iteration energy cost determine how far the Lenie
actually gets before starvation. See chapter 8 for energy-economy
considerations.

---

## Recipe 4 — If-else with `jz_t` (binary branch)

**When to use:** Choose between two paths based on a stack value — anything
that produces 0 vs nonzero. The cleanest predicates come from `:sense_front`
(0 = empty cell), arithmetic differences (`:sub` of two values, comparing
the result to 0), or counters whose remaining value is the test.

**Structure:**

```
<condition>                         ; pushes a value
jz_t [TEMPLATE_A]                   ; if value == 0, jump to anchor A
<TRUE block>                        ; runs when value != 0
jmp_t [TEMPLATE_B]                  ; skip the FALSE block
<anchor A>                          ; landing for the FALSE branch
<FALSE block>                       ; runs when value == 0
<anchor B>                          ; landing after both branches join
```

**Code (if the front cell is occupied, attack; else defend):**

The VM has no comparison opcode (`<`, `>`, `==`). The cleanest binary
predicates are the ones that produce 0 vs nonzero **naturally** — for
example `:sense_front` returns 0 for an empty cell and a positive integer
for an occupied one. We branch on that directly:

```elixir
[# ── CONDITION: sense the front cell ──────────────────────────────
 :sense_front,                     # → [k]  0 if empty, >0 if occupied

 # ── BRANCH: jz_t to anchor A (the FALSE / "empty" block) ─────────
 :jz_t, :nop_1, :nop_1, :nop_0, :nop_0,    # template [1,1,0,0] → searches [0,0,1,1]

 # ── TRUE block: front is occupied → attack ───────────────────────
 :attack,

 # ── SKIP THE FALSE BLOCK ─────────────────────────────────────────
 :jmp_t, :nop_0, :nop_1, :nop_1, :nop_0,   # template [0,1,1,0] → searches [1,0,0,1]

 # ── SEPARATOR (prevent extractor swallowing anchor A) ────────────
 :push0,

 # ── anchor A [0,0,1,1] (FALSE landing) ───────────────────────────
 :nop_0, :nop_0, :nop_1, :nop_1,

 # ── FALSE block: front is empty → defend ─────────────────────────
 :defend,

 # ── anchor B [1,0,0,1] (join point) ──────────────────────────────
 :nop_1, :nop_0, :nop_0, :nop_1]
```

**Stack trace (TRUE path, front cell has resource value 15):**

```
sense_front              →   [15]
jz_t [1,1,0,0]            tests 15 ≠ 0 → no jump
                          pops 15 anyway
                       →   [ ]
attack                    yields {:attack, pos, dir}
jmp_t [0,1,1,0]           searches for [1,0,0,1] → finds anchor B
                          ip lands just after anchor B
```

**Stack trace (FALSE path, front cell empty, k = 0):**

```
sense_front              →   [0]
jz_t [1,1,0,0]            tests 0 == 0 → jump fires
                          pops 0 anyway
                       →   [ ]
                          searches for [0,0,1,1] → finds anchor A
                          ip lands just after anchor A
defend                    yields :defend
(execution continues into anchor B's nops, then whatever follows runs)
```

**Cost (TRUE path):** `sense_front (0.5) + jz_t[4] (0.4) + attack (5.0) +
jmp_t[4] (0.4) = 6.30` energy plus the no-op tail through anchor B
(4 × 0.1 = 0.4) = **6.70** total.
**Cost (FALSE path):** `sense_front (0.5) + jz_t[4] (0.4) + defend (2.0)
+ 4 nops for anchor B (0.4) = **3.30** energy.

**Discussion — anchor and template choice:**

Two distinct anchor patterns are essential here so that the FALSE-skip jump
and the join jump cannot collide:

- Anchor A = `[0,0,1,1]` (template `[1,1,0,0]`) — destination of the conditional jump.
- Anchor B = `[1,0,0,1]` (template `[0,1,1,0]`) — destination of the skip jump.

Any two patterns that are NOT complements of each other work. If you reuse the
same bit pattern for both anchors, the join jump may land at the wrong place.
The `:push0` separator before anchor A is the standard precaution from
chapter 4 § 4 / chapter 10 Pattern 5: without it, the extractor for the
preceding `:jmp_t` could swallow part of anchor A's bits and silently
misroute the jump. See also recipe 4 in chapter 10 cookbook for a more
replicator-flavored example.

---

## Recipe 5 — Stack manipulation patterns

The VM gives you only `:dup`, `:drop`, and `:swap`. Anything more complex
must be composed. Each pattern below is named informally.

### 5a — Duplicate top (keep a copy before consuming)

**Stack effect:** `( a -- a a )`

```elixir
[:dup]                  # → [a, a]      cost 0.1
```

**Use it before** any opcode that consumes the value you want to read again.
A classic pairing is `:dup` before `:jz_t` or `:jnz_t`: the conditional
jump pops its test value regardless of branch, so without the `:dup` the
value is gone afterwards. With the `:dup` first, the value is preserved on
the stack for the next instruction.

### 5b — Drop-second (remove the value just below the top)

**Stack effect:** `( b a -- a )`

```elixir
[:swap,      # → [a, b]      top and second swap
 :drop]      # → [a]         drop the new top (was b)
```

**Cost:** `swap (0.1) + drop (0.1) = 0.20` energy.

**Use it** to discard a value you no longer need that is sitting *below*
the value you do need — for example, the `1` or `0` result of
`:make_plasmid` when the value above it is still useful.

### 5c — 2-deep peek (look at the second-from-top value)

**Stack effect:** `( b a -- b a b )` — a copy of `b` (originally second)
ends up on top.

```elixir
[:swap,      # → [a, b]    bring b to the top
 :dup,       # → [a, b, b] duplicate it
 :swap]      # → [a, b, b] (top two swap doesn't help when they're equal)
```

The pure result `( b a -- b a b )` requires breaking and restoring order
around the duplication. A more useful pattern is to *consume* the
duplicated value immediately:

```elixir
# pre:    [b, a]
[:swap,      # → [a, b]
 :dup,       # → [a, b, b]
 # ... opcode that consumes the top b (e.g., :jz_t or arithmetic) ...
 :swap]      # → [b, a]    restores original order, assuming consumer left
             #             one value on top
```

**Cost:** `swap (0.1) + dup (0.1) + swap (0.1) = 0.30` energy for the
peek-and-restore frame. If you need 2-deep access often, **storing the
value in a slot (recipe 6) is cheaper and clearer.**

### 5d — Reverse top three

**Stack effect:** `( c b a -- a b c )`

A pure-stack reverse of three is awkward without an `:over` opcode (the VM
lacks one). The cleanest approach uses a slot as a parking spot:

```elixir
# pre:    [c, b, a]
[:push0, :store,     # slot[0] = a;  → [c, b]      (top was a)
 :swap,              # → [b, c]
 :push0, :load]      # → [b, c, a]                  — but we wanted [a, b, c]
```

The above swaps positions of `a` and `c` but leaves `b` in the middle in
the wrong place. A correct three-element reverse needs two parking slots:

```elixir
# pre:    [c, b, a]
[:push0, :store,     # slot[0] = a;  → [c, b]
 :push1, :store,     # slot[1] = b;  → [c]
 :push0, :load,      # → [c, a]
 :push1, :load]      # → [c, a, b]                  — still not [a, b, c]
```

The honest conclusion: a true reverse of three is fragile in this VM.
**Use slots throughout** for anything beyond depth 2. Concretely, store
all three values into slots, then load them back in the desired order:

```elixir
# pre:    [c, b, a]
[:push0, :store,     # slot[0] = a
 :push1, :store,     # slot[1] = b
 # stack is now [c]; the c was at the bottom of the original three.
 # We need a third slot — use slot 2.
 :push1, :dup, :add, # → [c, 2]
 :store,             # slot[2] = c

 # now load in the order we want: a (was on top), then b, then c on top.
 :push0, :load,      # → [a]
 :push1, :load,      # → [a, b]
 :push1, :dup, :add, # → [a, b, 2]
 :load]              # → [a, b, c]
```

**Cost:** three stores + three loads + the arithmetic to build slot index
`2` twice ≈ `3 × 0.5 + 3 × 0.5 + 2 × (0.1 + 0.1 + 0.2) = 3.80` energy.
**The lesson:** prefer slots for any manipulation beyond depth 2 — and
question whether you really need a three-element reverse in the first
place.

---

## Recipe 6 — Storage idioms (basic)

Slots are four per-creature integers indexed 0..3. They persist across
opcode bursts and start at 0. Cost: `:store` 0.5, `:load` 0.5.

### 6a — Save a value into a slot

**Stack effect:** `( v -- )`, side effect: `slot[s] = v`.

```elixir
[:push1, :store]      # slot[1] = v        (slot_idx = 1, pops both)
```

Trace, assuming the stack starts as `[42]`:

```
before:        [42]
push1     →    [42, 1]
store     →    [ ]                ; slot[1] = 42 (top=slot_idx, second=value)
```

**Cost:** `push1 (0.1) + store (0.5) = 0.60` energy.

The `:store` opcode pops the slot index first (top) and the value second
(below). This is the most-forgotten detail in the VM. If you write
`:store, :push1` thinking you'll specify the slot afterward, you've
already corrupted state — `:store` already ran with whatever was on top.

### 6b — Load and use a slot value

**Stack effect:** `( -- v )`.

```elixir
[:push1, :load]       # → [slot[1]]
```

**Cost:** `push1 (0.1) + load (0.5) = 0.60` energy.

### 6c — Check-and-update (increment slot by 1)

**Stack effect:** `( -- )`, side effect: `slot[s] += 1`.

```elixir
[:push1, :load,       # → [counter]
 :push1, :add,        # → [counter + 1]
 :push1, :store]      # slot[1] = counter + 1
```

Trace, assuming `slot[1] = 7`:

```
push1      →   [1]
load       →   [7]              ; popped 1, pushed slot[1]
push1      →   [7, 1]
add        →   [8]
push1      →   [8, 1]
store      →   [ ]              ; slot[1] = 8
```

**Cost:** `push1 (0.1) + load (0.5) + push1 (0.1) + add (0.2) + push1 (0.1)
+ store (0.5) = 1.50` energy per increment.

---

## Recipe 7 — Storage idioms (advanced)

### 7a — Counter with bounds (wrap on overflow)

**When to use:** You want a counter that cycles 0 → 1 → 2 → ... → max-1 →
0 → ... rather than growing unbounded.

**Code (counter mod 8 in slot 1):**

```elixir
[:push1, :load,       # → [counter]
 :push1, :add,        # → [counter + 1]
 :push1, :dup, :add,  # → [counter+1, 2]
 :dup, :add,          # → [counter+1, 4]
 :dup, :add,          # → [counter+1, 8]
 :mod,                # → [(counter+1) mod 8]   (mod: second mod top)
 :push1, :store]      # slot[1] = result
```

**Cost:** `push1+load (0.6) + push1+add (0.3) + push1+3×(dup+add) (0.1+0.9
= 1.0) + mod (0.2) + push1+store (0.6) = 2.70` energy per cycle.

**Discussion:** `:mod` is `second mod top`, so the modulus (8) must be on
top of the stack when `:mod` runs. If you build the modulus *first* and
load the counter after, you get the wrong direction:
`8 mod (counter+1)`, which is 0 for counter ≥ 8 and otherwise small — not
what you want.

### 7b — Accumulator (running sum)

**When to use:** Aggregate a value over time — e.g., total energy harvested,
or sum of sensed values.

**Code (add new value v on top to slot 1):**

```elixir
[# pre: stack = [v]
 :push1, :load,       # → [v, sum]
 :add,                # → [v + sum]
 :push1, :store]      # slot[1] = v + sum
```

Trace, assuming `slot[1] = 30` and stack top is `5`:

```
before:       [5]
push1     →   [5, 1]
load      →   [5, 30]           ; popped 1, pushed slot[1] = 30
add       →   [35]              ; 5 + 30  (add is commutative)
push1     →   [35, 1]
store     →   [ ]               ; slot[1] = 35
```

**Cost:** `push1+load (0.6) + add (0.2) + push1+store (0.6) = 1.40` energy
per accumulation.

### 7c — Swap two slot values

**When to use:** Rare, but occasionally useful — e.g., swap "current
target" and "next target".

**Code (swap slot 0 and slot 1):**

The plan: load both values, `:swap` them on the stack, then `:store` each
back into the *other* slot.

```elixir
[:push0, :load,       # → [A]            A = slot[0]
 :push1, :load,       # → [A, B]         B = slot[1]
 :swap,               # → [B, A]         A is now on top
 :push1, :store,      # slot[1] = A;  → [B]   (push 1 then store: index=1, value=A)
 :push0, :store]      # slot[0] = B           (push 0 then store: index=0, value=B)
```

The non-obvious part is the order: after the `:swap`, A is on top and B is
second. To put A into slot 1 first, push `1` and `:store`; that consumes
both, leaving B on top. Then push `0` and `:store` to put B into slot 0.

Trace, assuming `slot[0] = 10, slot[1] = 99`:

```
push0      →   [0]
load       →   [10]              ; slot[0]
push1      →   [10, 1]
load       →   [10, 99]          ; slot[1]
swap       →   [99, 10]
push1      →   [99, 10, 1]
store      →   [99]              ; slot[1] = 10
push0      →   [99, 0]
store      →   [ ]               ; slot[0] = 99
```

After: `slot[0] = 99, slot[1] = 10`. Swap accomplished.

**Cost:** `push0+load (0.6) + push1+load (0.6) + swap (0.1) + push1+store
(0.6) + push0+store (0.6) = 2.50` energy.

**Discussion:** Operand order is the trap. `:store` pops slot_idx (top) THEN
value (second). So immediately after `:swap` the stack is `[B, A]` with A
on top; pushing the slot index `1` and storing writes A into slot 1.
You then re-push the index `0` and store B into slot 0. Drawing the stack
beside each opcode is the only reliable way to get this right on the first
try.

---

## Recipe 8 — Self-inspection (read your own opcode)

**When to use:** Building a copy loop (chapter 7) — you need to read the
opcode at a given position in your own codeome and write it into a child
buffer.

**Stack effect:** `( addr -- op_int )`. Cost: 0.3.

**Code (read opcode at position 5):**

```elixir
[:push1, :dup, :add, :push1, :add,   # → [5]   (build 5 via doubling + addition)
 :read_self]                          # → [op_int_at_pos_5]
```

`:read_self` pops the address from the top of the stack and pushes the
**integer encoding** of the opcode found at `codeome[addr mod size]`. It
does NOT push the opcode atom name — it pushes a small integer
(0..37). The encoding map is canonical:

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

If the address falls outside `0..size-1` it is wrapped (`addr mod size`),
so out-of-range arithmetic is safe.

**Copy-one-cell snippet (read self at slot[1], write to child at slot[1]):**

```elixir
[:push1, :load,        # → [i]            current address (also child dest)
 :read_self,           # → [op_int]       reads codeome[i]
 :push1, :load,        # → [op_int, i]    child_addr
 :swap,                # → [i, op_int]    swap to put child_addr below op_int
 :write_child]         # writes op_int → child[i]; pops both
```

Why the swap? `:write_child` pops `op_int` (top) THEN `child_addr` (second).
After `:read_self` the stack is `[op_int]` and after the second
`:push1, :load` it is `[op_int, i]` — but `i` is now on top and
`:write_child` would read it as the opcode. The swap restores the correct
order: `[i, op_int]`, with `op_int` on top.

**Cost of one copy step:** `push1+load (0.6) + read_self (0.3) + push1+load
(0.6) + swap (0.1) + write_child (1.0) = 2.60` energy per opcode copied.
Wrap this in a counter loop (recipe 2 with N = codeome size) and you have
the core of a replicator. See chapter 7 for the full skeleton.

**Discussion:** Reading `:read_self` is a pure VM operation — no world
yield, cost 0.3 — but `:write_child` yields to the World and costs 1.0. A
typical replicator copies its full codeome (say, 150 opcodes) which costs
roughly `150 × 2.60 = 390` energy just for the byte-by-byte copy, on top of
the per-loop overhead from the counter (recipe 2). Energy economy
considerations live in chapter 8.

---

## Bonus recipe — Coin flip (50/50 branch decision)

This is documented in chapter 2 and chapter 10 as a one-liner, but here is
the full trace so a beginner can see it in action.

**Stack effect:** `( -- 0 or 1 )`.

**Code:**

```elixir
[:pushN,                # → [r]           r is uniform in 0..255
 :push1, :push1, :add,  # → [r, 2]        build the divisor
 :mod]                  # → [r mod 2]     0 if r is even, 1 if r is odd
```

Trace, assuming `pushN` happens to draw 137:

```
pushN      →   [137]
push1      →   [137, 1]
push1      →   [137, 1, 1]
add        →   [137, 2]
mod        →   [1]             ; 137 mod 2  (mod is second mod top)
```

**Cost:** `pushN (0.1) + push1 (0.1) + push1 (0.1) + add (0.2) + mod (0.2)
= 0.70` energy.

**Discussion:** The bias is exactly 50/50 because the source range
(0..255) has 256 elements — even count — so exactly 128 even and 128 odd
outcomes. The most common mistake is reversing operand order so that the
result is `2 mod r`, which is 2 for almost all r and breaks the coin
entirely. See chapter 10 Pattern 2 for the full branched form combining
this with a `:jz_t`.

---

## Bonus recipe — Wait until condition

**When to use:** Sit in a tight loop until the world changes (a cell becomes
empty, or your energy crosses a threshold).

**Code (spin until the front cell is empty):**

```elixir
[# ── WAIT_HEAD anchor [0,0,0,0] ─────────────────────────────────
 :nop_0, :nop_0, :nop_0, :nop_0,

 # ── sense; if non-zero, loop back ──────────────────────────────
 :sense_front,
 :jnz_t, :nop_1, :nop_1, :nop_1, :nop_1]   # template → anchor [0,0,0,0]
```

Trace (cell occupied, k = 5):

```
sense_front      →   [5]
jnz_t [1,1,1,1]   tests 5 ≠ 0 → jump fires; pops 5
                  searches anchor [0,0,0,0] backward → lands at WAIT_HEAD + 4
                  (after the nops)
```

**Cost per spin iteration:** `4 × nop_0 (0.4) + sense_front (0.5) + jnz_t[4]
(0.4) = 1.30` energy per spin. **Beware**: this is a busy loop. On an
empty grid with a stable obstruction in front, this drains energy at
roughly 1.3 per iteration with no productive work. Use only when you have
reason to expect the wait to be short.

---

## Bonus recipe — Random walk vs directed walk

**Random walk (pick direction uniformly each step):**

```elixir
[:pushN,                                    # → [r]      0..255
 :push1, :dup, :add, :dup, :add,            # → [r, 4]
 :mod,                                       # → [r mod 4]  0..3 → direction index

 # ── Branch on the direction index ─────────────────────────────
 # Easiest realisation: use jz_t/jnz_t cascades, or convert to a
 # series of turn_lefts. Cheapest is a turn_left cascade:
 :push1, :store,                            # slot[1] = r mod 4

 # ── turn_left counter times ───────────────────────────────────
 :nop_0, :nop_0, :nop_0, :nop_0,            # anchor
 :push1, :load,
 :jz_t, :nop_1, :nop_1, :nop_0, :nop_0,    # if 0, skip turn_left
 :turn_left,
 :push1, :load, :push1, :sub, :push1, :store,
 :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,    # back to anchor
 :push0,
 :nop_0, :nop_0, :nop_1, :nop_1,            # skip-target anchor
 :move]
```

**Directed walk:** simply `:move` repeatedly inside a loop with no turn.
The walker from chapter 3 is the canonical directed walker; chapters 4–5
add foraging and turning. The random walk above costs ~5–10 energy per
step (depending on the value of r mod 4); a directed walk costs only the
2.0 of `:move`. Random walks explore more area but starve faster.

---

## Closing notes

These recipes are the alphabet. The cookbook in chapter 10 shows them
combined into mature idioms; the MinimalReplicator dissected in chapter 9
shows them combined into a real working creature. When something does not
behave the way you expect, the discipline is the same one chapter 4
introduced: *draw the stack beside every opcode*. The trace is always more
honest than your intuition about what the stack looks like — especially
after a `:jz_t` or a `:store` where operand order is easy to misread.

Some general guidelines:

- **Slots are precious.** With only four, dedicate them deliberately —
  this manual uses slot 0 for replication state and slot 1 for loop
  counters, leaving slot 2 and slot 3 for application-specific data.
- **Templates cost per bit.** 4-bit templates (cost 0.40 per jump) are
  the sweet spot; 8-bit templates (cost 0.60) are rarely worth it unless
  you need many distinct anchors in a long codeome.
- **`:push0` is the cheapest no-op-with-side-effect.** Use it as a
  separator (chapter 4 § 4 / chapter 10 Pattern 5) and as padding to meet
  the validator's 10-non-nop minimum.
- **When in doubt, store and load.** Pure-stack juggling beyond depth 2
  is fragile; slots are cheap (0.5 each) and dramatically more readable.

For more advanced patterns — full replication, conjugation, energy budget
analysis — continue with chapters 7, 8, 9, and 11.

Happy hacking.
