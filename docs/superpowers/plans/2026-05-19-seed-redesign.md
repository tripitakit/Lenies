# Seed Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the three specialized seeds (Defender, Hunter, Forager) with distinctive movement archetypes per [the seed-redesign spec](../specs/2026-05-19-seed-redesign-design.md).

**Architecture:** Each seed is a single Elixir module under `lib/lenies/codeomes/` exposing `codeome/0` (a `Lenies.Codeome.t()`) and `opcodes/0` (the raw list, useful for debugging/manual extraction). All three keep MinimalReplicator's replication skeleton (LOOP_HEAD anchor → copy loop → divide → post-divide turn → K-iteration forage loop → repeat). Differences are localized to the forage body and the choice of K. Anchor patterns are reused freely across seeds — each codeome owns its own template namespace, so the same 4-bit pattern can mean different things in different seeds.

**Tech Stack:** Elixir 1.19.3-otp-28, ExUnit. Run tests with `mix test`. The codeome DSL is a flat list of `:atom` opcodes; the bytecode is what counts (no Elixir control flow at runtime). Reference cost table: [lib/lenies/codeome/costs.ex](../../../lib/lenies/codeome/costs.ex). Reference reading: [lib/lenies/codeomes/minimal_replicator.ex](../../../lib/lenies/codeomes/minimal_replicator.ex) for the canonical replication skeleton.

---

## Background — opcode and anchor mechanics

Every implementer needs these facts before writing bytecode:

- **Anchors** are 4 consecutive `:nop_0`/`:nop_1` opcodes. The template-extractor reads up to 8 consecutive nops; **two adjacent nop blocks must be separated by a non-nop opcode** (we use `:push0`) to avoid mis-extraction.
- **Jump templates**: a `:jz_t` / `:jnz_t` / `:jmp_t` is followed by 4 nops (the template). The runtime searches the codeome for the **bitwise complement** of that template (n0 ↔ n1) and jumps there.
  - Example: anchor `[n1, n1, n1, n1]` is reached via template `[n0, n0, n0, n0]`.
- **Anchor uniqueness within a codeome**: every anchor pattern in a single codeome must be distinct. Otherwise, a jump finds the wrong anchor.
- **Stack discipline for `:jz_t` / `:jnz_t`**: pops the top regardless of whether the jump is taken.
- **Slot[0] reuse**: holds `N` (own size) during copy phase, then holds the forage counter after. Slot[1] is the copy counter. Slot[2] is unused. Slot[3] is free for in-forage state.
- **`:store` argument order**: pops slot_idx (top), pops value (second). To store `V` → `slot[S]`: `push V, push S, store`.
- **`:mod` argument order**: pops `a` (top), pops `b` (second), pushes `b mod a`.
- **`:sub`**: pops `a`, pops `b`, pushes `b - a`.
- **`:read_self`**: pops addr, pushes opcode at that address.
- **`:write_child`**: pops opcode_int (top), pops child_addr (second), writes opcode to child at child_addr. Returns 1 (success) or 0 (no slot).
- **`:pushN`**: pushes a uniform random int in 0..255.

**Decrement-first forage counter**: forage loops in Hunter/Forager (and the new Defender) decrement at the top of each iteration. To get exactly `K` body iterations, the counter must be **initialized to `K + 1`** (after K+1 decrements the counter reads 0 and the loop exits).

---

## File Structure

**Modify:**
- `lib/lenies/codeomes/defender.ex` — full rewrite (new `@opcodes` + new `@moduledoc`)
- `lib/lenies/codeomes/hunter.ex` — full rewrite
- `lib/lenies/codeomes/forager.ex` — full rewrite
- `test/lenies/codeomes/hunter_test.exs` — add prey-damage test
- `README.md` — update Defender/Hunter/Forager bullets (lines 206-221)

**Unchanged:**
- `lib/lenies/codeomes/minimal_replicator.ex`
- `lib/lenies/codeomes/carnivore.ex`
- `lib/lenies/seeds.ex`
- `lib/lenies/codeome.ex`, `lib/lenies/codeome/costs.ex`, `lib/lenies/interpreter.ex`
- `test/lenies/codeomes/defender_test.exs` (gen ≥ 3 test still applies)
- `test/lenies/codeomes/forager_test.exs` (gen ≥ 3 test still applies)
- All other tests

---

## Task 1: Rewrite Defender

**Goal**: K=32, no in-forage turn logic, deterministic post-divide `turn_left`, forage body = `defend; eat; move`. ~93 opcodes total.

**Why this design**: K=32 + smaller codeome (no random post-divide branch, no in-forage turn) keeps the replication cost low enough that E_ss ≈ +184 at default `eat_amount: 20`. Removing the random post-divide turn drops `TURN_LEFT_ANCHOR` and `SKIP_TURN_ANCHOR`, simplifying the layout. Cluster shape comes from frequent replication (K=32 = replicates every ~32 forage steps).

**Files:**
- Modify: `lib/lenies/codeomes/defender.ex` (full rewrite)
- Test: `test/lenies/codeomes/defender_test.exs` (no changes; existing gen-≥-3 test must pass)

### Anchor table

| Label             | Anchor pattern   | Jump template (complement) |
|-------------------|------------------|----------------------------|
| LOOP_HEAD         | `[n1, n1, n1, n1]` | `[n0, n0, n0, n0]`         |
| COPY_LOOP_HEAD    | `[n1, n0, n0, n1]` | `[n0, n1, n1, n0]`         |
| ABORT_TARGET      | `[n1, n1, n0, n0]` | `[n0, n0, n1, n1]`         |
| FORAGE_LOOP_HEAD  | `[n0, n1, n0, n1]` | `[n1, n0, n1, n0]`         |

Four anchors total. No new anchors beyond a strict subset of MR's set.

- [ ] **Step 1.1: Read current Defender to capture aliases and module signature**

Run: `head -20 lib/lenies/codeomes/defender.ex`

Confirm the module is `Lenies.Codeomes.Defender`, aliases `Lenies.Codeome`, and exposes `codeome/0` and `opcodes/0`. The rewrite preserves these.

- [ ] **Step 1.2: Replace `lib/lenies/codeomes/defender.ex` with the new layout**

Full file content:

```elixir
defmodule Lenies.Codeomes.Defender do
  @moduledoc """
  Defensive herbivore that builds tight clusters. Replicates often (K=32),
  defends every forage iteration, and uses a deterministic post-divide
  `turn_left` instead of a random branch. Cluster shape emerges from the
  short forage runs (~32 cells before each replication) combined with the
  deterministic 90° turn after every divide — descendants spiral outward
  in a fractal pattern.

  ## Forage body

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit forage)
    defend
    eat
    move
    jmp_t FORAGE_LOOP_HEAD
  ```

  ## Anchors

  | Label             | Anchor             | Jump template      |
  |-------------------|--------------------|--------------------|
  | LOOP_HEAD         | [n1, n1, n1, n1]   | [n0, n0, n0, n0]   |
  | COPY_LOOP_HEAD    | [n1, n0, n0, n1]   | [n0, n1, n1, n0]   |
  | ABORT_TARGET      | [n1, n1, n0, n0]   | [n0, n0, n1, n1]   |
  | FORAGE_LOOP_HEAD  | [n0, n1, n0, n1]   | [n1, n0, n1, n0]   |

  Four anchors total — a strict subset of MR's six. The two MR anchors
  for the post-divide random branch (`TURN_LEFT_ANCHOR`, `SKIP_TURN_ANCHOR`)
  are dropped because this seed uses an unconditional `turn_left` after
  `divide`.

  ## Energy

  - Codeome length: 93 opcodes
  - Replication cost ≈ 526 energy (copy 93 × ~5.4 + setup + divide)
  - Per-iter forage cost ≈ 8.9 energy (defend 2.0 + eat 2.0 + move 2.0 +
    counter ~1.5 + load+jz_t+jmp_t ~1.4)
  - Eat gain at default `eat_amount: 20` ≈ +11.1 per iter
  - Steady state at K=32: E_ss = 2 × 32 × 11.1 - 526 ≈ +184 (sustainable).
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──────────────────────
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..6: get own size N, store in slot[0] ───────────────────────
    :get_size, :push0, :store,

    # ── pos 7..9: allocate child slot of size N in front cell ────────────
    :push0, :load, :allocate,

    # ── pos 10..14: jz_t ABORT_TARGET if allocate failed (template [n0,n0,n1,n1]) ──
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

    # ── pos 15..17: init copy counter slot[1] = 0 ────────────────────────
    :push0, :push1, :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor [n1, n0, n0, n1] ───────────────
    :nop_1, :nop_0, :nop_0, :nop_1,

    # ── pos 22..29: copy body — read self at slot[1], write to child ────
    :push1, :load, :read_self,
    :push1, :load, :swap, :write_child, :drop,

    # ── pos 30..35: increment slot[1] (copy counter) ─────────────────────
    :push1, :load, :push1, :add, :push1, :store,

    # ── pos 36..40: loop condition (N - (counter+1)) ─────────────────────
    :push0, :load, :push1, :load, :sub,

    # ── pos 41..45: jnz_t COPY_LOOP_HEAD (template [n0,n1,n1,n0]) ───────
    :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

    # ── pos 46: divide ───────────────────────────────────────────────────
    :divide,

    # ── pos 47..50: ABORT_TARGET anchor [n1, n1, n0, n0] ─────────────────
    :nop_1, :nop_1, :nop_0, :nop_0,

    # ── pos 51: deterministic post-divide turn ───────────────────────────
    :turn_left,

    # ── pos 52..62: build K=32 on stack (push1 + 5×(dup,add) = 32) ─────
    # push1 [1]; dup [1,1]; add [2]; dup [2,2]; add [4]; ... → 32 (11 ops)
    :push1, :dup, :add, :dup, :add, :dup, :add, :dup, :add, :dup, :add,

    # ── pos 63..64: K+1 = 33 (decrement-first loop overshoots by 1) ─────
    :push1, :add,

    # ── pos 65..66: store K+1 in slot[0] (forage counter) ────────────────
    :push0, :store,

    # ── pos 67..70: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 71..76: decrement slot[0] (slot[0] -= 1) ─────────────────────
    :push0, :load, :push1, :sub, :push0, :store,

    # ── pos 77..78: load slot[0] for exit check ──────────────────────────
    :push0, :load,

    # ── pos 79..83: jz_t LOOP_HEAD (template [n0,n0,n0,n0]) — exit forage ─
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 84..86: forage body — defend, eat, move ──────────────────────
    :defend, :eat, :move,

    # ── pos 87..91: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ─────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 92: separator — prevents template extractor from reading ────
    # 4 nops of the final template + 4 nops of LOOP_HEAD across wrap.
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
```

- [ ] **Step 1.3: Sanity-check the opcode count**

Run from project root:

```bash
cd /home/patrick/projects/playground/Lenies && mix run -e 'IO.inspect(length(Lenies.Codeomes.Defender.opcodes()))'
```

Expected output: `93`

If output differs, recount the layout above against the spec.

- [ ] **Step 1.4: Run the Defender test**

```bash
mix test test/lenies/codeomes/defender_test.exs
```

Expected: 1 test passes, no failures. (The test boosts `eat_amount` to 50, which is well above sustainability threshold.)

If it fails with a timeout, the codeome likely has a template-collision or unreachable jump — re-check anchor patterns table.

- [ ] **Step 1.5: Run the full test suite**

```bash
mix test
```

Expected: all tests pass (354 currently). No regressions outside the rewritten seed.

- [ ] **Step 1.6: Commit**

```bash
git add lib/lenies/codeomes/defender.ex
git commit -m "feat(defender): K=32 cluster-forming seed (defend each iter, no in-forage turn)

Replaces the in-forage random-turn-every-5 with a simpler body
(defend, eat, move) and shrinks K from 64 → 32. Deterministic
post-divide turn_left frees two anchor patterns and drops codeome
size from ~149 → 93 opcodes, keeping the cycle sustainable at
default eat_amount=20.

Visual signature: short straight runs (~32 cells) terminated by
divide + 90° turn. Descendants spiral outward in a fractal pattern.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Rewrite Forager

**Goal**: K=128, deterministic post-divide `turn_left`, 3-way 33/33/33 random turn (no-turn / left / right) after each forward step. ~138 opcodes.

**Why this design**: `pushN mod 3` produces a uniform-ish distribution over {0, 1, 2} (bias 2.4%, negligible). A `dup; jz_t NO_TURN_BR` then `push1; sub; jz_t TURN_LEFT_BR` chains two zero-checks to split into 3 paths. The direction performs a random walk on cardinals → position drifts as a 2D random walk → fills space instead of tracing lines. K=128 (same as MR) because random walk needs many steps for visible coverage.

**Files:**
- Modify: `lib/lenies/codeomes/forager.ex` (full rewrite)
- Test: `test/lenies/codeomes/forager_test.exs` (no changes; existing gen-≥-3 test must pass)

### Anchor table

| Label             | Anchor pattern   | Jump template (complement) |
|-------------------|------------------|----------------------------|
| LOOP_HEAD         | `[n1, n1, n1, n1]` | `[n0, n0, n0, n0]`         |
| COPY_LOOP_HEAD    | `[n1, n0, n0, n1]` | `[n0, n1, n1, n0]`         |
| ABORT_TARGET      | `[n1, n1, n0, n0]` | `[n0, n0, n1, n1]`         |
| FORAGE_LOOP_HEAD  | `[n0, n1, n0, n1]` | `[n1, n0, n1, n0]`         |
| NO_TURN_BR        | `[n0, n0, n0, n1]` | `[n1, n1, n1, n0]`         |
| TURN_LEFT_BR      | `[n0, n1, n1, n1]` | `[n1, n0, n0, n0]`         |

Six anchors — four MR-shared plus two new in-forage labels. All twelve patterns (anchors + templates) distinct.

- [ ] **Step 2.1: Replace `lib/lenies/codeomes/forager.ex` with the new layout**

Full file content:

```elixir
defmodule Lenies.Codeomes.Forager do
  @moduledoc """
  Wandering herbivore. Each forage iteration: eat, move, then a 3-way
  random branch via `pushN mod 3` — 33% no turn, 33% turn_left, 33%
  turn_right. The direction performs a random walk on {N, E, S, W},
  so the position drifts as a 2D random walk and fills space rather
  than tracing straight lines.

  ## Forage body

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
    eat
    move
    pushN; mod 3                  ; val ∈ {0, 1, 2}
    dup; jz_t NO_TURN_BR          ; pops dup; if val == 0
    push1; sub                    ; val=1 → 0; val=2 → 1
    jz_t TURN_LEFT_BR             ; pops; if was 1
    ; val was 2
    turn_right
    jmp_t FORAGE_LOOP_HEAD

  NO_TURN_BR:
    drop                          ; drop the duplicated 0
    jmp_t FORAGE_LOOP_HEAD

  TURN_LEFT_BR:
    turn_left
    jmp_t FORAGE_LOOP_HEAD
  ```

  ## Anchors

  | Label             | Anchor             | Jump template      |
  |-------------------|--------------------|--------------------|
  | LOOP_HEAD         | [n1, n1, n1, n1]   | [n0, n0, n0, n0]   |
  | COPY_LOOP_HEAD    | [n1, n0, n0, n1]   | [n0, n1, n1, n0]   |
  | ABORT_TARGET      | [n1, n1, n0, n0]   | [n0, n0, n1, n1]   |
  | FORAGE_LOOP_HEAD  | [n0, n1, n0, n1]   | [n1, n0, n1, n0]   |
  | NO_TURN_BR        | [n0, n0, n0, n1]   | [n1, n1, n1, n0]   |
  | TURN_LEFT_BR      | [n0, n1, n1, n1]   | [n1, n0, n0, n0]   |

  The deterministic post-divide `turn_left` (vs MR's random branch)
  drops `TURN_LEFT_ANCHOR` and `SKIP_TURN_ANCHOR`, freeing the
  pattern budget for the two new in-forage anchors.

  ## `pushN mod 3` bias

  `pushN` returns 0..255. 256 mod 3 = 1, so values 0 and 1 appear 86
  times in a perfect sample while value 2 appears 84 times. Relative
  bias ≈ 2.4%. Behaviorally negligible.

  ## Energy

  - Codeome length: 138 opcodes
  - Replication cost ≈ 825 energy
  - Per-iter forage cost ≈ 9.22 energy (average across the 3 paths)
  - Eat gain at default eat_amount=20 ≈ +10.78 per iter
  - Steady state at K=128: E_ss = 2 × 128 × 10.78 - 825 ≈ +1935.

  ## Separators

  Two `:push0` separators sit between a `jmp_t` template (4 nops) and
  the following anchor (4 nops) to prevent the template-extractor from
  reading 8 consecutive nops.
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──────────────────────
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..6: get_size; store slot[0] ────────────────────────────────
    :get_size, :push0, :store,

    # ── pos 7..9: allocate(N) ────────────────────────────────────────────
    :push0, :load, :allocate,

    # ── pos 10..14: jz_t ABORT_TARGET ────────────────────────────────────
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

    # ── pos 15..17: init slot[1] = 0 ─────────────────────────────────────
    :push0, :push1, :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor [n1, n0, n0, n1] ───────────────
    :nop_1, :nop_0, :nop_0, :nop_1,

    # ── pos 22..29: copy body ────────────────────────────────────────────
    :push1, :load, :read_self,
    :push1, :load, :swap, :write_child, :drop,

    # ── pos 30..35: increment slot[1] ────────────────────────────────────
    :push1, :load, :push1, :add, :push1, :store,

    # ── pos 36..40: loop condition ───────────────────────────────────────
    :push0, :load, :push1, :load, :sub,

    # ── pos 41..45: jnz_t COPY_LOOP_HEAD ─────────────────────────────────
    :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

    # ── pos 46: divide ───────────────────────────────────────────────────
    :divide,

    # ── pos 47..50: ABORT_TARGET anchor ──────────────────────────────────
    :nop_1, :nop_1, :nop_0, :nop_0,

    # ── pos 51: deterministic post-divide turn ───────────────────────────
    :turn_left,

    # ── pos 52..65: build K=128 (push1 + 7×(dup,add)) ────────────────────
    :push1, :dup, :add, :dup, :add, :dup, :add,
    :dup, :add, :dup, :add, :dup, :add, :dup, :add,

    # ── pos 66..67: K+1 = 129 ────────────────────────────────────────────
    :push1, :add,

    # ── pos 68..69: store K+1 in slot[0] ─────────────────────────────────
    :push0, :store,

    # ── pos 70..73: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 74..79: decrement slot[0] ────────────────────────────────────
    :push0, :load, :push1, :sub, :push0, :store,

    # ── pos 80..81: load slot[0] for exit check ──────────────────────────
    :push0, :load,

    # ── pos 82..86: jz_t LOOP_HEAD (exit forage) ────────────────────────
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 87..88: forage body — eat, move ──────────────────────────────
    :eat, :move,

    # ── pos 89..95: pushN; build 3; mod (pushN mod 3) ────────────────────
    # pushN [r]; push1 [r,1]; push1 [r,1,1]; push1 [r,1,1,1]; add [r,1,2];
    # add [r,3]; mod [r mod 3].
    :pushN, :push1, :push1, :push1, :add, :add, :mod,

    # ── pos 96: dup the result ───────────────────────────────────────────
    :dup,

    # ── pos 97..101: jz_t NO_TURN_BR (template [n1,n1,n1,n0]) ───────────
    # Pops top dup. If 0 → jump to NO_TURN_BR. Else stack still has [val].
    :jz_t, :nop_1, :nop_1, :nop_1, :nop_0,

    # ── pos 102..103: val - 1 (val was 1 or 2) ───────────────────────────
    :push1, :sub,

    # ── pos 104..108: jz_t TURN_LEFT_BR (template [n1,n0,n0,n0]) ────────
    # Pops top. If 0 (val was 1) → jump. Else (val was 2) fall through.
    :jz_t, :nop_1, :nop_0, :nop_0, :nop_0,

    # ── pos 109: turn_right (val was 2) ──────────────────────────────────
    :turn_right,

    # ── pos 110..114: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 115: separator (prevents 8-consecutive-nop misread) ──────────
    :push0,

    # ── pos 116..119: NO_TURN_BR anchor [n0, n0, n0, n1] ─────────────────
    :nop_0, :nop_0, :nop_0, :nop_1,

    # ── pos 120: drop the duplicated 0 ───────────────────────────────────
    :drop,

    # ── pos 121..125: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 126: separator ───────────────────────────────────────────────
    :push0,

    # ── pos 127..130: TURN_LEFT_BR anchor [n0, n1, n1, n1] ──────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    # ── pos 131: turn_left ───────────────────────────────────────────────
    :turn_left,

    # ── pos 132..136: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 137: separator (final wrap protection) ───────────────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
```

- [ ] **Step 2.2: Sanity-check the opcode count**

```bash
mix run -e 'IO.inspect(length(Lenies.Codeomes.Forager.opcodes()))'
```

Expected: `138`

- [ ] **Step 2.3: Run the Forager test**

```bash
mix test test/lenies/codeomes/forager_test.exs
```

Expected: 1 test passes.

- [ ] **Step 2.4: Run the full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 2.5: Commit**

```bash
git add lib/lenies/codeomes/forager.ex
git commit -m "feat(forager): 3-way random walk (33% no-turn / 33% L / 33% R)

Drops the 'sense + 5-empties trigger' logic (which almost never
fired in a resource-rich world) for an unconditional per-step
3-way random branch via pushN mod 3. The direction does a random
walk on cardinal directions; position drifts as a 2D random walk
that fills space instead of tracing straight lines.

Visual signature: chaotic walk with no long straight runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Rewrite Hunter

**Goal**: K=96, L/R alternation via slot[3] parity (diagonal staircase advance), `sense_front` + `attack`-and-lock-on when prey detected. ~155 opcodes.

**Why this design**: Slot[3] parity gives deterministic L/R alternation → Hunter advances diagonally (each step rotates the facing by ±90°). The L/R alternation gives a wider effective scan than straight-line walk (Hunter touches both x and y axes). When `sense_front` returns -1 (Lenie ahead), the LENIE_HANDLER path attacks WITHOUT moving or turning — same direction next iteration, so if prey is still there, attack again. Lock-on amplifies kill probability without complex pursuit logic.

**Files:**
- Modify: `lib/lenies/codeomes/hunter.ex` (full rewrite)
- Modify: `test/lenies/codeomes/hunter_test.exs` (add prey-damage test)

### Anchor table

| Label             | Anchor pattern   | Jump template (complement) |
|-------------------|------------------|----------------------------|
| LOOP_HEAD         | `[n1, n1, n1, n1]` | `[n0, n0, n0, n0]`         |
| COPY_LOOP_HEAD    | `[n1, n0, n0, n1]` | `[n0, n1, n1, n0]`         |
| ABORT_TARGET      | `[n1, n1, n0, n0]` | `[n0, n0, n1, n1]`         |
| FORAGE_LOOP_HEAD  | `[n0, n1, n0, n1]` | `[n1, n0, n1, n0]`         |
| LENIE_HANDLER     | `[n0, n0, n0, n1]` | `[n1, n1, n1, n0]`         |
| TURN_LEFT_BR      | `[n0, n1, n1, n1]` | `[n1, n0, n0, n0]`         |

- [ ] **Step 3.1: Replace `lib/lenies/codeomes/hunter.ex` with the new layout**

Full file content:

```elixir
defmodule Lenies.Codeomes.Hunter do
  @moduledoc """
  Predator with a diagonal staircase advance and lock-on attack.

  Each forage iteration:
  - `sense_front`. If -1 (Lenie ahead), jump to LENIE_HANDLER → attack
    once, do NOT move, do NOT turn. Next iteration faces the same cell;
    if prey is still there, attack again. This "lock-on" amplifies kill
    probability without explicit pursuit logic.
  - Otherwise, `eat` + `move`, then alternate `turn_left`/`turn_right`
    via slot[3] parity. The alternation produces a deterministic
    diagonal staircase advance (face east → step east → turn south →
    step south → turn east → step east → …) covering both axes.

  The diagonal advance is the visual signature that distinguishes
  Hunter from MR/Carnivore (cardinal-direction straight runs) and from
  Forager (random walk).

  ## Forage body

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
    sense_front; push1; add        ; value+1: 0 iff was -1 (lenie)
    jz_t LENIE_HANDLER             ; pops; if was -1
    eat; move
    ; alternate L/R via slot[3] parity
    load slot[3]; push1; add        ; counter+1
    dup
    push 2; mod                    ; (counter+1) mod 2
    jz_t TURN_LEFT_BR              ; pops; if 0
    turn_right
    store slot[3] := counter+1
    jmp_t FORAGE_LOOP_HEAD

  LENIE_HANDLER:
    attack
    jmp_t FORAGE_LOOP_HEAD         ; no move/turn — lock on

  TURN_LEFT_BR:
    turn_left
    store slot[3] := counter+1
    jmp_t FORAGE_LOOP_HEAD
  ```

  ## Anchors

  | Label             | Anchor             | Jump template      |
  |-------------------|--------------------|--------------------|
  | LOOP_HEAD         | [n1, n1, n1, n1]   | [n0, n0, n0, n0]   |
  | COPY_LOOP_HEAD    | [n1, n0, n0, n1]   | [n0, n1, n1, n0]   |
  | ABORT_TARGET      | [n1, n1, n0, n0]   | [n0, n0, n1, n1]   |
  | FORAGE_LOOP_HEAD  | [n0, n1, n0, n1]   | [n1, n0, n1, n0]   |
  | LENIE_HANDLER     | [n0, n0, n0, n1]   | [n1, n1, n1, n0]   |
  | TURN_LEFT_BR      | [n0, n1, n1, n1]   | [n1, n0, n0, n0]   |

  ## Energy

  - Codeome length: ~155 opcodes
  - Replication cost ≈ 924 energy
  - Per-iter normal-path cost ≈ 12.4 energy
  - Eat gain at default eat_amount=20 ≈ +7.6 per iter
  - Steady state at K=96: E_ss = 2 × 96 × 7.6 - 924 ≈ +535.
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──────────────────────
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..6: get_size; store slot[0] ────────────────────────────────
    :get_size, :push0, :store,

    # ── pos 7..9: allocate(N) ────────────────────────────────────────────
    :push0, :load, :allocate,

    # ── pos 10..14: jz_t ABORT_TARGET ────────────────────────────────────
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

    # ── pos 15..17: init slot[1] = 0 ─────────────────────────────────────
    :push0, :push1, :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor [n1, n0, n0, n1] ───────────────
    :nop_1, :nop_0, :nop_0, :nop_1,

    # ── pos 22..29: copy body ────────────────────────────────────────────
    :push1, :load, :read_self,
    :push1, :load, :swap, :write_child, :drop,

    # ── pos 30..35: increment slot[1] ────────────────────────────────────
    :push1, :load, :push1, :add, :push1, :store,

    # ── pos 36..40: loop condition ───────────────────────────────────────
    :push0, :load, :push1, :load, :sub,

    # ── pos 41..45: jnz_t COPY_LOOP_HEAD ─────────────────────────────────
    :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

    # ── pos 46: divide ───────────────────────────────────────────────────
    :divide,

    # ── pos 47..50: ABORT_TARGET anchor ──────────────────────────────────
    :nop_1, :nop_1, :nop_0, :nop_0,

    # ── pos 51: deterministic post-divide turn ───────────────────────────
    :turn_left,

    # ── pos 52..66: build K=96 = 32 + 64 ────────────────────────────────
    # Phase 1 (pos 52..62, 11 ops): push1 + 5×(dup, add) = 32 on stack.
    # Phase 2 (pos 63..66, 4 ops): dup [32,32]; dup [32,32,32]; add → [32,64];
    # add → [96].
    :push1, :dup, :add, :dup, :add, :dup, :add, :dup, :add, :dup, :add,
    :dup, :dup, :add, :add,

    # ── pos 67..68: K+1 = 97 ─────────────────────────────────────────────
    :push1, :add,

    # ── pos 69..70: store K+1 in slot[0] ─────────────────────────────────
    :push0, :store,

    # ── pos 71..77: init slot[3] := 0 ────────────────────────────────────
    # push0 [0]; push1+push1+push1 [0,1,1,1]; add [0,1,2]; add [0,3];
    # store → slot[3] := 0. (7 ops, two adds to build slot idx 3.)
    :push0, :push1, :push1, :push1, :add, :add, :store,

    # ── pos 78..81: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 82..87: decrement slot[0] ────────────────────────────────────
    :push0, :load, :push1, :sub, :push0, :store,

    # ── pos 88..89: load slot[0] for exit check ──────────────────────────
    :push0, :load,

    # ── pos 90..94: jz_t LOOP_HEAD (exit forage) ────────────────────────
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 95..97: sense_front; push1; add — value+1 ────────────────────
    :sense_front, :push1, :add,

    # ── pos 98..102: jz_t LENIE_HANDLER (template [n1,n1,n1,n0]) ────────
    # Pops the value+1. If was -1 (now 0) → jump.
    :jz_t, :nop_1, :nop_1, :nop_1, :nop_0,

    # ── pos 103..104: not prey — eat, move ───────────────────────────────
    :eat, :move,

    # ── pos 105..110: build slot idx 3 and load slot[3] ──────────────────
    # push1 [1]; push1 [1,1]; push1 [1,1,1]; add [1,2]; add [3]; load [slot[3]]
    :push1, :push1, :push1, :add, :add, :load,

    # ── pos 111..112: counter + 1 ────────────────────────────────────────
    :push1, :add,

    # ── pos 113: dup (we need the value both for parity check and to store) ─
    :dup,

    # ── pos 114..116: build 2 on stack ───────────────────────────────────
    # push1 [c+1, c+1, 1]; push1 [c+1, c+1, 1, 1]; add [c+1, c+1, 2]
    :push1, :push1, :add,

    # ── pos 117: mod — (counter+1) mod 2 ─────────────────────────────────
    :mod,

    # ── pos 118..122: jz_t TURN_LEFT_BR (template [n1,n0,n0,n0]) ────────
    # Pops the mod result. If 0 → jump to TURN_LEFT_BR.
    :jz_t, :nop_1, :nop_0, :nop_0, :nop_0,

    # ── pos 123: turn_right (mod was 1) ──────────────────────────────────
    :turn_right,

    # ── pos 124..129: store counter+1 → slot[3] ──────────────────────────
    # Stack here has [counter+1]. Build slot idx 3 and store.
    :push1, :push1, :push1, :add, :add, :store,

    # ── pos 130..134: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 135: separator (prevents 8-nop misread) ──────────────────────
    :push0,

    # ── pos 136..139: LENIE_HANDLER anchor [n0, n0, n0, n1] ─────────────
    :nop_0, :nop_0, :nop_0, :nop_1,

    # ── pos 140: attack (no move, no turn — lock on) ─────────────────────
    :attack,

    # ── pos 141..145: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 146: separator ───────────────────────────────────────────────
    :push0,

    # ── pos 147..150: TURN_LEFT_BR anchor [n0, n1, n1, n1] ──────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    # ── pos 151: turn_left ───────────────────────────────────────────────
    :turn_left,

    # ── pos 152..157: store counter+1 → slot[3] ──────────────────────────
    :push1, :push1, :push1, :add, :add, :store,

    # ── pos 158..162: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 163: separator (final wrap protection) ───────────────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
```

**Stack trace for K=96 build** (positions 52..66, 15 opcodes):
- pos 52..62 (push1 + 5×(dup,add)): stack goes `[1] → [2] → [4] → [8] → [16] → [32]`
- pos 63 (dup): `[32, 32]`
- pos 64 (dup): `[32, 32, 32]`
- pos 65 (add): `[32, 64]` (top two summed)
- pos 66 (add): `[96]`

Same total opcode count as K=128 (15 ops) — no efficiency cost for matching the spec's K=96.

- [ ] **Step 3.2: Sanity-check the opcode count**

```bash
mix run -e 'IO.inspect(length(Lenies.Codeomes.Hunter.opcodes()))'
```

Expected: `164`

Position numbers in the source comments don't affect runtime (they're documentation only). If your final count differs by a few, it's likely a transcription difference — what matters is that the opcode sequence is correct, not the numeric labels in the comments.

- [ ] **Step 3.3: Run the existing Hunter test**

```bash
mix test test/lenies/codeomes/hunter_test.exs
```

Expected: 1 test passes (existing gen-≥-3 test).

- [ ] **Step 3.4: Add a prey-damage test to `test/lenies/codeomes/hunter_test.exs`**

Append the following test inside the `defmodule Lenies.Codeomes.HunterTest do ... end` block, after the existing test but before the `defp max_generation` helpers:

```elixir
  test "hunter damages a stationary prey directly in front within 10 seconds" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    # Fill the grid with resource so Hunter has energy to advance.
    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(:cells, {x, y})
      :ets.insert(:cells, {key, %{cell | resource: 200}})
    end

    # Place Hunter at (128, 128) facing east; prey at (129, 128).
    [{key_h, cell_h}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key_h, %{cell_h | lenie_id: "HUN-ORIGIN"}})

    [{key_p, cell_p}] = :ets.lookup(:cells, {129, 128})
    :ets.insert(:cells, {key_p, %{cell_p | lenie_id: "PREY"}})

    {:ok, hunter_pid} =
      Lenie.start_link(
        id: "HUN-ORIGIN",
        codeome: Hunter.codeome(),
        energy: 10_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0}
      )

    # The prey is a Minimal Replicator — it will try to move, but as long
    # as Hunter is one step away, sense_front will report `-1` on Hunter's
    # next iter and the attack will land at least once.
    {:ok, prey_pid} =
      Lenie.start_link(
        id: "PREY",
        codeome: Lenies.Codeomes.MinimalReplicator.codeome(),
        energy: 5_000.0,
        pos: {129, 128},
        dir: :w,
        lineage: {nil, 0}
      )

    Process.unlink(hunter_pid)
    Process.unlink(prey_pid)

    deadline = System.monotonic_time(:millisecond) + 10_000

    damaged = poll_until(deadline, fn ->
      case :ets.lookup(:lenies, "PREY") do
        [{_, %{energy: e}}] when e < 5_000.0 -> {:done, true}
        _ -> :continue
      end
    end)

    assert damaged == true,
           "expected prey energy to drop below 5_000 within 10s — Hunter never landed an attack"
  end
```

Note: This test reuses the existing `poll_until` helper and the same `setup do ... end` block. The helper's return value when the deadline is reached is `max_generation(snaps)` (an integer) — for our true/false poll, when the poll succeeds before the deadline, `poll_until` returns `true`; when the deadline elapses without a hit, it returns the integer max-gen value. The assert checks `== true`, so a timeout returns the integer and fails the assert with a clear message.

- [ ] **Step 3.5: Run the new Hunter test**

```bash
mix test test/lenies/codeomes/hunter_test.exs
```

Expected: 2 tests pass.

If the new prey-damage test fails: most likely cause is the lock-on logic not firing — verify the LENIE_HANDLER anchor pattern and the `:jz_t` template for it. The pattern at pos 98..102 must be `:jz_t, :nop_1, :nop_1, :nop_1, :nop_0` (template `[n1,n1,n1,n0]`, which is the bitwise complement of `LENIE_HANDLER` anchor `[n0,n0,n0,n1]`).

- [ ] **Step 3.6: Run the full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 3.7: Commit**

```bash
git add lib/lenies/codeomes/hunter.ex test/lenies/codeomes/hunter_test.exs
git commit -m "feat(hunter): diagonal staircase advance + lock-on attack

Replaces the straight-line walk + 8-iter 360° sweep (which never
actually changed direction and rarely landed on moving prey) with:

- L/R alternation via slot[3] parity each step → diagonal staircase
  advance instead of straight line, covering both axes
- Lock-on attack: on sense_front == -1, attack without moving or
  turning → next iter faces same cell, so consecutive attacks land
  on the same prey until it dies or moves

New prey-damage test verifies the lock-on works.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Update README descriptions

**Goal**: Replace the existing Defender / Hunter / Forager bullets in README.md to describe the new behaviors accurately.

**Files:**
- Modify: `README.md` lines 206-221

- [ ] **Step 4.1: Update the three bullets in README**

Replace lines 206-221 of `README.md` with:

```markdown
- **Defender** — defensive herbivore that builds tight clusters. K=32
  forage budget (vs MR's 128) means it replicates every ~32 cells; the
  deterministic post-divide `turn_left` spirals descendants outward into
  a fractal pattern. Forage body is `defend; eat; move` — each iteration
  applies the defense flag, so attackers pay the defense penalty for
  every hit on a Defender. Source:
  [lib/lenies/codeomes/defender.ex](lib/lenies/codeomes/defender.ex).
- **Hunter** — predator with a diagonal staircase advance and a lock-on
  attack. Each forage step alternates `turn_left` / `turn_right` via a
  slot[3] parity counter, producing a diagonal walk that covers both
  axes. When `sense_front` returns `-1` (Lenie ahead), the Hunter
  attacks without moving or turning — next iteration faces the same
  cell, so consecutive attacks land on the same prey until it dies or
  moves. Source:
  [lib/lenies/codeomes/hunter.ex](lib/lenies/codeomes/hunter.ex).
- **Forager** — wandering herbivore. Each step: `eat`, `move`, then a
  3-way random branch via `pushN mod 3` — 33% no turn, 33% `turn_left`,
  33% `turn_right`. The direction performs a random walk on cardinal
  directions; the position drifts as a 2D random walk that fills space
  rather than tracing straight lines. Source:
  [lib/lenies/codeomes/forager.ex](lib/lenies/codeomes/forager.ex).
```

- [ ] **Step 4.2: Commit**

```bash
git add README.md
git commit -m "docs(readme): describe Defender/Hunter/Forager new behaviors

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Verify in browser (manual)

The codeome rewrites change the species fingerprint (codeome hash), so previous saved sessions / custom seeds referencing the old hashes won't visually match. Run a fresh dashboard session and verify by eye:

- [ ] **Step 5.1: Boot the dev server and inspect**

```bash
cd /home/patrick/projects/playground/Lenies && iex -S mix phx.server
```

Open the dashboard, seed one Defender / Hunter / Forager each into a paused world, then resume. Watch for:

- **Defender**: dense cluster forming at the seed point, not spreading far
- **Hunter**: diagonal NE/NW/SE/SW lines (not cardinal lines like MR/Carnivore)
- **Forager**: chaotic walk with no long straight runs, position drifts in 2D

If the visual doesn't match, the codeome compiled but a jump is landing in the wrong place — diff the new file against the plan above and look for transposed anchor patterns.

---

## Risk notes

- **Hunter codeome size approximate**: ~164 opcodes (plan estimate). The energy math has margin (E_ss ≈ +535 at K=96), but if the actual count is much larger, replication cost rises proportionally. If Hunter starves at K=96, raising K is the lever — but the user explicitly approved K=96.
- **No isolated unit test for the L/R alternation pattern in Hunter**. The diagonal-staircase movement is verified visually (Task 5.1). If desired, a future improvement is to spawn one Hunter alone in an empty grid and assert that after N ticks, `position.x ≠ start_x AND position.y ≠ start_y` (i.e., it moved on both axes). Out of scope here to keep test runtime low.
- **`pushN mod 3` bias** is ~2.4% (256 not divisible by 3). Behaviorally negligible. Documented in the Forager moduledoc for future readers.
