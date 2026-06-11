# Chapter 6 — Procedures

Most languages give you a way to name a block of code and call it by name: `def`, `function`, `proc`,
`fn`. The Lenies VM has none of that. There is no name binding, no parameter list, no explicit
function table. What it has instead is two opcodes — `call_t` and `ret` — that together give you
**jump-with-return**: the VM remembers where execution should resume and jumps to a labelled region,
and `ret` brings it back. That is the entire mechanism. Everything else is convention.

This chapter explains the mechanics, the costs, when to use procedures, and how to build a
sense-branch creature whose eat-and-move behaviour lives in one procedure instead of two copies.
The structured, recursive seed **Architect** (rung 3) is built entirely on this mechanism — its
`MAIN` calls `FORAGE` and `REPLICATE`, and `FORAGE` in turn calls a nested `STEER`.

---

## 1  The VM has no `def`

In Python you write:

```python
def eat_and_move():
    eat()
    move()
```

In Lenies you write a stretch of code with a recognisable nop-pattern at the front (the "anchor"),
end it with `:ret`, and jump to it with `:call_t`. The anchor is the function's address. The
nop-pattern is its "name". There is no registry; the VM simply searches for the matching complement
at call time, exactly the same way `jmp_t` does.

The implication is significant: **procedures are found dynamically**. If you have two regions with
the same anchor pattern, `call_t` will find whichever one the search algorithm reaches first. This
is normally a problem to avoid (use unique patterns), but it also means a codeome can evolve
alternative procedure implementations and have them shadow each other.

---

## 2  `call_t` and `ret` mechanics

### 2.1  `call_t` step by step

Assume the instruction pointer is at position `C` and the opcode there is `:call_t`.

**Step 1 — Extract the template.**
The VM reads consecutive nop-cells starting at `C + 1`. Extraction stops at the first non-nop cell
(or when the maximum template length is reached). Let the extracted template have length `T` and
occupy positions `C+1 .. C+T`.

**Step 2 — Compute the return address.**

```
return_ip = (C + 1 + T) mod size
```

This is the cell immediately after the template — the first instruction that would execute if there
were no call at all. It is the address the caller expects to resume at after the procedure finishes.

**Step 3 — Push return_ip onto the call stack.**
The call stack is a separate list, completely independent of the data stack. `push_call` prepends
`return_ip` to the front of the call stack list (head = most recent entry).

**Step 4 — Search for the complement.**
The template is complemented (every `0` becomes `1`, every `1` becomes `0`) and the VM searches the
codeome for a run of nop-cells matching the complement, starting just beyond the current ip. The
search radius is the same as for `jmp_t`.

**Step 5a — Search succeeds.**
Let `match_pos` be the position where the complement begins. Execution jumps to:

```
target_ip = (match_pos + T) mod size
```

That is, just past the matched anchor — the first real instruction in the procedure body.

**Step 5b — Search fails.**
The VM falls through: `ip ← return_ip` (where `return_ip = ip + 1 + template_len`, computed in Step 3). Execution continues from the instruction immediately after the template. **The return address is NOT pushed onto the call stack on failure** — `State.push_call` only fires in the success branch. No orphaned frame is created. The cost (`0.2 + 0.05·t_len`) is paid either way.

### 2.2  `ret` step by step

Assume the instruction pointer is at position `R` and the opcode there is `:ret`.

**Step 1 — Pop the call stack.**

- If the call stack is **empty**: `ip ← (R + 1) mod size`. Execution falls through to the next
  cell. The opcode costs `0.2` energy (template length is 0).
- If the call stack is **non-empty**: the top entry is removed and `ip` is set to that value.
  Execution jumps to `return_ip`.

The data stack is untouched by both `call_t` and `ret`. Any values the caller pushed before the
call are still there when the procedure returns. Any values the procedure pushes are still there
too. Procedures share the data stack with their callers — which means a procedure can return
computed values to its caller simply by leaving them on the stack.

---

## 3  Cost and call-stack depth

### 3.1  Energy cost

Both `call_t` and `ret` follow the same formula as the other template opcodes (from `costs.ex`):

```
cost = 0.2 + 0.05 x template_len
```

For `:ret` the template length is always 0 (`:ret` has no following template), giving a fixed cost
of **0.2**.

For `:call_t` with a 4-cell template the cost is `0.2 + 0.05 × 4 = 0.40`.

A complete call-and-return round trip with 4-bit anchors therefore costs:

```
call_t  (T=4)  -> 0.40
ret     (T=0)  -> 0.20
total          -> 0.60
```

plus whatever the procedure body costs. That 0.60 overhead is the price of the procedure
abstraction. Factor it into your energy budget.

### 3.2  Call-stack depth limit

The call stack has a maximum depth of 32 entries (`@call_stack_max` in `state.ex`). When a 33rd
entry is pushed, `push_call` keeps the 32 most recent entries and silently **drops the oldest**.
The entry at the tail of the list (the oldest return address) is the one discarded.

```elixir
# state.ex - push_call implementation
new_cs = [return_ip | cs] |> Enum.take(@call_stack_max)
```

The head of the list is the most recently pushed entry (the one `ret` will consume first). `Enum.take`
keeps the first 32, so the 33rd-oldest is dropped off the tail.

The practical consequence: with very deep recursion or many nested calls you will eventually lose
the ability to return all the way back to the outermost caller. There is no error — the lenie keeps
running, but `ret` will return to the wrong place once the frame it needed has been discarded.
For typical non-recursive subroutine use (nesting depth ≤ 3 or 4) this limit is never reached.

---

## 4  When to factor out a procedure

The call-and-return round trip costs energy and adds cells to the codeome. Whether to factor a
repeated sequence into a procedure is a trade-off between three things:

1. **Code size**: fewer total cells in the codeome mean a smaller target for background mutation.
2. **Mutation stability**: a procedure body exists in one place. A mutation there affects all call
   sites uniformly. Inlined copies mutate independently — a mixed blessing.
3. **Energy overhead**: every call/ret round trip costs at least 0.60 (4-bit template).

**Rule of thumb**: factor out a sequence when it is called from **at least 2 distinct call sites**
AND the overhead is smaller than the size savings.

**Concrete example.** A 5-op sequence called from 3 sites:

| Strategy   | Total cells                            | Notes                               |
|------------|----------------------------------------|-------------------------------------|
| Inlined    | 3 × 5 = 15 body cells                 | Zero call overhead                  |
| Procedure  | 5 body + 3 × (call_t + 4 nops + ret) = 5 + 18 = 23 cells | One copy of body |

The procedure version is *larger*, not smaller! But only one copy of the body can be mutated. For
stability under evolution, fewer distinct copies wins even if total cell count is higher.

For only 2 call sites:
- Inlined: 10 cells
- Procedure: 5 + 2 × 6 = 17 cells

The size cost of inlining falls as the body grows. For short bodies (< 4 ops) and only 2 call
sites, inline usually wins. For longer bodies or 3+ call sites, procedures win on robustness.

---

## 5  Anchor naming convention for procedures

Chapter 4 established the bit-pattern convention: anchors are pure nop-sequences, and you pick
distinct patterns to avoid false matches.

For procedures, add a **conceptual name in a comment**:

```elixir
# EAT_MOVE anchor [1,1,1,0]
:nop_1, :nop_1, :nop_1, :nop_0,
```

The pattern `[1,1,1,0]` is the anchor. `EAT_MOVE` is the human name. When a `call_t` has a
template `[0,0,0,1]`, its complement is `[1,1,1,0]`, which is exactly this anchor. The comment
makes that connection explicit without inventing any VM mechanism.

Keep a short index at the top of your codeome comments listing each anchor and its role:

```elixir
# Anchor map:
#   [0,0,0,0] - LOOP_HEAD  (target of jmp_t with template [1,1,1,1])
#   [1,0,0,1] - TURN       (target of jz_t  with template [0,1,1,0])
#   [1,1,1,0] - EAT_MOVE   (target of call_t with template [0,0,0,1])
```

---

## 6  The Subroutine Crawler

We will build a sense-branch creature like Reflex from chapter 4, but with `:eat; :move` factored
into a single procedure, called from two places:

1. After a successful `sense_front` (food detected — eat and move forward).
2. After a random `turn_right` (turn to a new heading then immediately step forward).

The second call site is a slight behavioural change: Reflex turned in place and looped; this version
takes a step after each turn, covering ground more actively.

### 6.1  Anchor selection

We have three distinct anchor patterns:

| Role        | Anchor bits | Matched by template |
|-------------|-------------|---------------------|
| `LOOP_HEAD` | `[0,0,0,0]` | `jmp_t [1,1,1,1]`   |
| `TURN`      | `[1,0,0,1]` | `jz_t  [0,1,1,0]`   |
| `EAT_MOVE`  | `[1,1,1,0]` | `call_t [0,0,0,1]`  |

Opcodes **search for the complement of their template**, so each opcode is looking for a different
bit-pattern:

- `jmp_t [1,1,1,1]` searches for the complement `[0,0,0,0]` — it should find `LOOP_HEAD`.
- `jz_t  [0,1,1,0]` searches for the complement `[1,0,0,1]` — it should find `TURN`.
- `call_t [0,0,0,1]` searches for the complement `[1,1,1,0]` — it should find `EAT_MOVE`.

There is a subtlety that is easy to miss: **a template is itself a run of nop-cells sitting in the
codeome**, so the complement search can land on another opcode's template, not just on an anchor.
The search is forward-first and stops at the *first* matching run, so you must keep every template
distinct from every complement that some other opcode is hunting for. Concretely, the `jmp_t`
templates are `[1,1,1,1]` — if we had chosen `EAT_MOVE = [1,1,1,1]` (so `call_t` searched for
`[1,1,1,1]`), then `call_t` would have matched the nearest `jmp_t` template instead of the real
`EAT_MOVE` anchor. Choosing `EAT_MOVE = [1,1,1,0]` keeps the `call_t` complement (`[1,1,1,0]`)
clear of every template in the codeome, so the only run it can match is the anchor we intended.

The lesson: anchors and templates all live in the same nop bit-space. Pick anchor patterns whose
complements do not coincide with any template you use elsewhere, and separate adjacent groups with a
non-nop cell so two groups never merge into one long run.

### 6.2  Full codeome

```elixir
[
  # == Anchor map: ============================================
  #   [0,0,0,0] LOOP_HEAD  <- jmp_t template [1,1,1,1]
  #   [1,0,0,1] TURN       <- jz_t  template [0,1,1,0]
  #   [1,1,1,0] EAT_MOVE   <- call_t template [0,0,0,1]
  #
  # == 0..3   LOOP_HEAD anchor [0,0,0,0] ======================
  :nop_0, :nop_0, :nop_0, :nop_0,
  # == 4      sense the front cell ============================
  :sense_front,
  # == 5..9   jz_t to TURN [1,0,0,1] - template [0,1,1,0] =====
  :jz_t, :nop_0, :nop_1, :nop_1, :nop_0,
  # == 10..14 call_t to EAT_MOVE [1,1,1,0] - template [0,0,0,1]
  :call_t, :nop_0, :nop_0, :nop_0, :nop_1,
  # == 15..19 jmp_t back to LOOP_HEAD - template [1,1,1,1] ====
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,
  # == 20     separator (prevents template bleed) =============
  :push0,
  # == 21..24 TURN anchor [1,0,0,1] ===========================
  :nop_1, :nop_0, :nop_0, :nop_1,
  # == 25     turn right ======================================
  :turn_right,
  # == 26..30 call_t to EAT_MOVE - template [0,0,0,1] =========
  :call_t, :nop_0, :nop_0, :nop_0, :nop_1,
  # == 31..35 jmp_t back to LOOP_HEAD - template [1,1,1,1] ====
  :jmp_t, :nop_1, :nop_1, :nop_1, :nop_1,
  # == 36     separator =======================================
  :push0,
  # == 37..40 EAT_MOVE anchor [1,1,1,0] =======================
  :nop_1, :nop_1, :nop_1, :nop_0,
  # == 41     eat =============================================
  :eat,
  # == 42     move ============================================
  :move,
  # == 43     ret =============================================
  :ret
]
```

Total: 44 cells (indices 0–43). Non-nop opcodes: `sense_front`, `jz_t`, `call_t`, `jmp_t`,
`push0`, `turn_right`, `call_t`, `jmp_t`, `push0`, `eat`, `move`, `ret` — 12 opcodes. The
codeome validator accepts any mix; this passes.

### 6.3  Why the separators

Position 20 (`:push0`) sits between the end of the first `jmp_t` template (position 19, `:nop_1`)
and the start of the TURN anchor (position 21, `:nop_1`). Both neighbours are nop-cells. Without a
separator, any template-extraction that happened to scan across this boundary from position 19 into
position 21 would see a longer run of nops and extract a template that was never intended.

Position 19 is the last cell executed before the `jmp_t` at position 15 jumps back to
`LOOP_HEAD`, so no instruction naturally reads across 19→21 in normal execution. The separator is
**defensive**: it prevents an evolved or mutated `jmp_t`/`call_t` landing on position 20 from
seeing a spuriously long template spanning both groups. The same reasoning applies to the separator
at position 36.

---

## 7  Stack trace through one call

The lenie starts facing north (`:n`). Assume food is present in front at this tick, so
`sense_front` pushes a non-zero value and `jz_t` does NOT jump (condition is false — the stack
top is non-zero). Execution reaches `:call_t` at position 10.

```
tick | ip | opcode         | call stack | data stack | notes
-----+----+----------------+------------+------------+----------------------------------
  1  |  0 | nop_0          | []         | []         | LOOP_HEAD anchor, costs 0.1
  2  |  1 | nop_0          | []         | []         |
  3  |  2 | nop_0          | []         | []         |
  4  |  3 | nop_0          | []         | []         |
  5  |  4 | sense_front    | []         | [1]        | food present; push 1; costs 0.5
  6  |  5 | jz_t           | []         | [1]        | template [0,1,1,0] -> T=4
     |    |                |            |            | top=1 (non-zero) -> no jump
     |    |                |            |            | ip <- 5+1+4=10; costs 0.40
  7  | 10 | call_t         | [15]       | [1]        | template [0,0,0,1] -> T=4
     |    |                |            |            | return_ip = 10+1+4 = 15
     |    |                |            |            | push 15 onto call stack
     |    |                |            |            | search complement [1,1,1,0]
     |    |                |            |            | found at pos 37; target = 37+4 = 41
     |    |                |            |            | ip <- 41; costs 0.40
  8  | 41 | eat            | [15]       | [1]        | costs 2.0
  9  | 42 | move           | [15]       | [1]        | costs 2.0
 10  | 43 | ret            | []         | [1]        | pop 15 from call stack
     |    |                |            |            | ip <- 15; costs 0.20
 11  | 15 | jmp_t          | []         | [1]        | template [1,1,1,1] -> T=4
     |    |                |            |            | search complement [0,0,0,0]
     |    |                |            |            | found at pos 0; target = 0+4 = 4
     |    |                |            |            | ip <- 4; costs 0.40
 12  |  4 | sense_front    | []         | [1,1]      | next iteration begins ...
```

Key observations:

- **The data stack is untouched by `call_t` and `ret`.** The `1` pushed by `sense_front` remains
  on the stack throughout the call and return. (The lenie never pops it in this codeome — it
  accumulates, but at stack depth 1 per loop that is fine until the stack fills at depth 16.)
- **The call stack is cleanly balanced.** One push at tick 7, one pop at tick 10.
- **`ret` at tick 10 costs 0.20** — it has no template (template length = 0).
- The procedure body at positions 41–43 executes without knowing or caring how it was called. If
  it had been entered via a `jmp_t` instead (no return address on the call stack), `ret` at
  position 43 would fall through to position 44, which wraps to position 0 in a 44-cell codeome —
  right back to `LOOP_HEAD` by coincidence in this layout.

---

## 8  `ret` on an empty call stack

If `:ret` executes when the call stack is empty it advances ip by 1 (falls through). This is
defined, non-fatal behaviour:

```elixir
# state.ex
def pop_call(%__MODULE__{call_stack: []} = s), do: {nil, s}
```

When `pop_call` returns `nil`, the interpreter uses `State.advance_ip(size, 1)` instead of setting
`ip` to a popped value.

**When would this happen legitimately?**

A procedure that can be entered either via `call_t` or via plain `jmp_t` can still end with `ret`.
If entered via `call_t`, `ret` returns to the caller. If entered via `jmp_t`, the call stack has no
frame for this procedure, and `ret` falls through to the cell after `:ret`. If the cell after
`:ret` is a `jmp_t` back to a known anchor, the procedure degrades gracefully into an unconditional
branch when called the "wrong" way.

This dual-entry idiom is occasionally useful for evolved code but is generally fragile in
hand-written codeomes. In the Subroutine Crawler above, `EAT_MOVE` is only ever entered via
`call_t`, so `ret` always has a frame to pop.

**The orphaned-frame case from Section 2.1 revisited.** If a `call_t` fails to find its anchor,
execution falls through to `return_ip`, but the frame is already on the call stack. The next `:ret`
the lenie executes — wherever it is in the codeome — will pop that orphaned frame and jump to the
caller's return address. If the `:ret` is inside a different procedure, that procedure will appear
to return to the caller of the failed `call_t` instead of to where it should have gone. In
hand-written codeomes with stable anchor patterns this never happens. In evolved code, guard the
call stack depth carefully.

---

## 9  Try it

Open the Lenies editor and create a new genome named **subroutine-crawler-v1**. Enter the 44-cell
codeome from Section 6.2 exactly as listed. Spawn one lenie with medium energy (400–600).

**What to observe:**

- In a world with scattered food patches the lenie moves in straight lines until it hits an empty
  cell, turns right, then immediately steps in the new direction (the second `call_t` at position
  26 fires after every `turn_right`).
- Reflex turned and stayed put until the next sense; this version turns and steps,
  so it exits empty patches about one tick faster per turn.
- Energy consumption per loop is the same when food is found: `sense_front (0.5) + jz_t (0.4) +
  call_t (0.4) + eat (2.0) + move (2.0) + ret (0.2) + jmp_t (0.4) = 5.9`. When no food is found
  and the lenie turns: `sense_front (0.5) + jz_t (0.4) + turn_right (0.5) + call_t (0.4) + eat
  (2.0) + move (2.0) + ret (0.2) + jmp_t (0.4) = 6.4`.

**Verification steps:**

1. Confirm the codeome is exactly 44 cells in the editor's cell count display.
2. Watch the call stack panel (if your UI exposes it): it should never be deeper than 1 during
   normal operation.
3. Add a second lenie of the same genome to confirm the search radius does not cause cross-lenie
   anchor interference (anchors are searched within the lenie's own codeome only).

---

## 10  What's next

The Subroutine Crawler is a complete organism built from loops, conditional branches, and procedure
calls. The shipped seed **Architect** (rung 3) is the same idea taken to its conclusion: its forage
and replication logic are each their own subroutine, and its `STEER` routine is called *from inside*
`FORAGE` — a nested call, two frames deep on the call stack. The next leap it needs is
self-replication: teaching a lenie to copy its own codeome into a child. That requires `allocate`,
`write_child`, and `divide` — the most expensive opcodes in the VM.

→ Next: Chapter 7 builds the first replicator. ([07-replication.md](07-replication.md))
