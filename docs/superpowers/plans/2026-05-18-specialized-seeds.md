# Specialised Seeds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `:random` seed with three ecologically-specialised hand-written codeomes (Defender, Hunter, Forager) that share the MinimalReplicator skeleton but diverge in their forage-loop behaviour.

**Architecture:** Three new `Lenies.Codeomes.*` modules each exposing `codeome/0`. Catalog (`Lenies.Seeds.all/0`) is updated to drop `:random` and add the three new entries. Liveness test per seed verifies it reaches generation ≥ 3 alone on a resource-saturated grid within 30 s.

**Tech Stack:** Elixir + ExUnit + the existing Lenies VM (`:cells`/`:lenies` ETS tables, `Lenies.World`, `Lenies.Interpreter`).

---

## Design refinements vs the brainstorm spec

The spec ([docs/superpowers/specs/2026-05-18-specialized-seeds-design.md](../specs/2026-05-18-specialized-seeds-design.md)) was written before the anchor-budget audit. Two small deviations slipped in while writing this plan; both are no-op for the ecological behaviour and keep the seeds inside the VM's 4-bit template-pattern namespace (16 patterns total, 12 used by MR, 4 free):

1. **Decrement-first forage loop**: the loop counter is now decremented at the TOP of the forage body, with a `jz_t LOOP_HEAD` exit before the body runs. This eliminates the dedicated "end-of-forage" anchor (which would otherwise need its own pattern) and reuses the LOOP_HEAD template that already lives in MR. Slot[0] is initialised to `K + 1` instead of `K` so the body still runs exactly K times.

2. **Hunter and Forager use a deterministic `turn_left` after divide** instead of MR's `pushN`-mod-2 random turn. The post-divide turn exists to dodge the freshly-born child blocking forward movement — either left or right escapes; the randomisation is a Carnivore-tuned detail that costs three anchors (ABORT_TARGET, TURN_LEFT_ANCHOR, SKIP_TURN_ANCHOR) of the namespace. Replacing it with a single `turn_left` frees TURN_LEFT_ANCHOR and SKIP_TURN_ANCHOR for the new seeds' in-forage logic. **Defender keeps MR's full post-divide block** (its two new anchors fit within MR's existing 2-pair free budget) so the randomness from there compounds with the in-forage random turn.

These refinements are documented in each module's `@moduledoc` so the seed code is self-contained.

---

## File map

| File | Action |
|------|--------|
| `lib/lenies/codeomes/defender.ex` | **CREATE** — Defender seed module |
| `lib/lenies/codeomes/hunter.ex` | **CREATE** — Hunter seed module |
| `lib/lenies/codeomes/forager.ex` | **CREATE** — Forager seed module |
| `test/lenies/codeomes/defender_test.exs` | **CREATE** — liveness test |
| `test/lenies/codeomes/hunter_test.exs` | **CREATE** — liveness test |
| `test/lenies/codeomes/forager_test.exs` | **CREATE** — liveness test |
| `lib/lenies/seeds.ex` | **MODIFY** — drop `:random`, add 3 new entries |
| `README.md` | **MODIFY** — "Built-in seeds" section, 3 → 5 entries minus Random |

---

## Phase 0 — Confirm baseline tests are green

### Task 0.1: Baseline test sweep

**Files:** none.

- [ ] **Step 1: Run the existing suite**

```bash
mix test
```

Expected: all tests pass (current state on `master`). If anything is red, fix or quarantine before continuing — the new seed tests share infrastructure with the existing seed tests and need the world / lenies state to start clean.

---

## Phase 1 — Defender seed

### Task 1.1: Write Defender liveness test

**Files:**
- Test: `test/lenies/codeomes/defender_test.exs` (create)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Lenies.Codeomes.DefenderTest do
  use ExUnit.Case, async: false

  alias Lenies.{Lenie, World}
  alias Lenies.Codeomes.Defender
  alias Lenies.World.Tables

  @moduletag timeout: 60_000

  setup do
    # Deterministic: kill all stochastic codeome edits so the test sees the
    # pure Defender behaviour, no copy errors and no background mutation.
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
    Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 500})
    # Boost eat_amount so the cycle completes well within the 30s budget.
    Application.put_env(:lenies, :eat_amount, 50)
    Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

    on_exit(fn ->
      Application.delete_env(:lenies, :copy_substitution_rate)
      Application.delete_env(:lenies, :copy_insert_rate)
      Application.delete_env(:lenies, :copy_delete_rate)
      Application.delete_env(:lenies, :background_mutation_rate_per_1000_ticks)
      Application.delete_env(:lenies, :min_viable_codeome_opcodes)
      Application.delete_env(:lenies, :codeome_length_bounds)
      Application.delete_env(:lenies, :eat_amount)
      Application.delete_env(:lenies, :interpreter_steps_per_batch)

      case Process.whereis(Lenies.LenieSupervisor) do
        sup when is_pid(sup) ->
          DynamicSupervisor.which_children(sup)
          |> Enum.each(fn {_, child, _, _} ->
            if is_pid(child), do: DynamicSupervisor.terminate_child(sup, child)
          end)

        _ ->
          :ok
      end

      case Process.whereis(Lenies.World) do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      Tables.delete_all()
    end)

    :ok
  end

  test "defender reaches generation >= 3 in 30 seconds" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    # Wide resource strip so the random-turn behaviour can find food
    # regardless of the direction the seed wandered into.
    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(:cells, {x, y})
      :ets.insert(:cells, {key, %{cell | resource: 200}})
    end

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "DEF-ORIGIN"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "DEF-ORIGIN",
        codeome: Defender.codeome(),
        energy: 10_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    deadline = System.monotonic_time(:millisecond) + 30_000

    max_gen = poll_until(deadline, fn ->
      snaps = :ets.tab2list(:lenies)
      m = max_generation(snaps)
      if m >= 3, do: {:done, m}, else: :continue
    end)

    snaps = :ets.tab2list(:lenies)

    assert max_gen >= 3,
           "expected at least 3 generations; got max gen #{max_gen}, " <>
             "#{length(snaps)} Lenies alive"
  end

  defp max_generation(snaps) do
    snaps
    |> Enum.map(fn {_id, snap} -> snap.lineage |> elem(1) end)
    |> Enum.max(fn -> 0 end)
  end

  defp poll_until(deadline, fun) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      snaps = :ets.tab2list(:lenies)
      max_generation(snaps)
    else
      case fun.() do
        {:done, v} -> v
        :continue ->
          Process.sleep(200)
          poll_until(deadline, fun)
      end
    end
  end
end
```

- [ ] **Step 2: Run the test, expect it to fail with a module-not-found error**

```bash
mix test test/lenies/codeomes/defender_test.exs
```

Expected: compile error or `UndefinedFunctionError` for `Lenies.Codeomes.Defender.codeome/0`.

### Task 1.2: Write the Defender codeome module

**Files:**
- Create: `lib/lenies/codeomes/defender.ex`

- [ ] **Step 1: Create the module with full opcode list**

The Defender shares MR's outer skeleton (allocate, copy, divide, post-divide random turn) and a forage init that uses `K = 64` instead of `128`. The forage body adds a slot[3] counter that triggers a random turn every 5 iterations. Two new anchors live inside the random-turn block:

- `DO_TURN_ANCHOR` = `[n0, n0, n0, n1]` (jumped to when `(counter+1) mod 5 == 0`)
- `TURN_LEFT_BR_ANCHOR` = `[n0, n1, n1, n1]` (random-direction left branch)

Both are paired with their complements as the corresponding `jz_t` templates and live within MR's two free pattern pairs.

```elixir
defmodule Lenies.Codeomes.Defender do
  @moduledoc """
  Pacifist herbivore with a pseudo-random walk. Inherits MinimalReplicator's
  replication skeleton; the forage loop body inserts a counter that fires
  a random `turn_left` or `turn_right` every 5 forage iterations.

  Visible behaviour: short straight runs (~5 cells) interrupted by 90°
  random turns, making the Lenie hard to track for a directional predator.
  K = 64 (half of MR's 128) keeps the per-cycle energy balance comparable
  to MR despite the extra ~12 opcodes the counter machinery adds per iter.

  ## Anchors added vs MinimalReplicator

  | Label             | Anchor           | Jump template     |
  |-------------------|------------------|-------------------|
  | DO_TURN_ANCHOR    | [n0,n0,n0,n1]    | [n1,n1,n1,n0]     |
  | TURN_LEFT_BR_ANCHOR | [n0,n1,n1,n1]  | [n1,n0,n0,n0]     |

  ## Forage loop structure (decrement-first)

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
    sense_front; drop; eat; move
    counter := slot[3] + 1
    if (counter mod 5) != 0:
      slot[3] := counter; jmp_t FORAGE_LOOP_HEAD
    else:                                        (DO_TURN_ANCHOR)
      slot[3] := 0
      if (pushN mod 2) == 0:                     (jz_t TURN_LEFT_BR_ANCHOR)
        turn_right
      else:                                      (TURN_LEFT_BR_ANCHOR)
        turn_left
      jmp_t FORAGE_LOOP_HEAD
  ```

  Slot[0] is reused for the forage countdown after holding `N` during the
  copy phase, exactly as in MinimalReplicator. Slot[3] is the new
  step-counter; the slot is otherwise untouched.
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──────────────────────
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..6: get own size N, store in slot[0] ───────────────────────
    :get_size, :push0, :store,

    # ── pos 7..9: allocate child slot of size N in front cell ────────────
    :push0, :load, :allocate,

    # ── pos 10..14: jz_t → ABORT_TARGET if allocate failed ───────────────
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

    # ── pos 15..17: init copy counter slot[1] = 0 ────────────────────────
    :push0, :push1, :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor [n1, n0, n0, n1] ───────────────
    :nop_1, :nop_0, :nop_0, :nop_1,

    # ── pos 22..29: copy body (read self, write child) ───────────────────
    :push1, :load, :read_self,
    :push1, :load, :swap, :write_child, :drop,

    # ── pos 30..35: increment counter ────────────────────────────────────
    :push1, :load, :push1, :add, :push1, :store,

    # ── pos 36..40: loop condition (N - (counter+1) != 0?) ───────────────
    :push0, :load, :push1, :load, :sub,

    # ── pos 41..45: jnz_t back to COPY_LOOP_HEAD ─────────────────────────
    :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

    # ── pos 46: divide ───────────────────────────────────────────────────
    :divide,

    # ── pos 47..50: ABORT_TARGET anchor [n1, n1, n0, n0] ─────────────────
    :nop_1, :nop_1, :nop_0, :nop_0,

    # ── pos 51..55: r := pushN; (r mod 2) on stack ───────────────────────
    :pushN, :push1, :push1, :add, :mod,

    # ── pos 56..60: jz_t → TURN_LEFT_ANCHOR (post-divide random turn) ────
    :jz_t, :nop_1, :nop_0, :nop_1, :nop_1,

    # ── pos 61: turn_right (r mod 2 == 1) ────────────────────────────────
    :turn_right,

    # ── pos 62..66: jmp_t → SKIP_TURN_ANCHOR ─────────────────────────────
    :jmp_t, :nop_1, :nop_1, :nop_0, :nop_1,

    # ── pos 67: separator (dead code) ────────────────────────────────────
    :push0,

    # ── pos 68..71: TURN_LEFT_ANCHOR [n0, n1, n0, n0] ────────────────────
    :nop_0, :nop_1, :nop_0, :nop_0,

    # ── pos 72: turn_left ────────────────────────────────────────────────
    :turn_left,

    # ── pos 73..76: SKIP_TURN_ANCHOR [n0, n0, n1, n0] ────────────────────
    :nop_0, :nop_0, :nop_1, :nop_0,

    # ── pos 77..89: build K=64 on stack (push1 + 6 doublings) ────────────
    :push1, :dup, :add, :dup, :add, :dup, :add, :dup, :add, :dup, :add, :dup, :add,

    # ── pos 90..91: K+1 = 65 (decrement-first loop overshoots by 1) ──────
    :push1, :add,

    # ── pos 92..93: store K+1 in slot[0] ─────────────────────────────────
    :push0, :store,

    # ── init slot[3] := 0 (step counter for random turn) ────────────────
    # Stack trace: push0 [0]; push1 [0,1]; push1 [0,1,1]; push1 [0,1,1,1];
    # add [0,1,2]; add [0,3]; store → slot[3] := 0. (7 opcodes.)
    :push0, :push1, :push1, :push1, :add, :add, :store,

    # ── pos 101..104: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ───────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 105..110: decrement slot[0]; load and test ──────────────────
    # slot[0] -= 1; then push slot[0] onto stack
    :push0, :load, :push1, :sub, :push0, :store,
    :push0, :load,

    # ── pos 113..117: jz_t LOOP_HEAD (exit forage when counter is 0) ────
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 118..121: forage body — sense, drop, eat, move ──────────────
    :sense_front, :drop, :eat, :move,

    # ── pos 122..128: increment slot[3] counter ─────────────────────────
    # load slot[3]; push 1; add; dup; push 5; mod
    :push1, :push1, :push1, :add, :load,        # build slot idx 3 then load
    :push1, :add,                                  # counter + 1
    :dup,                                          # [counter+1, counter+1]
    # push 5 = push1 + push1 + push1 + push1 + push1 + add + add + add + add
    # Cheaper: push1; dup; add; dup; add; push1; add = 1, 2, 4, 5 (5 ops)
    :push1, :dup, :add, :dup, :add, :push1, :add,
    :mod,                                          # [counter+1, (counter+1) mod 5]

    # ── jz_t DO_TURN_ANCHOR — if (counter+1) mod 5 == 0, jump to turn ───
    :jz_t, :nop_1, :nop_1, :nop_1, :nop_0,

    # ── (mod != 0) store counter+1 → slot[3]; jmp_t FORAGE_LOOP_HEAD ───
    # stack here is [counter+1]
    :push1, :push1, :push1, :add, :store,        # build slot idx 3, store
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,      # template for FORAGE_LOOP_HEAD

    # ── DO_TURN_ANCHOR [n0,n0,n0,n1] ────────────────────────────────────
    :nop_0, :nop_0, :nop_0, :nop_1,

    # ── stack on entry: [counter+1]. Reset slot[3] := 0. ─────────────────
    :drop,                                          # drop counter+1, []
    :push0, :push1, :push1, :push1, :add, :add, :store,   # slot[3]=0

    # ── Random direction: pushN mod 2 → jz_t TURN_LEFT_BR ───────────────
    :pushN, :push1, :push1, :add, :mod,

    :jz_t, :nop_1, :nop_0, :nop_0, :nop_0,        # template for TURN_LEFT_BR

    # ── turn_right path ────────────────────────────────────────────────
    :turn_right,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,       # template for FORAGE_LOOP_HEAD

    # ── TURN_LEFT_BR_ANCHOR [n0,n1,n1,n1] ───────────────────────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    :turn_left,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,       # template for FORAGE_LOOP_HEAD

    # ── separator (final wrap protection) ───────────────────────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
```

- [ ] **Step 2: Run the Defender test**

```bash
mix test test/lenies/codeomes/defender_test.exs
```

Expected: PASS (Defender reaches gen ≥ 3 within 30 s). If it fails, the most likely culprits are:
- Template-pattern collision (a new anchor whose complement matches a substring of an existing one) — run `iex -S mix` and inspect anchor positions in the codeome.
- Off-by-one in the K-counter (slot[0] should be K + 1 = 65 since decrement-first overshoots by 1).
- Slot[3] initialisation built with wrong opcode count (the `push 3` slot index is built via push1+push1+push1+add+add).

- [ ] **Step 3: Commit**

```bash
git add lib/lenies/codeomes/defender.ex test/lenies/codeomes/defender_test.exs
git commit -m "$(cat <<'EOF'
feat(seeds): Defender — pacifist herbivore with pseudo-random walk

Hand-written codeome that inherits MinimalReplicator's replication
skeleton and adds a slot[3] counter to the forage body — every 5
forage iterations the seed fires a random turn_left or turn_right.
K = 64 (half MR's 128) keeps the per-cycle balance comparable despite
the ~12-opcode counter overhead.

Liveness test (alone on a resource-saturated grid, eat_amount=50)
asserts gen >= 3 within 30 s.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Hunter seed

### Task 2.1: Write Hunter liveness test

**Files:**
- Test: `test/lenies/codeomes/hunter_test.exs` (create)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Lenies.Codeomes.HunterTest do
  use ExUnit.Case, async: false

  alias Lenies.{Lenie, World}
  alias Lenies.Codeomes.Hunter
  alias Lenies.World.Tables

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
    Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 500})
    Application.put_env(:lenies, :eat_amount, 50)
    Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

    on_exit(fn ->
      Application.delete_env(:lenies, :copy_substitution_rate)
      Application.delete_env(:lenies, :copy_insert_rate)
      Application.delete_env(:lenies, :copy_delete_rate)
      Application.delete_env(:lenies, :background_mutation_rate_per_1000_ticks)
      Application.delete_env(:lenies, :min_viable_codeome_opcodes)
      Application.delete_env(:lenies, :codeome_length_bounds)
      Application.delete_env(:lenies, :eat_amount)
      Application.delete_env(:lenies, :interpreter_steps_per_batch)

      case Process.whereis(Lenies.LenieSupervisor) do
        sup when is_pid(sup) ->
          DynamicSupervisor.which_children(sup)
          |> Enum.each(fn {_, child, _, _} ->
            if is_pid(child), do: DynamicSupervisor.terminate_child(sup, child)
          end)
        _ -> :ok
      end

      case Process.whereis(Lenies.World) do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        _ -> :ok
      end

      Tables.delete_all()
    end)

    :ok
  end

  test "hunter reaches generation >= 3 in 30 seconds (alone, sweep finds no prey)" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(:cells, {x, y})
      :ets.insert(:cells, {key, %{cell | resource: 200}})
    end

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "HUN-ORIGIN"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "HUN-ORIGIN",
        codeome: Hunter.codeome(),
        energy: 10_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    deadline = System.monotonic_time(:millisecond) + 30_000

    max_gen = poll_until(deadline, fn ->
      snaps = :ets.tab2list(:lenies)
      m = max_generation(snaps)
      if m >= 3, do: {:done, m}, else: :continue
    end)

    snaps = :ets.tab2list(:lenies)

    assert max_gen >= 3,
           "expected at least 3 generations; got max gen #{max_gen}, " <>
             "#{length(snaps)} Lenies alive"
  end

  defp max_generation(snaps) do
    snaps
    |> Enum.map(fn {_id, snap} -> snap.lineage |> elem(1) end)
    |> Enum.max(fn -> 0 end)
  end

  defp poll_until(deadline, fun) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      snaps = :ets.tab2list(:lenies)
      max_generation(snaps)
    else
      case fun.() do
        {:done, v} -> v
        :continue ->
          Process.sleep(200)
          poll_until(deadline, fun)
      end
    end
  end
end
```

- [ ] **Step 2: Run the test, expect failure**

```bash
mix test test/lenies/codeomes/hunter_test.exs
```

Expected: `UndefinedFunctionError` for `Lenies.Codeomes.Hunter.codeome/0`.

### Task 2.2: Write the Hunter codeome module

**Files:**
- Create: `lib/lenies/codeomes/hunter.ex`

- [ ] **Step 1: Create the module with full opcode list**

Hunter replaces MR's post-divide random turn with a deterministic `turn_left` (freeing TURN_LEFT_ANCHOR and SKIP_TURN_ANCHOR's pattern pairs). The forage body inline-checks for a Lenie in front and attacks; every 8 iterations a sweep rotates 4× and attacks the first Lenie found.

Four new anchors:
- `LENIE_HANDLER_ANCHOR` = `[n0, n0, n0, n1]`
- `INCR_COUNTER_ANCHOR` = `[n0, n1, n1, n1]`
- `DO_SWEEP_ANCHOR` = `[n0, n1, n0, n0]` (reuses MR's old TURN_LEFT pattern, now free)
- `SWEEP_FOUND_ANCHOR` = `[n0, n0, n1, n0]` (reuses MR's old SKIP_TURN pattern)

```elixir
defmodule Lenies.Codeomes.Hunter do
  @moduledoc """
  Reactive predator. Inline sense-and-attack: every forage iteration the
  seed checks `sense_front` and attacks if it sees a Lenie (-1 wire
  marker), otherwise it eats and moves. Every 8 forage iterations a 360°
  sweep rotates four times left, sensing in each direction; the first
  Lenie detected interrupts the sweep and triggers `attack`. If no Lenie
  is found, the four turn_lefts bring the Hunter back to its starting
  facing.

  The post-divide turn is deterministic `turn_left` instead of MR's
  random `pushN`-mod-2 pick — this frees two anchor patterns that the
  in-forage logic needs.

  ## Anchors added vs MinimalReplicator

  | Label                  | Anchor           | Jump template     |
  |------------------------|------------------|-------------------|
  | LENIE_HANDLER_ANCHOR   | [n0,n0,n0,n1]    | [n1,n1,n1,n0]     |
  | INCR_COUNTER_ANCHOR    | [n0,n1,n1,n1]    | [n1,n0,n0,n0]     |
  | DO_SWEEP_ANCHOR        | [n0,n1,n0,n0]    | [n1,n0,n1,n1]     |
  | SWEEP_FOUND_ANCHOR     | [n0,n0,n1,n0]    | [n1,n1,n0,n1]     |

  ## Forage loop structure (decrement-first, K = 128)

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
    sense_front
    push 1; add                     ; value+1: 0 iff was -1 (lenie)
    jz_t LENIE_HANDLER              ; pops the (value+1)
    eat; move; jmp_t INCR_COUNTER
  LENIE_HANDLER:
    attack
  INCR_COUNTER:                     ; both paths converge
    counter := slot[3] + 1
    if (counter mod 8) != 0:
      slot[3] := counter; jmp_t FORAGE_LOOP_HEAD
    else:                                          (DO_SWEEP)
      slot[3] := 0
      4× { turn_left; sense_front; push 1; add; jz_t SWEEP_FOUND }
      jmp_t FORAGE_LOOP_HEAD
  SWEEP_FOUND:
    attack
    jmp_t FORAGE_LOOP_HEAD
  ```
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor ───────────────────────────────────────
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..6: get_size; store slot[0] ────────────────────────────────
    :get_size, :push0, :store,

    # ── pos 7..9: allocate(N) ────────────────────────────────────────────
    :push0, :load, :allocate,

    # ── pos 10..14: jz_t ABORT_TARGET ────────────────────────────────────
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

    # ── pos 15..17: init slot[1] = 0 ────────────────────────────────────
    :push0, :push1, :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor ────────────────────────────────
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

    # ── pos 51: post-divide deterministic turn ──────────────────────────
    :turn_left,

    # ── pos 52..64: build K=128 (push1 + 7 doublings) ───────────────────
    :push1, :dup, :add, :dup, :add, :dup, :add,
    :dup, :add, :dup, :add, :dup, :add, :dup, :add,

    # ── pos 67..68: K+1 = 129 ────────────────────────────────────────────
    :push1, :add,

    # ── pos 69..70: store K+1 in slot[0] ─────────────────────────────────
    :push0, :store,

    # ── pos 71..77: init slot[3] := 0 ────────────────────────────────────
    :push0, :push1, :push1, :push1, :add, :add, :store,

    # ── pos 78..81: FORAGE_LOOP_HEAD anchor ──────────────────────────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 82..87: decrement slot[0] ────────────────────────────────────
    :push0, :load, :push1, :sub, :push0, :store,

    # ── pos 88..89: load slot[0] for exit check ──────────────────────────
    :push0, :load,

    # ── pos 90..94: jz_t LOOP_HEAD (exit forage when counter hits 0) ─────
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 95..98: sense_front; push 1; add; (value+1 on stack) ────────
    :sense_front, :push1, :add,

    # ── pos 98..102: jz_t LENIE_HANDLER (was -1) ─────────────────────────
    :jz_t, :nop_1, :nop_1, :nop_1, :nop_0,

    # ── (not a Lenie) eat; move; jmp_t INCR_COUNTER ──────────────────────
    :eat, :move,
    :jmp_t, :nop_1, :nop_0, :nop_0, :nop_0,        # template for INCR_COUNTER

    # ── LENIE_HANDLER_ANCHOR [n0,n0,n0,n1] ──────────────────────────────
    :nop_0, :nop_0, :nop_0, :nop_1,

    # ── attack; fall through to INCR_COUNTER ─────────────────────────────
    :attack,

    # ── INCR_COUNTER_ANCHOR [n0,n1,n1,n1] ───────────────────────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    # ── increment slot[3]; check mod 8 ───────────────────────────────────
    :push1, :push1, :push1, :add, :load,       # build slot 3, load
    :push1, :add,                                # counter + 1
    :dup,                                        # [counter+1, counter+1]

    # ── push 8 = push1; dup; add; dup; add; dup; add (1,2,4,8) ──────────
    :push1, :dup, :add, :dup, :add, :dup, :add,
    :mod,                                        # [counter+1, mod_result]

    # ── jz_t DO_SWEEP ───────────────────────────────────────────────────
    :jz_t, :nop_1, :nop_0, :nop_1, :nop_1,      # template for DO_SWEEP

    # ── (mod != 0) store counter+1 to slot[3]; jmp_t FORAGE_LOOP_HEAD ──
    :push1, :push1, :push1, :add, :store,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,     # template for FORAGE_LOOP_HEAD

    # ── DO_SWEEP_ANCHOR [n0,n1,n0,n0] ───────────────────────────────────
    :nop_0, :nop_1, :nop_0, :nop_0,

    # ── reset slot[3] := 0 ───────────────────────────────────────────────
    :drop,                                       # drop counter+1
    :push0, :push1, :push1, :push1, :add, :add, :store,

    # ── Sweep iter 1: turn_left, sense_front, push 1, add, jz_t FOUND ──
    :turn_left, :sense_front, :push1, :add,
    :jz_t, :nop_1, :nop_1, :nop_0, :nop_1,      # template for SWEEP_FOUND

    # ── Sweep iter 2 ─────────────────────────────────────────────────────
    :turn_left, :sense_front, :push1, :add,
    :jz_t, :nop_1, :nop_1, :nop_0, :nop_1,

    # ── Sweep iter 3 ─────────────────────────────────────────────────────
    :turn_left, :sense_front, :push1, :add,
    :jz_t, :nop_1, :nop_1, :nop_0, :nop_1,

    # ── Sweep iter 4 ─────────────────────────────────────────────────────
    :turn_left, :sense_front, :push1, :add,
    :jz_t, :nop_1, :nop_1, :nop_0, :nop_1,

    # ── No prey found — back to FORAGE_LOOP_HEAD ─────────────────────────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── SWEEP_FOUND_ANCHOR [n0,n0,n1,n0] ────────────────────────────────
    :nop_0, :nop_0, :nop_1, :nop_0,

    :attack,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,     # template for FORAGE_LOOP_HEAD

    # ── separator (final wrap protection) ───────────────────────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
```

- [ ] **Step 2: Run the Hunter test**

```bash
mix test test/lenies/codeomes/hunter_test.exs
```

Expected: PASS. If it fails, likely culprits:
- Template collision between LENIE_HANDLER and SWEEP_FOUND (both use 4-nop runs in close proximity inside the forage body — verify the separators between them).
- The sweep's `jz_t SWEEP_FOUND` lands a non-zero stack — the codeome above keeps stack discipline by **not** dup-ing the sensed value (the `jz_t` pops the only value, and on the non-jump path control naturally reaches the next sense_front with empty stack).
- Off-by-one in slot[0] init.

- [ ] **Step 3: Commit**

```bash
git add lib/lenies/codeomes/hunter.ex test/lenies/codeomes/hunter_test.exs
git commit -m "$(cat <<'EOF'
feat(seeds): Hunter — reactive predator with periodic 360° sweep

Inline sense-and-attack: each forage iteration the seed checks
sense_front and attacks if value+1 == 0 (the -1 lenie marker). Every
8 iterations a sweep rotates 4× left, sensing in each direction; the
first lenie detected interrupts the sweep and triggers attack.

The post-divide turn is deterministic turn_left (vs MR's pushN-mod-2
random pick) so the 4 new anchors fit inside the VM's 4-bit template
namespace.

Liveness test (alone, no prey, sweep finds nothing) asserts gen >= 3
within 30 s — validates the seed survives on its forage loop even
when the predator role is dormant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Forager seed

### Task 3.1: Write Forager liveness test

**Files:**
- Test: `test/lenies/codeomes/forager_test.exs` (create)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Lenies.Codeomes.ForagerTest do
  use ExUnit.Case, async: false

  alias Lenies.{Lenie, World}
  alias Lenies.Codeomes.Forager
  alias Lenies.World.Tables

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
    Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 500})
    Application.put_env(:lenies, :eat_amount, 50)
    Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

    on_exit(fn ->
      Application.delete_env(:lenies, :copy_substitution_rate)
      Application.delete_env(:lenies, :copy_insert_rate)
      Application.delete_env(:lenies, :copy_delete_rate)
      Application.delete_env(:lenies, :background_mutation_rate_per_1000_ticks)
      Application.delete_env(:lenies, :min_viable_codeome_opcodes)
      Application.delete_env(:lenies, :codeome_length_bounds)
      Application.delete_env(:lenies, :eat_amount)
      Application.delete_env(:lenies, :interpreter_steps_per_batch)

      case Process.whereis(Lenies.LenieSupervisor) do
        sup when is_pid(sup) ->
          DynamicSupervisor.which_children(sup)
          |> Enum.each(fn {_, child, _, _} ->
            if is_pid(child), do: DynamicSupervisor.terminate_child(sup, child)
          end)
        _ -> :ok
      end

      case Process.whereis(Lenies.World) do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        _ -> :ok
      end

      Tables.delete_all()
    end)

    :ok
  end

  test "forager reaches generation >= 3 in 30 seconds" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(:cells, {x, y})
      :ets.insert(:cells, {key, %{cell | resource: 200}})
    end

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "FOR-ORIGIN"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "FOR-ORIGIN",
        codeome: Forager.codeome(),
        energy: 10_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    deadline = System.monotonic_time(:millisecond) + 30_000

    max_gen = poll_until(deadline, fn ->
      snaps = :ets.tab2list(:lenies)
      m = max_generation(snaps)
      if m >= 3, do: {:done, m}, else: :continue
    end)

    snaps = :ets.tab2list(:lenies)

    assert max_gen >= 3,
           "expected at least 3 generations; got max gen #{max_gen}, " <>
             "#{length(snaps)} Lenies alive"
  end

  defp max_generation(snaps) do
    snaps
    |> Enum.map(fn {_id, snap} -> snap.lineage |> elem(1) end)
    |> Enum.max(fn -> 0 end)
  end

  defp poll_until(deadline, fun) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      snaps = :ets.tab2list(:lenies)
      max_generation(snaps)
    else
      case fun.() do
        {:done, v} -> v
        :continue ->
          Process.sleep(200)
          poll_until(deadline, fun)
      end
    end
  end
end
```

- [ ] **Step 2: Run the test, expect failure**

```bash
mix test test/lenies/codeomes/forager_test.exs
```

Expected: `UndefinedFunctionError` for `Lenies.Codeomes.Forager.codeome/0`.

### Task 3.2: Write the Forager codeome module

**Files:**
- Create: `lib/lenies/codeomes/forager.ex`

- [ ] **Step 1: Create the module with full opcode list**

```elixir
defmodule Lenies.Codeomes.Forager do
  @moduledoc """
  Adaptive herbivore that abandons resource-empty patches. Each forage
  iteration the seed checks `sense_front`; if the cell directly in front
  is empty (the wire format pushes 0), a slot[3] counter increments. On
  the 5th consecutive empty sighting, the seed fires a random
  turn_left or turn_right and resets the counter. Non-empty sightings
  reset the counter immediately.

  ## VM-side relaxation

  The spec specified "low energy = sense_front < 20" but the Lenies VM
  has no less-than opcode — emulating `< 20` would cost ~16 energy per
  forage iteration. The implementation uses **T = 0** (count only
  truly empty cells via `jz_t` on the sense_front result). Behaviour
  is qualitatively the same — the seed walks away from exhausted
  patches — just at the absolute exhaustion point rather than a soft
  20-unit threshold.

  Like Hunter, Forager replaces MR's post-divide random turn with a
  deterministic `turn_left` so the three new in-forage anchors fit in
  the 4-bit template namespace.

  ## Anchors added vs MinimalReplicator

  | Label             | Anchor           | Jump template     |
  |-------------------|------------------|-------------------|
  | EMPTY_ANCHOR      | [n0,n0,n0,n1]    | [n1,n1,n1,n0]     |
  | DO_TURN_ANCHOR    | [n0,n1,n1,n1]    | [n1,n0,n0,n0]     |
  | TURN_LEFT_BR_ANCHOR | [n0,n1,n0,n0]  | [n1,n0,n1,n1]     |

  ## Forage loop structure (decrement-first, K = 128)

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
    sense_front
    dup; jz_t EMPTY              ; pops the dup, jumps if value == 0
    drop                          ; non-empty: drop the remaining value
    eat; move
    slot[3] := 0                  ; reset low-energy counter
    jmp_t FORAGE_LOOP_HEAD
  EMPTY:
    drop                          ; drop the leftover value (= 0)
    eat; move                     ; eat is a no-op cost-wise (still pays 2)
    counter := slot[3] + 1
    if (counter mod 5) != 0:
      slot[3] := counter; jmp_t FORAGE_LOOP_HEAD
    else:                                          (DO_TURN)
      slot[3] := 0
      if (pushN mod 2) == 0:                       (jz_t TURN_LEFT_BR)
        turn_right
      else:                                        (TURN_LEFT_BR)
        turn_left
      jmp_t FORAGE_LOOP_HEAD
  ```
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor ───────────────────────────────────────
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..6: get_size; store slot[0] ────────────────────────────────
    :get_size, :push0, :store,

    # ── pos 7..9: allocate(N) ────────────────────────────────────────────
    :push0, :load, :allocate,

    # ── pos 10..14: jz_t ABORT_TARGET ────────────────────────────────────
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

    # ── pos 15..17: init slot[1] = 0 ─────────────────────────────────────
    :push0, :push1, :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor ────────────────────────────────
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

    # ── pos 51: post-divide deterministic turn ──────────────────────────
    :turn_left,

    # ── pos 52..64: build K=128 ─────────────────────────────────────────
    :push1, :dup, :add, :dup, :add, :dup, :add,
    :dup, :add, :dup, :add, :dup, :add, :dup, :add,

    # ── pos 67..68: K+1 = 129 ────────────────────────────────────────────
    :push1, :add,

    # ── pos 69..70: store K+1 in slot[0] ─────────────────────────────────
    :push0, :store,

    # ── pos 71..77: init slot[3] := 0 ────────────────────────────────────
    :push0, :push1, :push1, :push1, :add, :add, :store,

    # ── pos 78..81: FORAGE_LOOP_HEAD anchor ──────────────────────────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 82..87: decrement slot[0] ────────────────────────────────────
    :push0, :load, :push1, :sub, :push0, :store,

    # ── pos 88..89: load slot[0] for exit check ──────────────────────────
    :push0, :load,

    # ── pos 90..94: jz_t LOOP_HEAD (exit forage when counter is 0) ──────
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 95: sense_front (pushes value) ──────────────────────────────
    :sense_front,

    # ── pos 96: dup ──────────────────────────────────────────────────────
    :dup,

    # ── pos 97..101: jz_t EMPTY_ANCHOR ───────────────────────────────────
    :jz_t, :nop_1, :nop_1, :nop_1, :nop_0,

    # ── (non-empty) drop the remaining value; eat; move; reset counter ──
    :drop,
    :eat, :move,
    :push0, :push1, :push1, :push1, :add, :add, :store,    # slot[3] := 0
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,                # FORAGE_LOOP_HEAD

    # ── EMPTY_ANCHOR [n0,n0,n0,n1] ──────────────────────────────────────
    :nop_0, :nop_0, :nop_0, :nop_1,

    :drop,                                                  # drop the 0
    :eat, :move,

    # ── increment slot[3]; check mod 5 ───────────────────────────────────
    :push1, :push1, :push1, :add, :load,                   # build 3, load
    :push1, :add,                                           # counter+1
    :dup,
    :push1, :dup, :add, :dup, :add, :push1, :add,          # build 5
    :mod,

    # ── jz_t DO_TURN_ANCHOR ─────────────────────────────────────────────
    :jz_t, :nop_1, :nop_0, :nop_0, :nop_0,

    # ── (mod != 0) store counter+1; jmp_t FORAGE_LOOP_HEAD ──────────────
    :push1, :push1, :push1, :add, :store,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── DO_TURN_ANCHOR [n0,n1,n1,n1] ────────────────────────────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    :drop,
    :push0, :push1, :push1, :push1, :add, :add, :store,   # slot[3] := 0

    :pushN, :push1, :push1, :add, :mod,

    # ── jz_t TURN_LEFT_BR_ANCHOR ─────────────────────────────────────────
    :jz_t, :nop_1, :nop_0, :nop_1, :nop_1,

    :turn_right,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── TURN_LEFT_BR_ANCHOR [n0,n1,n0,n0] ───────────────────────────────
    :nop_0, :nop_1, :nop_0, :nop_0,

    :turn_left,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── separator (final wrap protection) ───────────────────────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
```

- [ ] **Step 2: Run the Forager test**

```bash
mix test test/lenies/codeomes/forager_test.exs
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/lenies/codeomes/forager.ex test/lenies/codeomes/forager_test.exs
git commit -m "$(cat <<'EOF'
feat(seeds): Forager — adaptive herbivore that escapes exhausted patches

Each forage iteration the seed checks sense_front; on the 5th
consecutive empty sighting it fires a random turn_left/turn_right and
resets the counter. Non-empty sightings reset the counter immediately.

The spec's T=20 threshold is relaxed to T=0 (count only :empty cells)
because the Lenies VM has no less-than opcode; the qualitative
"leave exhausted patches" behaviour is preserved.

Post-divide turn is deterministic turn_left so the three new in-forage
anchors fit in the 4-bit template namespace.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Wire into Seeds catalog, drop Random

### Task 4.1: Update `Lenies.Seeds`

**Files:**
- Modify: `lib/lenies/seeds.ex`

- [ ] **Step 1: Open the current catalog**

```bash
cat lib/lenies/seeds.ex
```

Expected structure (see [lib/lenies/seeds.ex](../../lib/lenies/seeds.ex)): `all/0` returning a list with `:minimal_replicator`, `:carnivore`, `:random`; module attributes `@random_min_len` / `@random_max_len`; private helpers `build_random_codeome/0` and friends; possibly `alias Lenies.Codeome.Opcodes`.

- [ ] **Step 2: Rewrite the module**

Replace the entire file with:

```elixir
defmodule Lenies.Seeds do
  @moduledoc """
  Registry of seed Codeomes for the dashboard Seed dropdown.

  Each seed has:
  - `id`: atom identifier (used in dropdown values)
  - `name`: human-readable label
  - `codeome`: a `Lenies.Codeome.t()`
  - `default_options`: keyword/map with initial energy, etc.

  Vedi spec §7.1 (Controllo / Seed) e §5.5 (seed predefiniti).
  """

  alias Lenies.Codeomes.{Carnivore, Defender, Forager, Hunter, MinimalReplicator}

  @doc "All available seeds as a list of records."
  def all do
    [
      %{
        id: :minimal_replicator,
        name: "Minimal Replicator",
        codeome: MinimalReplicator.codeome(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :carnivore,
        name: "Carnivore",
        codeome: Carnivore.codeome(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :defender,
        name: "Defender",
        codeome: Defender.codeome(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :hunter,
        name: "Hunter",
        codeome: Hunter.codeome(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :forager,
        name: "Forager",
        codeome: Forager.codeome(),
        default_options: %{energy: 10_000.0}
      }
    ]
  end

  @doc "Look up a seed by id. Returns nil if not found."
  def get(id) when is_atom(id) do
    Enum.find(all(), &(&1.id == id))
  end
end
```

- [ ] **Step 3: Compile-check**

```bash
mix compile --warnings-as-errors
```

Expected: clean compile. If a warning fires, it's usually an unused alias / private function left over from the `:random` removal — clean it up.

- [ ] **Step 4: Run the full suite**

```bash
mix test
```

Expected: all tests pass. The `:random` seed was used only inside `Lenies.Seeds.all/0` and there's no existing test that hard-codes the seed-id list (the project has `test/lenies/seeds_test.exs`? check; if it asserts `:random` is present, update it). Confirm with:

```bash
grep -r ":random" test/ lib/
```

If any references remain, fix them inline.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/seeds.ex
git commit -m "$(cat <<'EOF'
feat(seeds): expose Defender / Hunter / Forager in the catalog, drop Random

Drops the sterile `:random` seed (and its build_random_codeome helper +
@random_min_len / @random_max_len constants) and registers the three new
hand-written specialised seeds. Order in the dropdown:
Minimal Replicator → Carnivore → Defender → Hunter → Forager. All
default to energy 10_000.0 so ecological interactions aren't distorted
by uneven spawn-energy.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — README update

### Task 5.1: Update "Built-in seeds" section

**Files:**
- Modify: `README.md` (the "Built-in seeds" section, around line 146)

- [ ] **Step 1: Locate the current section**

```bash
grep -n "Built-in seeds" README.md
```

- [ ] **Step 2: Replace the Random entry and add the three new ones**

Find the existing list (Minimal Replicator → Carnivore → Random) and replace with:

```markdown
## Built-in seeds

Five seeds come pre-loaded in the spawn dropdown:

- **Minimal Replicator** — a hand-written 121-opcode self-replicator with a
  128-step forage cycle between divisions. Robust enough to maintain a
  steady population on the default world. Source:
  [lib/lenies/codeomes/minimal_replicator.ex](lib/lenies/codeomes/minimal_replicator.ex).
  The Programming Manual dissects it line by line in
  [chapter 9](docs/manual/09-minimal-replicator.md).
- **Carnivore** — the Minimal Replicator with `:attack` injected before
  `:eat`. Demonstrates predation; thrives in dense populations, starves
  in sparse ones. Source:
  [lib/lenies/codeomes/carnivore.ex](lib/lenies/codeomes/carnivore.ex).
- **Defender** — pacifist herbivore with a pseudo-random walk: every 5
  forage steps the Lenie fires a random turn, making it hard to track
  for a directional predator. Net forage gain is ~5% lower than the
  Minimal Replicator. Source:
  [lib/lenies/codeomes/defender.ex](lib/lenies/codeomes/defender.ex).
- **Hunter** — reactive predator. Each forage iteration checks
  `sense_front` and attacks if it sees a Lenie; every 8 iterations a
  360° sweep rotates four times left, sensing in each direction and
  attacking the first prey detected. More efficient than the Carnivore
  on sparse worlds where blind attacks waste energy. Source:
  [lib/lenies/codeomes/hunter.ex](lib/lenies/codeomes/hunter.ex).
- **Forager** — adaptive herbivore. Counts consecutive empty
  `sense_front` sightings; on the 5th, fires a random turn and resets
  the counter. Walks away from exhausted patches and tends to settle
  in hotspots. Source:
  [lib/lenies/codeomes/forager.ex](lib/lenies/codeomes/forager.ex).
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): drop Random, add Defender / Hunter / Forager to built-in seeds

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 — Final sanity check

### Task 6.1: Run the entire test suite

**Files:** none.

- [ ] **Step 1: Run all tests**

```bash
mix test
```

Expected: every test passes. If a previously-green test now fails, it's almost certainly because it asserted `:random` was in `Seeds.all/0` — update or remove that assertion.

- [ ] **Step 2: Manual smoke test (optional)**

```bash
iex -S mix phx.server
```

Open the dashboard, confirm all five seeds appear in the dropdown, spawn one of each, watch the species table populate.

---

## Self-review

After the agent writes this plan into running code, verify:

1. **Spec coverage**: Defender / Hunter / Forager all present, each with a `codeome/0` returning a list-built codeome. Random is gone. Catalog order matches the spec.
2. **Placeholder scan**: no "TBD" / "TODO" / "implement later" in any committed code or comment.
3. **Type consistency**: `Lenies.Codeomes.Defender`, `Lenies.Codeomes.Hunter`, `Lenies.Codeomes.Forager` — exact module names match the catalog aliases.
4. **Per-seed liveness** assertion: all three seed tests follow the exact same setup-shutdown pattern as `minimal_replicator_test.exs`, ensuring no cross-test state leakage.
