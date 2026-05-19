# Seed Plasmids Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Equip MinimalReplicator and Carnivore seeds with plasmids that produce a visible movement signature (twitch / sprint) and spread via `:conjugate` calls baked into their forage loops.

**Architecture:** Each seed gets (a) two new opcodes `:conjugate, :drop` inserted into its forage body so it actively spreads its plasmid, and (b) a new `plasmid/0` function returning the opcode list of the plasmid payload. The plasmid payload begins with a `[n1,n1,n1,n1]` anchor that intercepts the host's end-of-forage `jmp_t LOOP_HEAD` (template's forward search finds the appended plasmid before wrapping to position 0). The seeds catalog gains an optional `:plasmid` field; the dashboard spawn handler reads it and passes a `plasmids:` opt to `World.spawn_lenie`.

**Tech Stack:** Elixir 1.19.3-otp-28, Phoenix LiveView, ExUnit.

---

## Background

Read these before starting any task:

- **Spec**: [docs/superpowers/specs/2026-05-19-seed-plasmids-design.md](../specs/2026-05-19-seed-plasmids-design.md)
- **Prior PR**: plasmid conjugation MVP (commits `edda610..7b48100`). The `:make_plasmid` and `:conjugate` opcodes already exist; `%Lenies.Plasmid{}` struct, vertical inheritance, divide tax, UI flash all in place.
- **`Lenies.Seeds`** ([lib/lenies/seeds.ex](../../../lib/lenies/seeds.ex)): the catalog of seed records.
- **`MinimalReplicator`** ([lib/lenies/codeomes/minimal_replicator.ex](../../../lib/lenies/codeomes/minimal_replicator.ex)): existing 121-opcode replicator. The forage body lives at positions 94..119.
- **`Carnivore`** ([lib/lenies/codeomes/carnivore.ex](../../../lib/lenies/codeomes/carnivore.ex)): MR with `:attack` injected before `:eat` via the `inject_attack_before_eat` patcher.
- **Dashboard spawn**: [lib/lenies_web/live/controls_panel_component.ex:351-362](../../../lib/lenies_web/live/controls_panel_component.ex) — the `"spawn"` handler reads `Lenies.Seeds.get(seed_id)` and calls `World.spawn_lenie/2`.
- **Mix command prefix**: `export PATH="$HOME/.asdf/installs/elixir/1.19.3-otp-28/bin:$HOME/.asdf/installs/erlang/28.1.1/bin:$PATH"`

---

## File Structure

**Modified:**
- `lib/lenies/codeomes/minimal_replicator.ex` — add `:conjugate, :drop` to forage body; add `plasmid/0` function
- `lib/lenies/codeomes/carnivore.ex` — add `plasmid/0` function (codeome modification is inherited from MR automatically)
- `lib/lenies/seeds.ex` — add `plasmid:` field to MR + Carnivore catalog entries
- `lib/lenies_web/live/controls_panel_component.ex` — propagate `seed.plasmid` to `spawn_lenie` opts
- `test/lenies/codeomes/minimal_replicator_test.exs` — verify replication still works + new movement / conjugation tests
- `test/lenies/codeomes/carnivore_test.exs` — analogous

---

## Task 1: Inject `:conjugate, :drop` into MR forage + add `plasmid/0`

**Goal**: MR's forage body actively calls `:conjugate` and discards the result; expose the Twitch plasmid via `plasmid/0`.

**Files:**
- Modify: `lib/lenies/codeomes/minimal_replicator.ex`
- Modify: `test/lenies/codeomes/minimal_replicator_test.exs` (verify replication still works)

- [ ] **Step 1.1: Read the current MR codeome**

```bash
grep -n "FORAGE_LOOP_HEAD\|forage body\|eat,\s*:move" lib/lenies/codeomes/minimal_replicator.ex | head -10
```

The forage body lives at positions 98..101 (`:sense_front, :drop, :eat, :move`). The `:conjugate, :drop` insertion goes immediately after the existing `:move`, before the counter machinery at positions 102+.

- [ ] **Step 1.2: Replace MR's `@opcodes` to insert the two new opcodes**

Open `lib/lenies/codeomes/minimal_replicator.ex`. Find the line:

```elixir
    # ── pos 98..101: forage body — sense, drop result, eat, move ─────────
    :sense_front,
    :drop,
    :eat,
    :move,
```

Insert immediately after:

```elixir
    # ── pos 102..103: try to infect a neighbor and drop the result ──────
    :conjugate,
    :drop,
```

Then the existing comment block `# ── pos 102..107: counter := counter - 1 (slot[0]) ───────────────────` should be renumbered to `# ── pos 104..109` (cosmetic; not enforced by runtime). Add a brief moduledoc note explaining that the codeome now embeds `:conjugate` for plasmid propagation.

- [ ] **Step 1.3: Add the Twitch plasmid function to MR**

At the bottom of the module (before the closing `end`), add:

```elixir
  @plasmid_opcodes [
    # ── pos 0..3: INTERCEPT_ANCHOR — matches host's LOOP_HEAD template ──
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..8: build pushN mod 2 on stack ─────────────────────────────
    :pushN, :push1, :push1, :add, :mod,

    # ── pos 9..13: jz_t TURN_LEFT_BR (template [n1,n0,n0,n0]) ───────────
    :jz_t, :nop_1, :nop_0, :nop_0, :nop_0,

    # ── pos 14: turn_right (fallthrough — mod was 1) ────────────────────
    :turn_right,

    # ── pos 15..19: jmp_t back to host LOOP_HEAD (template [n0,n0,n0,n0]) ──
    :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 20: separator (avoids 8-nop misread into next anchor) ───────
    :push0,

    # ── pos 21..24: TURN_LEFT_BR anchor [n0,n1,n1,n1] ───────────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    # ── pos 25: turn_left ────────────────────────────────────────────────
    :turn_left,

    # ── pos 26..30: jmp_t back to host LOOP_HEAD ─────────────────────────
    :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0
  ]

  @doc """
  The Twitch plasmid: 31 opcodes that intercept the host's end-of-forage
  `jmp_t LOOP_HEAD` and inject a random L/R turn before bouncing back.

  Anchor at pos 0..3 (`[n1,n1,n1,n1]`) matches any host whose LOOP_HEAD
  uses the same pattern (i.e., any MR-derived codeome). The forward
  template search finds this appended anchor before wrapping to position 0.
  """
  @spec plasmid() :: [atom()]
  def plasmid, do: @plasmid_opcodes
```

- [ ] **Step 1.4: Sanity-check opcode counts**

```bash
export PATH="$HOME/.asdf/installs/elixir/1.19.3-otp-28/bin:$HOME/.asdf/installs/erlang/28.1.1/bin:$PATH"
cd /home/patrick/projects/playground/Lenies
mix run --no-start -e '
  IO.puts("MR codeome length: #{length(Lenies.Codeomes.MinimalReplicator.opcodes())}")
  IO.puts("MR plasmid length: #{length(Lenies.Codeomes.MinimalReplicator.plasmid())}")
'
```

Expected: codeome length 123 (was 121, +2 for `:conjugate, :drop`), plasmid length 31.

- [ ] **Step 1.5: Run the MR test (replication must still succeed)**

```bash
mix test test/lenies/codeomes/minimal_replicator_test.exs
```

Expected: the gen-≥-3 test still passes. Energy math: per-iter cost rose by 4.1 (conjugate 4.0 + drop 0.1) but eat_amount is 50 in tests, so headroom is large.

If the test fails with starvation, energy budget needs reconsidering — escalate.

- [ ] **Step 1.6: Run the full test suite**

```bash
mix test --seed 0
```

Expected: 379 tests + any new ones, 0 failures.

- [ ] **Step 1.7: Commit**

```bash
git add lib/lenies/codeomes/minimal_replicator.ex
git commit -m "feat(minimal_replicator): embed :conjugate in forage + expose Twitch plasmid

Inserts :conjugate, :drop after the existing forage move so MR actively
attempts conjugation on every forage iter. Adds the plasmid/0 function
returning a 31-opcode Twitch payload that hijacks any MR-derived host's
end-of-forage jmp_t LOOP_HEAD and injects a random L/R turn.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add `plasmid/0` to Carnivore (Sprint plasmid)

**Goal**: Expose the 11-opcode Sprint plasmid via `Carnivore.plasmid/0`. The codeome modification (`:conjugate, :drop` in forage) is inherited automatically because `Carnivore.codeome/0` builds on `MinimalReplicator.opcodes/0`.

**Files:**
- Modify: `lib/lenies/codeomes/carnivore.ex`
- Modify: `test/lenies/codeomes/carnivore_test.exs` (verify replication still works)

- [ ] **Step 2.1: Add the Sprint plasmid to Carnivore**

Open `lib/lenies/codeomes/carnivore.ex`. Append (before the final `end`):

```elixir
  @plasmid_opcodes [
    # ── pos 0..3: INTERCEPT_ANCHOR — matches host's LOOP_HEAD template ──
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..5: extra step + extra eat ─────────────────────────────────
    :move, :eat,

    # ── pos 6..10: jmp_t back to host LOOP_HEAD ─────────────────────────
    :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0
  ]

  @doc """
  The Sprint plasmid: 11 opcodes that intercept the host's end-of-forage
  `jmp_t LOOP_HEAD` and inject an extra `:move, :eat` pair before
  bouncing back. The host effectively covers two cells (and eats two)
  per forage iter instead of one.

  Anchor at pos 0..3 matches any MR-derived codeome's LOOP_HEAD via the
  template forward search.
  """
  @spec plasmid() :: [atom()]
  def plasmid, do: @plasmid_opcodes
```

- [ ] **Step 2.2: Sanity-check**

```bash
mix run --no-start -e '
  IO.puts("Carnivore codeome length: #{length(Lenies.Codeome.to_list(Lenies.Codeomes.Carnivore.codeome()))}")
  IO.puts("Carnivore plasmid length: #{length(Lenies.Codeomes.Carnivore.plasmid())}")
'
```

Expected: codeome length 124 (MR's 123 + 1 for `:attack` injected by `inject_attack_before_eat`), plasmid 11.

- [ ] **Step 2.3: Run Carnivore tests**

```bash
mix test test/lenies/codeomes/carnivore_test.exs
mix test --seed 0
```

Expected: all tests pass.

- [ ] **Step 2.4: Commit**

```bash
git add lib/lenies/codeomes/carnivore.ex
git commit -m "feat(carnivore): expose Sprint plasmid (move + eat hijack)

Adds plasmid/0 returning an 11-opcode Sprint payload. Anchor [n1,n1,n1,n1]
hijacks the host's end-of-forage jmp_t LOOP_HEAD, injects extra move
+ eat, then bounces back. The :conjugate, :drop forage modification
is inherited automatically from MR via inject_attack_before_eat.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Wire `plasmid` into seed catalog + dashboard spawn

**Goal**: Add a `:plasmid` field to seed records; dashboard spawn handler reads it and passes a `plasmids:` opt.

**Files:**
- Modify: `lib/lenies/seeds.ex`
- Modify: `lib/lenies_web/live/controls_panel_component.ex`

- [ ] **Step 3.1: Update Seeds catalog**

Open `lib/lenies/seeds.ex`. Update the MR and Carnivore catalog records:

```elixir
      %{
        id: :minimal_replicator,
        name: "Minimal Replicator",
        codeome: MinimalReplicator.codeome(),
        plasmid: MinimalReplicator.plasmid(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :carnivore,
        name: "Carnivore",
        codeome: Carnivore.codeome(),
        plasmid: Carnivore.plasmid(),
        default_options: %{energy: 10_000.0}
      },
```

The other three seed records (`:defender`, `:hunter`, `:forager`) get no `plasmid` field (`Map.get` returns `nil`).

Also update the @moduledoc to mention the new optional field.

- [ ] **Step 3.2: Update dashboard spawn handler**

Open `lib/lenies_web/live/controls_panel_component.ex`. Find the spawn handler around line 351:

```elixir
    case Lenies.Seeds.get(seed_id) do
      %{codeome: codeome, default_options: opts, name: seed_name} ->
        energy = Map.get(opts, :energy, 500.0)
        dirs = [:n, :s, :e, :w]

        for _ <- 1..count do
          Lenies.World.spawn_lenie(codeome,
            energy: energy,
            dir: Enum.random(dirs),
            seed_origin: seed_name
          )
        end

      nil ->
        :ok
    end
```

Replace with:

```elixir
    case Lenies.Seeds.get(seed_id) do
      %{codeome: codeome, default_options: opts, name: seed_name} = seed ->
        energy = Map.get(opts, :energy, 500.0)
        dirs = [:n, :s, :e, :w]
        plasmid_opcodes = Map.get(seed, :plasmid)

        plasmid_opt =
          if is_list(plasmid_opcodes) and plasmid_opcodes != [] do
            [plasmids: [Lenies.Plasmid.new(plasmid_opcodes)]]
          else
            []
          end

        for _ <- 1..count do
          spawn_opts =
            [
              energy: energy,
              dir: Enum.random(dirs),
              seed_origin: seed_name
            ] ++ plasmid_opt

          Lenies.World.spawn_lenie(codeome, spawn_opts)
        end

      nil ->
        :ok
    end
```

- [ ] **Step 3.3: Sanity-check the wiring**

```bash
mix compile --warnings-as-errors 2>&1 | tail -5
```

Expected: clean compile.

- [ ] **Step 3.4: Run the full test suite**

```bash
mix test --seed 0
```

Expected: all tests pass.

- [ ] **Step 3.5: Commit**

```bash
git add lib/lenies/seeds.ex lib/lenies_web/live/controls_panel_component.ex
git commit -m "feat(seeds): wire MR/Carnivore plasmids through the spawn pipeline

Seeds catalog records gain an optional :plasmid field (list of opcode
atoms). The dashboard spawn handler reads it and passes plasmids: opt
to World.spawn_lenie wrapping it in a %Lenies.Plasmid{}. Seeds without
a plasmid (Defender/Hunter/Forager) spawn without the opt as before.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Movement signature + conjugation spread tests

**Goal**: Concrete integration tests that verify (a) MR-Twitch produces a visible movement signature (y-displacement ≠ 0 after walking east) and (b) the plasmid spreads to vanilla MR via conjugation.

**Files:**
- Create: `test/lenies/seed_plasmid_test.exs`

- [ ] **Step 4.1: Write the test file**

Create `test/lenies/seed_plasmid_test.exs`:

```elixir
defmodule Lenies.SeedPlasmidTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie, Plasmid, World}
  alias Lenies.Codeomes.MinimalReplicator
  alias Lenies.World.Tables

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
    Application.put_env(:lenies, :eat_amount, 50)
    Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

    on_exit(fn ->
      Application.delete_env(:lenies, :copy_substitution_rate)
      Application.delete_env(:lenies, :copy_insert_rate)
      Application.delete_env(:lenies, :copy_delete_rate)
      Application.delete_env(:lenies, :background_mutation_rate_per_1000_ticks)
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

  test "MR-Twitch moves on both x and y axes (twitch signature)" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(:cells, {x, y})
      :ets.insert(:cells, {key, %{cell | resource: 200}})
    end

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "TWITCH"}})

    plasmid = Plasmid.new(MinimalReplicator.plasmid())

    {:ok, pid} =
      Lenie.start_link(
        id: "TWITCH",
        codeome: MinimalReplicator.codeome(),
        energy: 10_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0},
        plasmids: [plasmid]
      )

    Process.unlink(pid)

    deadline = System.monotonic_time(:millisecond) + 15_000

    moved_off_axis = poll_until(deadline, fn ->
      case :ets.lookup(:lenies, "TWITCH") do
        [{_, %{pos: {_, y}}}] when y != 128 -> {:done, true}
        _ -> :continue
      end
    end)

    assert moved_off_axis == true,
           "expected MR-Twitch to leave y=128 within 15s (twitch plasmid hijacks LOOP_HEAD jump and injects random L/R turn)"
  end

  test "MR-Twitch infects an adjacent vanilla MR" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(:cells, {x, y})
      :ets.insert(:cells, {key, %{cell | resource: 200}})
    end

    [{key1, c1}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key1, %{c1 | lenie_id: "TWITCH"}})
    [{key2, c2}] = :ets.lookup(:cells, {129, 128})
    :ets.insert(:cells, {key2, %{c2 | lenie_id: "VANILLA"}})

    plasmid = Plasmid.new(MinimalReplicator.plasmid())

    {:ok, twitch_pid} =
      Lenie.start_link(
        id: "TWITCH",
        codeome: MinimalReplicator.codeome(),
        energy: 10_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0},
        plasmids: [plasmid]
      )

    {:ok, vanilla_pid} =
      Lenie.start_link(
        id: "VANILLA",
        codeome: MinimalReplicator.codeome(),
        energy: 10_000.0,
        pos: {129, 128},
        dir: :w,
        lineage: {nil, 0}
      )

    Process.unlink(twitch_pid)
    Process.unlink(vanilla_pid)

    deadline = System.monotonic_time(:millisecond) + 15_000

    infected = poll_until(deadline, fn ->
      case :ets.lookup(:lenies, "VANILLA") do
        [{_, snap}] ->
          if Map.get(snap, :plasmids, []) != [] do
            {:done, true}
          else
            :continue
          end

        _ ->
          :continue
      end
    end)

    assert infected == true,
           "expected vanilla MR to receive the Twitch plasmid within 15s"
  end

  defp poll_until(deadline, fun) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      nil
    else
      case fun.() do
        {:done, v} -> v
        :continue ->
          Process.sleep(150)
          poll_until(deadline, fun)
      end
    end
  end
end
```

- [ ] **Step 4.2: Run the new tests**

```bash
mix test test/lenies/seed_plasmid_test.exs
```

Expected: 2 tests pass.

If the twitch-signature test fails: most likely the plasmid's anchor isn't being found by the host's template search. Verify by hand:
- MR's last `jmp_t LOOP_HEAD` is at position ~115-119 of the codeome.
- The plasmid is appended at position 123+ (after codeome size 123).
- Forward search from pos 120 (one past the template) up to radius 256: should find `[n1,n1,n1,n1]` at the plasmid's start.
- If search radius is < 4, search wraps too early; otherwise it should land on the plasmid first.

If the infection test fails: verify the donor MR's energy doesn't run out before reaching its `:conjugate` opcode (the conjugate is at position 102, well within the first forage iter).

- [ ] **Step 4.3: Run the full test suite**

```bash
mix test --seed 0
```

Expected: all tests pass.

- [ ] **Step 4.4: Commit**

```bash
git add test/lenies/seed_plasmid_test.exs
git commit -m "test(seed-plasmid): MR-Twitch movement signature + infection of vanilla MR

Two integration tests:
- twitch signature: a single MR-Twitch leaves its starting y axis
  within 15s (the plasmid's LOOP_HEAD hijack injects random L/R turns)
- infection: MR-Twitch adjacent to a vanilla MR transfers its plasmid
  within 15s (vanilla.plasmids ends up non-empty)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-review checklist (run after all tasks complete)

- [ ] MR codeome length is 123 ops (+ 2 for `:conjugate, :drop`)
- [ ] MR plasmid length is 31 ops
- [ ] Carnivore codeome length is 124 ops (MR's 123 + 1 for `:attack`)
- [ ] Carnivore plasmid length is 11 ops
- [ ] `Lenies.Seeds.get(:minimal_replicator).plasmid` returns the 31-opcode list
- [ ] `Lenies.Seeds.get(:carnivore).plasmid` returns the 11-opcode list
- [ ] `Lenies.Seeds.get(:defender)` has no `:plasmid` key (or it's nil)
- [ ] Dashboard spawn handler passes `plasmids: [...]` for seeds that have one
- [ ] All existing tests pass
- [ ] New seed-plasmid tests pass

## Risk notes

- **MR/Carnivore replication might starve under default config**: the
  added 4.1 energy/iter from `:conjugate, :drop` plus the plasmid
  intercept's ~1.8 should still leave net ~+5 at eat_amount=20. Tests
  use eat_amount=50 so the margin is generous. If production runs at
  eat_amount=10 or lower, escalate.
- **Vanilla MR spawned from a snapshot before this PR**: its codeome
  hash is different from MR-Twitch's, so it shows as a separate species
  in the table. Acceptable.
- **Symmetric-donor deadlock**: MR-Twitch + MR-Twitch facing each other
  could deadlock via the known `:conjugate` cross-fire (see prior PR's
  Risk section). Probability per tick remains low; not a blocker.
