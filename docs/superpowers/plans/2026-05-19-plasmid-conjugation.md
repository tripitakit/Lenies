# Plasmid Conjugation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional per-Lenie `plasmid` and two opcodes (`:make_plasmid`, `:conjugate`) so plasmids can spread horizontally between adjacent Lenies as well as vertically through reproduction, with appropriate energy costs and a visible flash on each conjugation.

**Architecture:** A new `%Lenies.Plasmid{}` struct holds the plasmid opcodes. Each Lenie's state gets a `plasmids: []` field (list with 0 or 1 element for MVP, forward-compatible with multi-plasmid later). Two new opcodes drive creation (`:make_plasmid`, atomic from own codeome) and transfer (`:conjugate`, sender-push via `GenServer.call` to the front Lenie's process). Vertical inheritance and divide-time energy tax are handled in `World.spawn_child`. UI flash is broadcast on a new `"world:fx"` PubSub topic, picked up by the dashboard and rendered as a fading overlay on both cells.

**Tech Stack:** Elixir 1.19.3-otp-28, Phoenix LiveView, ExUnit, plain JS (canvas hook).

---

## Background — repository conventions for new implementers

Read these before starting any task:

- **Spec**: [docs/superpowers/specs/2026-05-19-plasmid-conjugation-design.md](../specs/2026-05-19-plasmid-conjugation-design.md) — full design, cost model, edge cases.
- **Opcode whitelist**: [lib/lenies/codeome/opcodes.ex](../../../lib/lenies/codeome/opcodes.ex) — adding an opcode = appending it to `@opcodes`. The integer encoding follows list position automatically.
- **Opcode costs**: [lib/lenies/codeome/costs.ex](../../../lib/lenies/codeome/costs.ex) — pattern is `def cost(:op, _) when ... do <value> end`.
- **Interpreter dispatch**: [lib/lenies/interpreter.ex](../../../lib/lenies/interpreter.ex) — `defp dispatch(:op, state, c, size) do ... end` per opcode. Use `Costs.cost/2` and `State.apply_cost/2` for accounting; `advance_and_charge/4` is the helper used by simple opcodes.
- **World actions**: opcodes that touch the world send `{:wait_world, action, new_state}` and the Lenie's `apply_world_action/3` calls `World.action/1`. Pure VM opcodes (no world) return the updated state directly.
- **Inter-Lenie communication**: There is currently NO direct Lenie→Lenie message path. We will add one (a `GenServer.call({:receive_plasmid, opcodes})`). This is safe because Lenie GenServers register in `Lenies.Registry` by id and the cell occupant's id is in `:cells` ETS.
- **Snapshot**: maybe_write_snapshot in lenie.ex writes selected fields to `:lenies` ETS every K batches. Add `plasmids` to the snapshot so the inspector sees it.
- **Mix command prefix**: asdf-managed. Tests need `export PATH="$HOME/.asdf/installs/elixir/1.19.3-otp-28/bin:$HOME/.asdf/installs/erlang/28.1.1/bin:$PATH"` once per shell.
- **Test conventions**: integration tests live in `test/lenies/`, follow the setup pattern in `test/lenies/codeomes/defender_test.exs` (set deterministic config in `setup`, cleanup in `on_exit`).

---

## File Structure

**New files:**
- `lib/lenies/plasmid.ex` — `%Plasmid{}` struct + helpers (Task 1)
- `test/lenies/plasmid_test.exs` (Task 1)
- `test/lenies/conjugation_test.exs` — end-to-end conjugation tests (Task 5)

**Modified files:**
- `lib/lenies/mutator.ex` — add list-flavored mutation helpers (Task 2)
- `lib/lenies/lenie.ex` — `plasmids` field, `:receive_plasmid` handler, BG mutation extension, plasmid passthrough at spawn (Tasks 3, 5, 6)
- `lib/lenies/world.ex` — propagate `plasmids` opt in `spawn_lenie`/`spawn_child`, mutate plasmid during divide, charge plasmid tax (Tasks 3, 5)
- `lib/lenies/codeome/opcodes.ex` — append `:make_plasmid`, `:conjugate` (Task 4)
- `lib/lenies/codeome/costs.ex` — costs for the new opcodes (Task 4)
- `lib/lenies/interpreter.ex` — dispatch entries for `:make_plasmid` and `:conjugate` (Tasks 4, 5)
- `lib/lenies_web/live/dashboard_live.ex` — subscribe to `"world:fx"`, forward to client (Task 7)
- `assets/js/hooks/grid_canvas.js` — handle `fx_conjugation` events, render flash overlay (Task 7)
- `config/runtime.exs` — bump `codeome_length_bounds` to `{3, 1000}` (Task 3)
- `test/lenies/codeomes/*_test.exs` — full suite still passes after each task

---

## Task 1: `%Plasmid{}` struct

**Goal**: Create a minimal struct module that all subsequent tasks can depend on. Pure data, no behavior.

**Files:**
- Create: `lib/lenies/plasmid.ex`
- Create: `test/lenies/plasmid_test.exs`

- [ ] **Step 1.1: Write the failing test**

Create `test/lenies/plasmid_test.exs`:

```elixir
defmodule Lenies.PlasmidTest do
  use ExUnit.Case, async: true
  alias Lenies.Plasmid

  test "new/1 builds a struct from a list of opcodes" do
    p = Plasmid.new([:eat, :move, :turn_left])
    assert %Plasmid{opcodes: [:eat, :move, :turn_left]} = p
  end

  test "size/1 returns the opcode count" do
    assert Plasmid.size(Plasmid.new([:eat, :move])) == 2
    assert Plasmid.size(Plasmid.new([])) == 0
  end

  test "valid_length?/1 enforces [1, 64]" do
    refute Plasmid.valid_length?(0)
    assert Plasmid.valid_length?(1)
    assert Plasmid.valid_length?(64)
    refute Plasmid.valid_length?(65)
    refute Plasmid.valid_length?(-1)
  end
end
```

- [ ] **Step 1.2: Run the test to verify it fails**

```bash
export PATH="$HOME/.asdf/installs/elixir/1.19.3-otp-28/bin:$HOME/.asdf/installs/erlang/28.1.1/bin:$PATH"
cd /home/patrick/projects/playground/Lenies
mix test test/lenies/plasmid_test.exs
```

Expected: compilation error `Lenies.Plasmid is undefined`.

- [ ] **Step 1.3: Write the module**

Create `lib/lenies/plasmid.ex`:

```elixir
defmodule Lenies.Plasmid do
  @moduledoc """
  A short opcode buffer that a Lenie can transfer to an adjacent Lenie via
  the `:conjugate` opcode. Plasmids inherit vertically through `:divide`
  alongside the codeome, and spread horizontally through conjugation.

  The MVP enforces a hard length cap of 64 opcodes per plasmid. The buffer
  is a plain Elixir list (not a tuple like `Lenies.Codeome`) because
  plasmids are small and the cost of `Tuple.to_list` round-trips would
  dominate. See `docs/superpowers/specs/2026-05-19-plasmid-conjugation-design.md`.
  """

  @max_length 64

  defstruct opcodes: []

  @type t :: %__MODULE__{opcodes: [atom()]}

  @spec new([atom()]) :: t()
  def new(opcodes) when is_list(opcodes), do: %__MODULE__{opcodes: opcodes}

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{opcodes: ops}), do: length(ops)

  @doc "Whether `len` is in the valid range for `:make_plasmid` (1..64)."
  @spec valid_length?(integer()) :: boolean()
  def valid_length?(len) when is_integer(len), do: len >= 1 and len <= @max_length
  def valid_length?(_), do: false

  @spec max_length() :: pos_integer()
  def max_length, do: @max_length
end
```

- [ ] **Step 1.4: Run the test to verify it passes**

```bash
mix test test/lenies/plasmid_test.exs
```

Expected: `3 tests, 0 failures`.

- [ ] **Step 1.5: Run the full test suite**

```bash
mix test
```

Expected: all tests pass (355 currently after seed redesign + 3 new = 358).

- [ ] **Step 1.6: Commit**

```bash
git add lib/lenies/plasmid.ex test/lenies/plasmid_test.exs
git commit -m "feat(plasmid): add %Lenies.Plasmid{} struct with size and length validation

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Mutator helpers for opcode lists

**Goal**: Extend `Lenies.Mutator` with two helpers that work on bare opcode lists (not `%Codeome{}` structs). The plasmid struct holds a list; mutating it should not require packing/unpacking into a Codeome.

**Files:**
- Modify: `lib/lenies/mutator.ex`
- Modify: `test/lenies/mutator_test.exs` (if exists; create if not)

- [ ] **Step 2.1: Read existing test file or note its absence**

Run: `ls test/lenies/mutator_test.exs 2>/dev/null`. If it doesn't exist, this task creates it.

- [ ] **Step 2.2: Write the failing tests**

Append to `test/lenies/mutator_test.exs` (or create with the standard ExUnit boilerplate):

```elixir
defmodule Lenies.MutatorTest do
  use ExUnit.Case, async: true
  alias Lenies.Mutator

  describe "background_mutation_list/1" do
    test "single substitution on a non-empty list" do
      original = [:eat, :move, :turn_left, :turn_right]
      mutated = Mutator.background_mutation_list(original)
      assert length(mutated) == 4
      diff_count = Enum.zip(original, mutated) |> Enum.count(fn {a, b} -> a != b end)
      assert diff_count <= 1
    end

    test "empty list is returned unchanged" do
      assert Mutator.background_mutation_list([]) == []
    end
  end

  describe "copy_mutate_list/4" do
    test "rate 0.0 reproduces the input exactly" do
      original = [:eat, :move, :turn_left]
      assert Mutator.copy_mutate_list(original, 0.0, 0.0, 0.0) == original
    end

    test "rate 1.0 substitution changes every opcode" do
      # With sub=1.0, every opcode is replaced by a random one from the
      # whitelist. The replacement might match by chance, but for 100
      # opcodes it's overwhelmingly unlikely all 100 match.
      original = List.duplicate(:eat, 100)
      mutated = Mutator.copy_mutate_list(original, 1.0, 0.0, 0.0)
      assert length(mutated) == 100
      refute mutated == original
    end

    test "rate 1.0 delete returns empty list" do
      original = List.duplicate(:eat, 20)
      assert Mutator.copy_mutate_list(original, 0.0, 0.0, 1.0) == []
    end
  end
end
```

- [ ] **Step 2.3: Run tests to verify they fail**

```bash
mix test test/lenies/mutator_test.exs
```

Expected: `(UndefinedFunctionError) function Lenies.Mutator.background_mutation_list/1 is undefined`.

- [ ] **Step 2.4: Add helper functions to `lib/lenies/mutator.ex`**

Append (do NOT replace existing functions; add inside the module):

```elixir
  @doc """
  Apply a single random substitution to a plain opcode list. Returns the
  list unchanged if empty.
  """
  @spec background_mutation_list([atom()]) :: [atom()]
  def background_mutation_list([]), do: []

  def background_mutation_list(opcodes) when is_list(opcodes) do
    n = length(opcodes)
    pos = :rand.uniform(n) - 1
    new_op = random_opcode()
    List.replace_at(opcodes, pos, new_op)
  end

  @doc """
  Apply per-opcode copy mutations to a list. For each opcode, rolls
  substitution → insert → delete dice in that order; the first hit
  determines the outcome (same convention as `copy_outcome/1`). Insertions
  add a random opcode immediately after the current one; deletions drop
  the current opcode.

  Returns the mutated list.
  """
  @spec copy_mutate_list([atom()], float(), float(), float()) :: [atom()]
  def copy_mutate_list(opcodes, sub_rate, ins_rate, del_rate)
      when is_list(opcodes) and is_float(sub_rate) and is_float(ins_rate) and is_float(del_rate) do
    rates = %{substitution: sub_rate, insert: ins_rate, delete: del_rate}

    Enum.flat_map(opcodes, fn op ->
      case copy_outcome(rates) do
        :write -> [op]
        :substitute -> [random_opcode()]
        :insert -> [op, random_opcode()]
        :delete -> []
      end
    end)
  end
```

- [ ] **Step 2.5: Run tests to verify they pass**

```bash
mix test test/lenies/mutator_test.exs
```

Expected: `5 tests, 0 failures` (the 2 in Task 2 plus 3 newly added).

- [ ] **Step 2.6: Run the full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 2.7: Commit**

```bash
git add lib/lenies/mutator.ex test/lenies/mutator_test.exs
git commit -m "feat(mutator): add list-flavored copy_mutate and background helpers

Used by plasmid mutation paths where the buffer is a plain Elixir list
rather than a Codeome struct. Mirrors copy_outcome semantics opcode-by-
opcode for copy mutations and a single random substitution for background.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Lenie `plasmids` field + propagation + config bump

**Goal**: Add the `plasmids: []` field to `Lenie` state; thread it through `spawn_lenie` and `spawn_child`; apply copy mutation to the plasmid during divide; bump `codeome_length_bounds` to give plasmid accumulation room.

**Files:**
- Modify: `lib/lenies/lenie.ex` — defstruct + init + maybe_write_snapshot
- Modify: `lib/lenies/world.ex` — spawn_lenie / spawn_child plasmid passthrough + mutation
- Modify: `config/runtime.exs` — bump codeome_length_bounds upper to 1000
- Modify: `test/lenies/lenie_test.exs` (or create if absent)

- [ ] **Step 3.1: Bump `codeome_length_bounds` in `config/runtime.exs`**

Find the line `codeome_length_bounds: {3, 500}` (or similar; the current upper bound). Change to:

```elixir
codeome_length_bounds: {3, 1000},
```

Run a quick sanity build:

```bash
mix compile --warnings-as-errors 2>&1 | tail -5
```

Expected: clean compile.

- [ ] **Step 3.2: Add `plasmids` field to `Lenies.Lenie` defstruct**

Open `lib/lenies/lenie.ex`. Find the defstruct:

```elixir
  defstruct [
    :id,
    :codeome,
    :interp,
    :lineage,
    :seed_origin,
    batch_count: 0,
    paused?: false
  ]
```

Add `plasmids: []` at the end:

```elixir
  defstruct [
    :id,
    :codeome,
    :interp,
    :lineage,
    :seed_origin,
    batch_count: 0,
    paused?: false,
    plasmids: []
  ]
```

- [ ] **Step 3.3: Accept `plasmids` opt in `Lenie.init/1`**

In `Lenie.init/1`, the existing block reads several keyword opts (`id`, `codeome`, `energy`, etc.). Add:

```elixir
    plasmids = Keyword.get(opts, :plasmids, [])
```

And include in the `state = %__MODULE__{...}` construction:

```elixir
    state = %__MODULE__{
      id: id,
      codeome: codeome,
      interp: interp,
      lineage: lineage,
      seed_origin: seed_origin,
      batch_count: 0,
      paused?: paused?,
      plasmids: plasmids
    }
```

- [ ] **Step 3.4: Include `plasmids` in snapshots**

In `Lenie.maybe_write_snapshot/1`, the `new_snap` map currently has these keys:
`id, pid, pos, dir, energy, age, ip, codeome_hash, lineage, seed_origin`.

Add `plasmids: state.plasmids` after `seed_origin`:

```elixir
      new_snap = %{
        id: state.id,
        pid: self(),
        pos: state.interp.pos,
        dir: state.interp.dir,
        energy: state.interp.energy,
        age: state.interp.age,
        ip: state.interp.ip,
        codeome_hash: Lenies.Codeome.hash(state.codeome),
        lineage: state.lineage,
        seed_origin: state.seed_origin,
        plasmids: state.plasmids
      }
```

- [ ] **Step 3.5: Pass `plasmids` from `World.spawn_lenie` to child_opts**

In `lib/lenies/world.ex`, the `handle_call({:spawn_lenie, codeome, opts}, _from, state)` clause builds `child_opts`. Add `plasmids` read from opts:

```elixir
        plasmids = Keyword.get(opts, :plasmids, [])

        child_opts = [
          id: lenie_id,
          codeome: codeome,
          energy: energy * 1.0,
          pos: pos,
          dir: dir,
          lineage: lineage,
          seed_origin: seed_origin,
          paused?: state.paused?,
          plasmids: plasmids
        ]
```

- [ ] **Step 3.6: Propagate + mutate `plasmids` in `World.spawn_child`**

In `lib/lenies/world.ex`, find `defp spawn_child(...)`. This is where the parent's state is read (via `parent_record`) when divide resolves. Read the parent's plasmids and apply copy mutation:

```elixir
  defp spawn_child(parent_id, parent_record, slot_id, slot, parent_energy, state) do
    child_id = generate_child_id()
    child_energy = trunc(parent_energy / 2)
    child_codeome = Codeome.from_list(Tuple.to_list(slot.opcodes))
    parent_generation = parent_record |> Map.get(:lineage, {nil, 0}) |> elem(1)
    parent_seed_origin = Map.get(parent_record, :seed_origin)

    parent_plasmids = Map.get(parent_record, :plasmids, [])
    child_plasmids = mutate_plasmids(parent_plasmids)

    child_opts = [
      id: child_id,
      codeome: child_codeome,
      energy: child_energy * 1.0,
      pos: slot.target_cell,
      dir: parent_record.dir,
      lineage: {parent_id, parent_generation + 1},
      seed_origin: parent_seed_origin,
      paused?: state.paused?,
      plasmids: child_plasmids
    ]

    # ... rest unchanged
```

And add the helper at the bottom of `world.ex` (private function area):

```elixir
  defp mutate_plasmids(plasmids) when is_list(plasmids) do
    sub_rate = Application.get_env(:lenies, :copy_substitution_rate, 0.005)
    ins_rate = Application.get_env(:lenies, :copy_insert_rate, 0.0)
    del_rate = Application.get_env(:lenies, :copy_delete_rate, 0.0)

    Enum.map(plasmids, fn %Lenies.Plasmid{opcodes: ops} = p ->
      %{p | opcodes: Lenies.Mutator.copy_mutate_list(ops, sub_rate, ins_rate, del_rate)}
    end)
  end
```

- [ ] **Step 3.7: Write integration test for vertical inheritance**

Append to `test/lenies/codeomes/minimal_replicator_test.exs` (or create a new `test/lenies/plasmid_inheritance_test.exs` following the seed test boilerplate):

```elixir
defmodule Lenies.PlasmidInheritanceTest do
  use ExUnit.Case, async: false

  alias Lenies.{Lenie, Plasmid, World}
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

  test "child inherits parent's plasmid through divide" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(:cells, {x, y})
      :ets.insert(:cells, {key, %{cell | resource: 200}})
    end

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "PARENT"}})

    parent_plasmid = Plasmid.new([:eat, :move, :turn_left])

    {:ok, pid} =
      Lenie.start_link(
        id: "PARENT",
        codeome: MinimalReplicator.codeome(),
        energy: 10_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0},
        plasmids: [parent_plasmid]
      )

    Process.unlink(pid)

    deadline = System.monotonic_time(:millisecond) + 30_000

    child_with_plasmid = poll_until(deadline, fn ->
      :ets.tab2list(:lenies)
      |> Enum.find_value(fn {id, snap} ->
        if id != "PARENT" and Map.get(snap, :plasmids, []) != [] do
          {:done, snap}
        else
          nil
        end
      end) || :continue
    end)

    assert is_map(child_with_plasmid),
           "expected at least one child Lenie to have inherited the plasmid within 30s"

    assert [%Plasmid{opcodes: [:eat, :move, :turn_left]}] = child_with_plasmid.plasmids
  end

  defp poll_until(deadline, fun) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      nil
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

- [ ] **Step 3.8: Run the new test**

```bash
mix test test/lenies/plasmid_inheritance_test.exs
```

Expected: 1 test passes.

- [ ] **Step 3.9: Run the full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 3.10: Commit**

```bash
git add lib/lenies/lenie.ex lib/lenies/world.ex config/runtime.exs test/lenies/plasmid_inheritance_test.exs
git commit -m "feat(plasmid): plasmids field on Lenie with vertical inheritance

- Lenie defstruct gets plasmids: [] field
- World.spawn_lenie and spawn_child propagate the field via child_opts
- Plasmids are copy-mutated during divide using copy_*_rate config values
- Snapshot includes plasmids so the inspector can see them
- codeome_length_bounds upper bumped from 500 to 1000 to allow accumulation

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `:make_plasmid` opcode

**Goal**: A new pure-VM opcode that pops `length` and `start_addr` from the stack, slices the Lenie's own codeome over that range (with toroidal wrap), and stores the result as the Lenie's plasmid. Push 1 on success, 0 on validation failure.

**Files:**
- Modify: `lib/lenies/codeome/opcodes.ex` — add `:make_plasmid` to the whitelist
- Modify: `lib/lenies/codeome/costs.ex` — add cost formula
- Modify: `lib/lenies/interpreter.ex` — dispatch entry
- Create: `test/lenies/interpreter/make_plasmid_test.exs`

This task introduces the first novel opcode mechanic: writing to `state.plasmids` from inside `dispatch/4`. The Interpreter currently dispatches pure ops on `State.t()` (which doesn't have plasmids — that's on the Lenie process). For this MVP we extend the `State` struct to also carry plasmids; the Lenie's `handle_info` already keeps `state.interp` in sync, so plasmid changes inside `dispatch` propagate to the Lenie state.

- [ ] **Step 4.1: Verify the Interpreter `State` struct location**

```bash
grep -n "defstruct" /home/patrick/projects/playground/Lenies/lib/lenies/interpreter/state.ex
```

Expected: see the struct keys (energy, age, pos, dir, stack, slots, ip, call_stack).

- [ ] **Step 4.2: Add `plasmids: []` to `State` struct**

Open `lib/lenies/interpreter/state.ex`. Find the defstruct and add `plasmids: []` at the end:

```elixir
  defstruct energy: 0.0,
            age: 0,
            pos: {0, 0},
            dir: :n,
            ip: 0,
            stack: [],
            slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
            call_stack: [],
            plasmids: []
```

- [ ] **Step 4.3: Sync plasmids in the Lenie's state struct with interp.plasmids**

The Lenie struct already holds `plasmids`. The interp has its own. They must agree. In `Lenie.init/1`, when constructing the interp via `State.new(...)`, also pass plasmids:

```elixir
    interp = State.new(energy: energy, pos: pos, dir: dir)
    interp = %{interp | plasmids: plasmids}
```

Then in `Lenie.age_and_continue/2`, the `state.plasmids` must mirror `new_interp.plasmids`:

```elixir
  defp age_and_continue(state, new_interp) do
    new_interp = %{new_interp | age: new_interp.age + 1}
    new_batch_count = state.batch_count + 1

    new_state = %{
      state
      | interp: new_interp,
        batch_count: new_batch_count,
        plasmids: new_interp.plasmids
    }

    maybe_write_snapshot(new_state)
    schedule_metabolize()
    new_state
  end
```

- [ ] **Step 4.4: Add `:make_plasmid` to opcode whitelist**

In `lib/lenies/codeome/opcodes.ex`, append `:make_plasmid` to `@opcodes` AFTER `:load`:

```elixir
  @opcodes [
    # ... existing entries ...
    :store,
    :load,
    # Plasmid / horizontal gene transfer
    :make_plasmid,
    :conjugate
  ]
```

(Include `:conjugate` now too even though Task 5 implements its dispatch — keeps the whitelist coherent.)

- [ ] **Step 4.5: Add costs**

In `lib/lenies/codeome/costs.ex`, add two clauses BEFORE the fallback `def cost(_, _), do: 0.1`:

```elixir
  # Plasmid creation: 2.0 base + 0.05 per opcode copied.
  # The `template_len` parameter is repurposed by the interpreter to carry
  # the actual length argument (top of stack at dispatch time).
  def cost(:make_plasmid, length) when is_integer(length) and length > 0 do
    Float.round(2.0 + 0.05 * length, 10)
  end

  def cost(:make_plasmid, _), do: 2.0

  # Conjugation: 4.0 base + 0.05 per opcode transferred. Same parameter
  # repurposing.
  def cost(:conjugate, plasmid_size) when is_integer(plasmid_size) and plasmid_size > 0 do
    Float.round(4.0 + 0.05 * plasmid_size, 10)
  end

  def cost(:conjugate, _), do: 4.0
```

- [ ] **Step 4.6: Write the failing test**

Create `test/lenies/interpreter/make_plasmid_test.exs`:

```elixir
defmodule Lenies.Interpreter.MakePlasmidTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter, Plasmid}
  alias Lenies.Interpreter.State

  defp run_one(state, codeome) do
    {:cont, new_state} = Interpreter.run_k_instructions(state, codeome, 1)
    new_state
  end

  defp build_codeome_with_make_plasmid do
    # Codeome layout: pushN[...arbitrary 10 ops...], push 0, push 4, :make_plasmid
    # After execution from IP=0: we want the IP to land on :make_plasmid with
    # [0, 4] on the stack.
    Codeome.from_list([
      :push0, :push1, :push1, :push1, :add, :add,  # build 3 on stack (for slot index)
      :push0, :store,                                # store 3 in slot[0] (junk)
      :push0,                                        # start_addr = 0
      :push1, :push1, :push1, :push1, :add, :add,   # length = 3 ... hmm, complex
      :make_plasmid
    ])
  end

  test ":make_plasmid with valid args creates plasmid and pushes 1" do
    # Build a 10-opcode codeome and seed the interp stack directly: [start=0, length=4]
    codeome = Codeome.from_list([
      :eat, :move, :turn_left, :turn_right, :defend,
      :sense_front, :drop, :eat, :move, :make_plasmid
    ])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> State.push(0)    # start_addr
      |> State.push(4)    # length (top)
      |> Map.put(:ip, 9)  # jump straight to :make_plasmid

    new_state = run_one(state, codeome)

    # Top of stack should be 1 (success). Plasmid should contain
    # codeome[0..3] = [:eat, :move, :turn_left, :turn_right].
    assert [1 | _] = new_state.stack
    assert [%Plasmid{opcodes: [:eat, :move, :turn_left, :turn_right]}] = new_state.plasmids
    assert new_state.energy == 100.0 - (2.0 + 0.05 * 4)
  end

  test ":make_plasmid with length=0 pushes 0 and does not create plasmid" do
    codeome = Codeome.from_list([:eat, :move, :make_plasmid])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> State.push(0)
      |> State.push(0)
      |> Map.put(:ip, 2)

    new_state = run_one(state, codeome)

    assert [0 | _] = new_state.stack
    assert new_state.plasmids == []
    assert new_state.energy == 100.0 - 2.0
  end

  test ":make_plasmid with length=65 pushes 0" do
    codeome = Codeome.from_list([:eat, :move, :make_plasmid])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> State.push(0)
      |> State.push(65)
      |> Map.put(:ip, 2)

    new_state = run_one(state, codeome)

    assert [0 | _] = new_state.stack
    assert new_state.plasmids == []
  end

  test ":make_plasmid wraps start_addr toroidally" do
    codeome = Codeome.from_list([:eat, :move, :turn_left, :make_plasmid])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> State.push(4)   # start_addr 4, wraps to (4 mod 4) = 0
      |> State.push(2)
      |> Map.put(:ip, 3)

    new_state = run_one(state, codeome)

    assert [%Plasmid{opcodes: [:eat, :move]}] = new_state.plasmids
  end

  test ":make_plasmid replaces an existing plasmid" do
    codeome = Codeome.from_list([:eat, :move, :make_plasmid])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> Map.put(:plasmids, [Plasmid.new([:turn_left, :turn_right])])
      |> State.push(0)
      |> State.push(2)
      |> Map.put(:ip, 2)

    new_state = run_one(state, codeome)

    assert [%Plasmid{opcodes: [:eat, :move]}] = new_state.plasmids
  end
end
```

- [ ] **Step 4.7: Run tests to verify they fail**

```bash
mix test test/lenies/interpreter/make_plasmid_test.exs
```

Expected: failures (dispatch not implemented yet).

- [ ] **Step 4.8: Add dispatch in `lib/lenies/interpreter.ex`**

Find an appropriate spot among the existing `defp dispatch(:atom, ...)` clauses (e.g., right after `:load`). Add:

```elixir
  defp dispatch(:make_plasmid, state, codeome, size) do
    {length, s1} = State.pop(state)
    {start_addr, s2} = State.pop(s1)

    if Lenies.Plasmid.valid_length?(length) do
      ops =
        for i <- 0..(length - 1) do
          Codeome.at(codeome, start_addr + i)
        end

      new_plasmid = Lenies.Plasmid.new(ops)
      cost = Costs.cost(:make_plasmid, length)

      s2
      |> State.push(1)
      |> Map.put(:plasmids, [new_plasmid])
      |> State.apply_cost(cost)
      |> advance(:make_plasmid, size, 1, halt_if_dead: true)
    else
      cost = Costs.cost(:make_plasmid, 0)

      s2
      |> State.push(0)
      |> State.apply_cost(cost)
      |> advance(:make_plasmid, size, 1, halt_if_dead: true)
    end
  end
```

> NOTE: `advance/4` is a helper that may or may not exist with that exact signature; check the existing dispatch entries (e.g., the `:read_self` clause uses `advance_and_charge`). Adapt to the existing pattern. The key requirements: advance IP by 1, apply the computed cost, push the success/failure marker, halt if energy hits 0.

A minimal pattern matching what the rest of the file uses:

```elixir
  defp dispatch(:make_plasmid, state, codeome, size) do
    {length, s1} = State.pop(state)
    {start_addr, s2} = State.pop(s1)

    if Lenies.Plasmid.valid_length?(length) do
      ops = for i <- 0..(length - 1), do: Codeome.at(codeome, start_addr + i)
      new_plasmid = Lenies.Plasmid.new(ops)

      s2
      |> State.push(1)
      |> Map.put(:plasmids, [new_plasmid])
      |> State.apply_cost(Costs.cost(:make_plasmid, length))
      |> bump_ip(size)
      |> halt_if_dead()
    else
      s2
      |> State.push(0)
      |> State.apply_cost(Costs.cost(:make_plasmid, 0))
      |> bump_ip(size)
      |> halt_if_dead()
    end
  end
```

If `bump_ip/2` and `halt_if_dead/1` don't exist, look at how `:get_size` and `:read_self` chain `State.push(...) |> advance_and_charge(...)`. The helper to use is whichever already manages IP+cost in a single call. Mirror that exactly — don't invent new helpers.

- [ ] **Step 4.9: Run tests to verify they pass**

```bash
mix test test/lenies/interpreter/make_plasmid_test.exs
```

Expected: `5 tests, 0 failures`.

- [ ] **Step 4.10: Run the full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 4.11: Commit**

```bash
git add lib/lenies/codeome/opcodes.ex lib/lenies/codeome/costs.ex lib/lenies/interpreter.ex lib/lenies/interpreter/state.ex lib/lenies/lenie.ex test/lenies/interpreter/make_plasmid_test.exs
git commit -m "feat(opcode): :make_plasmid creates plasmid from codeome range

Pops [start_addr, length] from stack. Validates length in [1, 64];
slices codeome with toroidal wrap and stores as the Lenie's plasmid
(replacing any prior). Pushes 1 on success, 0 on invalid args.

Cost: 2.0 + 0.05 × length (success) or 2.0 (validation failure).

Adds :conjugate to the whitelist as a placeholder — its dispatch
arrives in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `:conjugate` opcode + `receive_plasmid` handler + divide tax

**Goal**: Wire the cross-process conjugation flow. The donor Lenie executes `:conjugate`, which (a) pre-checks the front cell via `:cells` ETS, (b) calls `Lenies.Lenie.receive_plasmid(recipient_pid, opcodes)` synchronously, (c) pushes 1/0 to its own stack based on the call result, (d) pays the appropriate cost. Also add the divide-time tax of `0.5 × plasmid_size` to the parent's energy when divide succeeds.

**Files:**
- Modify: `lib/lenies/lenie.ex` — add `receive_plasmid/2` + `handle_call({:receive_plasmid, opcodes}, ...)`, divide tax in `apply_world_action({:divide, ...}, ...)`
- Modify: `lib/lenies/interpreter.ex` — dispatch `:conjugate` as a world-bound opcode (`{:wait_world, {:conjugate, pos, dir, plasmid_opcodes}, new_state}`) so the Lenie's apply_world_action can issue the GenServer.call (which can't be done from inside the interpreter — it doesn't have access to the world).
- Create: `test/lenies/conjugation_test.exs`

> **Design subtlety**: pure dispatch can't issue a GenServer.call (it would block the Interpreter, and the interpreter has no PID context). Instead, `:conjugate` follows the same "wait for world" pattern as `:eat`, `:move`, `:divide`, etc. — it emits `{:wait_world, action, state}` from dispatch, and the Lenie's `apply_world_action` carries out the call.

- [ ] **Step 5.1: Add `receive_plasmid/2` public API + handle_call to `Lenies.Lenie`**

In `lib/lenies/lenie.ex`, after the existing public API functions:

```elixir
  @doc """
  Synchronous call invoked by another Lenie's `:conjugate` opcode. Appends
  the plasmid opcodes to this Lenie's codeome and replaces its plasmid
  buffer. Returns `:ok` on success, `{:error, :too_large}` if appending
  would exceed `codeome_length_bounds`.
  """
  @spec receive_plasmid(pid(), [atom()]) :: :ok | {:error, :too_large}
  def receive_plasmid(pid, plasmid_opcodes) when is_pid(pid) and is_list(plasmid_opcodes) do
    GenServer.call(pid, {:receive_plasmid, plasmid_opcodes})
  end
```

And in the `handle_call` clauses block:

```elixir
  def handle_call({:receive_plasmid, plasmid_opcodes}, _from, state) do
    current_size = Lenies.Codeome.size(state.codeome)
    new_size = current_size + length(plasmid_opcodes)
    {_min, max} = Application.get_env(:lenies, :codeome_length_bounds, {3, 1000})

    if new_size > max do
      {:reply, {:error, :too_large}, state}
    else
      new_codeome =
        state.codeome
        |> Lenies.Codeome.to_list()
        |> Kernel.++(plasmid_opcodes)
        |> Lenies.Codeome.from_list()

      new_plasmid = Lenies.Plasmid.new(plasmid_opcodes)
      new_state = %{state | codeome: new_codeome, plasmids: [new_plasmid]}

      cache_codeome_by_hash(new_codeome)

      {:reply, :ok, new_state}
    end
  end
```

- [ ] **Step 5.2: Add `:conjugate` dispatch in `lib/lenies/interpreter.ex`**

Add a new dispatch clause that emits a `:wait_world` action:

```elixir
  defp dispatch(:conjugate, state, _codeome, size) do
    plasmid_opcodes =
      case state.plasmids do
        [%Lenies.Plasmid{opcodes: ops} | _] -> ops
        _ -> []
      end

    # IP advances; cost is applied by apply_world_action based on outcome.
    new_state = %{state | ip: rem(state.ip + 1, size)}
    {:wait_world, {:conjugate, state.pos, state.dir, plasmid_opcodes}, new_state}
  end
```

- [ ] **Step 5.3: Add `apply_world_action({:conjugate, ...}, ...)` in `lib/lenies/lenie.ex`**

After the other apply_world_action clauses:

```elixir
  defp apply_world_action({:conjugate, pos, dir, plasmid_opcodes}, _id, interp) do
    cond do
      plasmid_opcodes == [] ->
        # No plasmid — base cost, push 0.
        new_interp =
          interp
          |> Lenies.Interpreter.State.push(0)
          |> Lenies.Interpreter.State.apply_cost(Lenies.Codeome.Costs.cost(:conjugate, 0))

        {:ok, new_interp}

      true ->
        target_pos = front_cell(pos, dir)

        case :ets.lookup(:cells, target_pos) do
          [{_, %{lenie_id: nil}}] ->
            base_cost(interp, 0)

          [{_, %{lenie_id: recipient_id}}] when is_binary(recipient_id) ->
            case Lenies.Registry.whereis(recipient_id) do
              recipient_pid when is_pid(recipient_pid) ->
                attempt_transfer(interp, recipient_pid, plasmid_opcodes)

              nil ->
                base_cost(interp, 0)
            end

          _ ->
            base_cost(interp, 0)
        end
    end
  end

  defp front_cell({x, y}, :n), do: {x, rem(y - 1 + 256, 256)}
  defp front_cell({x, y}, :s), do: {x, rem(y + 1, 256)}
  defp front_cell({x, y}, :e), do: {rem(x + 1, 256), y}
  defp front_cell({x, y}, :w), do: {rem(x - 1 + 256, 256), y}

  defp base_cost(interp, plasmid_size) do
    new_interp =
      interp
      |> Lenies.Interpreter.State.push(0)
      |> Lenies.Interpreter.State.apply_cost(Lenies.Codeome.Costs.cost(:conjugate, plasmid_size))

    {:ok, new_interp}
  end

  defp attempt_transfer(interp, recipient_pid, plasmid_opcodes) do
    plasmid_size = length(plasmid_opcodes)

    case Lenies.Lenie.receive_plasmid(recipient_pid, plasmid_opcodes) do
      :ok ->
        Phoenix.PubSub.broadcast(
          Lenies.PubSub,
          "world:fx",
          {:conjugation, interp.pos, front_cell(interp.pos, interp.dir)}
        )

        new_interp =
          interp
          |> Lenies.Interpreter.State.push(1)
          |> Lenies.Interpreter.State.apply_cost(Lenies.Codeome.Costs.cost(:conjugate, plasmid_size))

        {:ok, new_interp}

      {:error, :too_large} ->
        # Receiver full — pay base cost only, push 0.
        new_interp =
          interp
          |> Lenies.Interpreter.State.push(0)
          |> Lenies.Interpreter.State.apply_cost(Lenies.Codeome.Costs.cost(:conjugate, 0))

        {:ok, new_interp}
    end
  end
```

> If `Lenies.Registry.lookup/1` returns something different from `{:ok, pid}`, check its actual signature in `lib/lenies/registry.ex` and adapt. The Lenie's id-to-pid mapping is what's needed.

- [ ] **Step 5.4: Add divide tax**

In the existing `apply_world_action({:divide, _new_energy, _pos, _dir}, ...)` clause, add a tax on success based on the Lenie's current plasmid size. The interp doesn't carry the size directly post-divide, but it can be computed from `interp.plasmids`:

```elixir
  defp apply_world_action({:divide, _new_energy, _pos, _dir}, id, interp) do
    case World.action({:divide, interp.energy, interp.pos, interp.dir, id}) do
      {:ok, {:divided, _child_id, energy_given}} ->
        plasmid_size =
          case interp.plasmids do
            [%Lenies.Plasmid{opcodes: ops} | _] -> length(ops)
            _ -> 0
          end

        tax = 0.5 * plasmid_size
        {:ok, %{interp | energy: interp.energy - energy_given - tax}}

      {:ok, _failure} ->
        {:ok, interp}
    end
  end
```

- [ ] **Step 5.5: Write end-to-end conjugation test**

Create `test/lenies/conjugation_test.exs`:

```elixir
defmodule Lenies.ConjugationTest do
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
    Application.put_env(:lenies, :codeome_length_bounds, {3, 1000})

    on_exit(fn ->
      Application.delete_env(:lenies, :copy_substitution_rate)
      Application.delete_env(:lenies, :copy_insert_rate)
      Application.delete_env(:lenies, :copy_delete_rate)
      Application.delete_env(:lenies, :background_mutation_rate_per_1000_ticks)
      Application.delete_env(:lenies, :eat_amount)
      Application.delete_env(:lenies, :interpreter_steps_per_batch)
      Application.delete_env(:lenies, :codeome_length_bounds)

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

  test "receive_plasmid appends to codeome and replaces plasmid buffer" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "RX"}})

    {:ok, recipient_pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move, :turn_left, :eat, :move]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(recipient_pid)

    plasmid_ops = [:turn_right, :turn_right, :defend]
    assert Lenie.receive_plasmid(recipient_pid, plasmid_ops) == :ok

    snapshot = :sys.get_state(recipient_pid)
    assert Codeome.size(snapshot.codeome) == 5 + 3
    assert Codeome.to_list(snapshot.codeome) ==
             [:eat, :move, :turn_left, :eat, :move, :turn_right, :turn_right, :defend]
    assert [%Plasmid{opcodes: ^plasmid_ops}] = snapshot.plasmids
  end

  test "receive_plasmid rejects oversize append" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 10})

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "RX"}})

    {:ok, recipient_pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move, :turn_left, :eat, :move, :turn_right, :eat, :move]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(recipient_pid)

    assert Lenie.receive_plasmid(recipient_pid, [:defend, :defend, :defend]) ==
             {:error, :too_large}

    snapshot = :sys.get_state(recipient_pid)
    assert Codeome.size(snapshot.codeome) == 8
    assert snapshot.plasmids == []
  end

  test ":conjugate with no plasmid pushes 0 and pays base cost" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    # A 2-opcode codeome: [:conjugate, :nop_0]. Place lenie alone; no front lenie.
    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "SOLO"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "SOLO",
        codeome: Codeome.from_list([:conjugate, :nop_0]),
        energy: 100.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    Process.sleep(200)

    snapshot = :sys.get_state(pid)
    # Energy should have dropped by exactly 4.0 (base cost), give or take
    # a few subsequent nop_0 charges (0.1 each).
    assert snapshot.interp.energy < 100.0 - 3.9
    assert hd(snapshot.interp.stack) == 0
  end

  test ":conjugate with plasmid and adjacent recipient transfers and pushes 1" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key1, c1}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key1, %{c1 | lenie_id: "TX"}})
    [{key2, c2}] = :ets.lookup(:cells, {129, 128})
    :ets.insert(:cells, {key2, %{c2 | lenie_id: "RX"}})

    {:ok, recipient_pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move]),
        energy: 5_000.0,
        pos: {129, 128},
        dir: :w,
        lineage: {nil, 0}
      )

    plasmid = Plasmid.new([:turn_left, :defend, :eat])

    {:ok, donor_pid} =
      Lenie.start_link(
        id: "TX",
        codeome: Codeome.from_list([:conjugate, :nop_0]),
        energy: 100.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0},
        plasmids: [plasmid]
      )

    Process.unlink(donor_pid)
    Process.unlink(recipient_pid)

    Process.sleep(300)

    donor_snap = :sys.get_state(donor_pid)
    recipient_snap = :sys.get_state(recipient_pid)

    # Donor still has its plasmid (transfer is a copy).
    assert [%Plasmid{opcodes: [:turn_left, :defend, :eat]}] = donor_snap.plasmids
    # Donor energy decreased by at least 4.0 + 3 * 0.05 = 4.15 base + extra ops.
    assert donor_snap.interp.energy < 100.0 - 4.1
    assert hd(donor_snap.interp.stack) == 1

    # Recipient codeome grew by 3 opcodes.
    assert Codeome.size(recipient_snap.codeome) == 5
    assert Codeome.to_list(recipient_snap.codeome) ==
             [:eat, :move, :turn_left, :defend, :eat]
    # Recipient now has the plasmid in its buffer too.
    assert [%Plasmid{opcodes: [:turn_left, :defend, :eat]}] = recipient_snap.plasmids
  end

  test ":conjugate broadcasts world:fx event on success" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:fx")

    [{key1, c1}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key1, %{c1 | lenie_id: "TX"}})
    [{key2, c2}] = :ets.lookup(:cells, {129, 128})
    :ets.insert(:cells, {key2, %{c2 | lenie_id: "RX"}})

    {:ok, recipient_pid} =
      Lenie.start_link(
        id: "RX",
        codeome: Codeome.from_list([:eat, :move]),
        energy: 5_000.0,
        pos: {129, 128},
        dir: :w,
        lineage: {nil, 0}
      )

    plasmid = Plasmid.new([:defend])

    {:ok, donor_pid} =
      Lenie.start_link(
        id: "TX",
        codeome: Codeome.from_list([:conjugate, :nop_0]),
        energy: 100.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0},
        plasmids: [plasmid]
      )

    Process.unlink(donor_pid)
    Process.unlink(recipient_pid)

    assert_receive {:conjugation, {128, 128}, {129, 128}}, 1000
  end
end
```

- [ ] **Step 5.6: Run the conjugation test**

```bash
mix test test/lenies/conjugation_test.exs
```

Expected: 5 tests pass.

- [ ] **Step 5.7: Run the full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 5.8: Commit**

```bash
git add lib/lenies/lenie.ex lib/lenies/interpreter.ex test/lenies/conjugation_test.exs
git commit -m "feat(opcode): :conjugate transfers plasmid to front Lenie

:conjugate emits a :wait_world action carrying the donor's plasmid opcodes
and the front cell address. apply_world_action looks up the recipient via
the cells ETS + Registry, then calls Lenie.receive_plasmid/2 which appends
the opcodes to the recipient's codeome and replaces its plasmid buffer.
Donor pays 4.0 base + 0.05 × plasmid_size on success; 4.0 on any failure
path (no plasmid, no front lenie, recipient full).

On success, broadcasts {:conjugation, sender_pos, receiver_pos} on the new
'world:fx' PubSub topic.

Divide gains an additional 0.5 × plasmid_size tax when the parent has a
plasmid, mirroring write_child's per-opcode cost but discounted because
the World handles the copy without explicit opcodes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Background mutation extended to plasmid

**Goal**: When the existing `:background_mutate` handler fires, mutate the plasmid buffer too (using the same probability budget). Reuses `Mutator.background_mutation_list/1` from Task 2.

**Files:**
- Modify: `lib/lenies/lenie.ex` — extend `handle_info(:background_mutate, ...)`
- Modify: `test/lenies/conjugation_test.exs` (append) or add `test/lenies/plasmid_mutation_test.exs`

- [ ] **Step 6.1: Write the failing test**

Append to `test/lenies/conjugation_test.exs` (inside the existing `defmodule` block, after the previous tests):

```elixir
  test "background_mutate mutates the plasmid buffer in place" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {128, 128})
    :ets.insert(:cells, {key, %{cell | lenie_id: "BG"}})

    original_plasmid = Plasmid.new(List.duplicate(:eat, 30))

    {:ok, pid} =
      Lenie.start_link(
        id: "BG",
        codeome: Codeome.from_list([:nop_0, :nop_0, :nop_0]),
        energy: 5_000.0,
        pos: {128, 128},
        dir: :n,
        lineage: {nil, 0},
        plasmids: [original_plasmid]
      )

    Process.unlink(pid)

    # Trigger background mutation directly.
    send(pid, :background_mutate)
    Process.sleep(100)

    snapshot = :sys.get_state(pid)
    [%Plasmid{opcodes: new_ops}] = snapshot.plasmids
    # At most one opcode changed (background mutation is a single-point sub).
    assert length(new_ops) == 30
    diff = Enum.zip(original_plasmid.opcodes, new_ops) |> Enum.count(fn {a, b} -> a != b end)
    assert diff <= 1
  end
```

- [ ] **Step 6.2: Run test to verify it fails**

```bash
mix test test/lenies/conjugation_test.exs
```

Expected: the new test fails because plasmids are not yet mutated.

- [ ] **Step 6.3: Extend `handle_info(:background_mutate, ...)` in `lib/lenies/lenie.ex`**

Replace the existing clause:

```elixir
  def handle_info(:background_mutate, state) do
    new_codeome = Lenies.Mutator.background_mutation(state.codeome)
    cache_codeome_by_hash(new_codeome)

    new_plasmids =
      Enum.map(state.plasmids, fn %Lenies.Plasmid{opcodes: ops} = p ->
        %{p | opcodes: Lenies.Mutator.background_mutation_list(ops)}
      end)

    new_interp = %{state.interp | plasmids: new_plasmids}

    {:noreply, %{state | codeome: new_codeome, plasmids: new_plasmids, interp: new_interp}}
  end
```

- [ ] **Step 6.4: Run the test to verify it passes**

```bash
mix test test/lenies/conjugation_test.exs
```

Expected: all 6 tests pass.

- [ ] **Step 6.5: Run the full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6.6: Commit**

```bash
git add lib/lenies/lenie.ex test/lenies/conjugation_test.exs
git commit -m "feat(plasmid): background mutation also mutates the plasmid buffer

The :background_mutate handler now applies a single random substitution
to the plasmid opcode list alongside the existing codeome mutation. The
interp's plasmids field is kept in sync.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: UI flash on conjugation

**Goal**: The dashboard subscribes to the new `"world:fx"` PubSub topic and pushes `fx_conjugation` events to the client. The canvas hook marks the two cells as flashing for 3 seconds (wall-clock, regardless of tick rate) and renders them with heightened saturation/luminosity that fades over the duration.

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex` — subscribe + handle_info forwarder
- Modify: `assets/js/hooks/grid_canvas.js` — event handler + flashing cells overlay

- [ ] **Step 7.1: Subscribe to `"world:fx"` in dashboard mount**

In `lib/lenies_web/live/dashboard_live.ex`, find the `mount/3` function. It almost certainly already subscribes to PubSub topics like `"world:tick"`. Add a subscription:

```elixir
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:control")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:fx")
    end
```

(Match the existing subscription style — `if connected?(socket)` guard if used elsewhere.)

- [ ] **Step 7.2: Handle `{:conjugation, sender, receiver}` and push to client**

Add a new `handle_info/2` clause grouped with other handle_info clauses:

```elixir
  def handle_info({:conjugation, sender_pos, receiver_pos}, socket) do
    {:noreply,
     push_event(socket, "fx_conjugation", %{
       sender: tuple_to_xy(sender_pos),
       receiver: tuple_to_xy(receiver_pos)
     })}
  end

  defp tuple_to_xy({x, y}), do: %{x: x, y: y}
```

(If `tuple_to_xy/1` already exists, reuse it.)

- [ ] **Step 7.3: Handle `fx_conjugation` in `assets/js/hooks/grid_canvas.js`**

Add to the hook's `mounted()` block, alongside existing `handleEvent` calls:

```javascript
    this.flashingCells = new Map(); // key: "x,y" -> { startMs, durationMs }

    this.handleEvent("fx_conjugation", ({ sender, receiver }) => {
      const now = performance.now();
      const durationMs = 3000;
      const expireAt = now + durationMs;

      this.flashingCells.set(`${sender.x},${sender.y}`, { startMs: now, expireAt });
      this.flashingCells.set(`${receiver.x},${receiver.y}`, { startMs: now, expireAt });
    });
```

In the canvas render loop (wherever cells are drawn — look for the function that iterates over `:cells` data or a `drawCell` helper), after drawing the normal cell color, apply the flash overlay:

```javascript
    // Inside the render function, after drawing the cell at (x, y):
    const flashKey = `${x},${y}`;
    const flash = this.flashingCells.get(flashKey);
    if (flash) {
      const now = performance.now();
      if (now >= flash.expireAt) {
        this.flashingCells.delete(flashKey);
      } else {
        const progress = (now - flash.startMs) / (flash.expireAt - flash.startMs);
        const alpha = 1 - progress; // fade from 1 to 0
        ctx.fillStyle = `rgba(255, 255, 200, ${alpha * 0.8})`;
        ctx.fillRect(cellPxX, cellPxY, cellPxW, cellPxH);
      }
    }
```

Substitute `cellPxX`, `cellPxY`, `cellPxW`, `cellPxH` with whatever the existing render code uses for per-cell pixel coordinates.

- [ ] **Step 7.4: Build the JS bundle**

```bash
cd /home/patrick/projects/playground/Lenies
mix esbuild default
```

Expected: clean compile.

- [ ] **Step 7.5: Manual verification**

This is a UI feature; automated test of the render is out of scope. Start the dev server:

```bash
iex -S mix phx.server
```

In the dashboard:
1. Pause the world.
2. Sterilize.
3. Open the codeome editor; spawn a Lenie with codeome `[:make_plasmid, :conjugate, :nop_0]` next to another spawned Lenie (use the Spawn N copies controls or seed at specific positions).
4. Resume. Watch for both cells flashing yellow-white when conjugation fires.

Note in commit: "Manual UI verification only; automated canvas-render test deferred."

- [ ] **Step 7.6: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex assets/js/hooks/grid_canvas.js
git commit -m "feat(dashboard): flash both cells on successful conjugation

Subscribes to 'world:fx' PubSub topic in dashboard mount, forwards
{:conjugation, sender, receiver} events to the client. grid_canvas hook
tracks a flashingCells map keyed by 'x,y' with expireAt timestamps and
overlays a fading yellow rectangle on each cell for 3 seconds wall-clock,
regardless of simulation tick rate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-review checklist (to run after all tasks complete)

Verify spec coverage:
- [ ] `Plasmid` struct exists with `opcodes: []` field — **Task 1**
- [ ] `:make_plasmid` opcode with stack args, cap 64, push 1/0 — **Task 4**
- [ ] `:conjugate` opcode with sender-push semantics, push 1/0 — **Task 5**
- [ ] Reception appends to both codeome and plasmid_buffer — **Task 5 (handle_call)**
- [ ] Vertical inheritance via `World.spawn_child` — **Task 3**
- [ ] Plasmid copy mutated with same rates as codeome — **Task 3 (mutate_plasmids)**
- [ ] Background mutation also mutates plasmid — **Task 6**
- [ ] Cost model: 2 + 0.05×len / 4 + 0.05×size / 0.5×size divide tax — **Tasks 4, 5**
- [ ] Codeome hash = codeome only (plasmid buffer not hashed) — **inherited from existing behavior, no change**
- [ ] Max codeome length bumped to 1000 — **Task 3**
- [ ] `:conjugate` fails if append would exceed bound — **Task 5**
- [ ] UI flash on conjugation, 3s wall-clock — **Task 7**
- [ ] Snapshot includes plasmids — **Task 3 (maybe_write_snapshot)**

## Risk notes

- **`State` struct change**: Task 4 adds `plasmids: []` to `Lenies.Interpreter.State`. Any code that pattern-matches on the State struct's keys with full coverage will need to be updated. Most call sites use map field access (`state.energy`, `state.stack`) which is robust. Audit `lib/lenies/interpreter/state.ex` and its consumers if you see test failures after Task 4.
- **`Lenies.Registry.whereis/1`**: Verified to return `pid | nil` (see `lib/lenies/registry.ex:25`). The plan code matches this signature.
- **Background mutation race**: Task 6 modifies `state.plasmids` and `state.interp.plasmids` in the same handle_info. If a metabolize tick fires between the two writes (it can't — handle_info is serialized per process), the interp could see a stale plasmid. Confirmed safe by Erlang's actor model.
- **Old snapshot files**: Snapshots saved before this feature won't have a `plasmids` field. `Map.get(snap, :plasmids, [])` is used everywhere; old snapshots default to `[]` cleanly.
- **Performance**: `:conjugate` is a synchronous `GenServer.call` — donor blocks for ~microseconds. If conjugation becomes very common in a steady-state population, this could become a hotspot. Mitigation: monitor `:erlang.statistics(:scheduler_wall_time)` in long runs; if needed, convert to `GenServer.cast` with a settled-by-next-tick semantic (lose synchronous push 1/0 result — needs design change).
