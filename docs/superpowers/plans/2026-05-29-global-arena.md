# Global Arena Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A shared, publicly-viewable `:arena` world at `/`. Anonymous viewers can watch; logged-in users seed from their personal collection, subject to "one alive lineage per user" — with an `Apoptosis` button to self-terminate that lineage and seed again. Sandbox dashboard moves under `/sandbox/...`.

**Architecture:** A new `Lenies.Arena` GenServer mirrors `Lenies.Sandboxes` but manages a single `:arena` world (presence-counted viewers, 30 s grace, snapshot+stop on empty, auto-restore on next viewer, adopt-on-restart). Lineage tracked via a new `seeder_user_id` field on Lenie state, propagated through replication, included in the per-Lenie ETS snapshot so `Lenies.Arena.lineage_count/1` is an `:ets.select`. Seed and apoptosis are atomic `GenServer.call`s. A new `LeniesWeb.ArenaLive` + `LeniesWeb.ArenaControlsComponent` render the read-mostly Arena. The 5 Sandbox routes migrate from `/`/`/lenie/:id`/etc. to `/sandbox/...`; only `/` is public, the rest stay behind login.

**Tech Stack:** Elixir 1.19, OTP 28, Phoenix 1.8, Phoenix LiveView 1.1, `Phoenix.Presence`, `Phoenix.PubSub`, multi-world engine from sub-project #2, sandbox lifecycle from sub-project #3.

**Spec:** `docs/superpowers/specs/2026-05-29-global-arena-design.md`

---

## File Structure

**Created:**
- `lib/lenies/arena.ex` — the Arena lifecycle GenServer + `seed/2`/`apoptosis/1`/`lineage_count/1`.
- `lib/lenies_web/presence.ex` — `use Phoenix.Presence`, topic `"arena:presence"`.
- `lib/lenies_web/live/arena_live.ex` — public ArenaLive.
- `lib/lenies_web/live/arena_controls_component.ex` — Arena's read-mostly control component (Seed + Apoptosis only).
- `test/lenies/arena_test.exs` — Arena manager + lineage + apoptosis unit tests.
- `test/lenies_web/live/arena_live_test.exs` — ArenaLive integration tests + route migration assertions.

**Modified:**
- `lib/lenies/lenie.ex` — add `seeder_user_id` to state struct, read from opts in `init/1`, include in `maybe_write_snapshot`.
- `lib/lenies/world.ex` — propagate `seeder_user_id` in the two `child_opts` construction sites (lines ~230-243 external spawn, ~795-810 post-gestation replication).
- `lib/lenies/application.ex` — add `Lenies.Arena` to children list after `Lenies.Sandboxes`.
- `lib/lenies_web/router.ex` — public scope for `/` + ArenaLive; sandbox routes move under `/sandbox/...`.
- `lib/lenies_web/user_auth.ex` — `signed_in_path/1` returns `~p"/sandbox"` (was `~p"/"`).
- `lib/lenies_web/live/dashboard_live.ex` — every `push_navigate(~p"/")` etc. updated to `~p"/sandbox..."`.
- `lib/lenies_web/live/editor_live.ex` — same path updates.
- `lib/lenies_web/live/lenie_inspector_live.ex`, `species_live.ex` — same.
- `lib/lenies_web/components/layouts.ex` (or wherever the root layout's navbar lives) — header with conditional auth/anon nav.
- All Sandbox LiveView tests in `test/lenies_web/live/*.exs` — `~p"/"`/`~p"/lenie/..."`/etc. → `~p"/sandbox..."`/`~p"/sandbox/lenie/..."`/etc.

**Stage-to-task mapping:**
- Stage A — Lineage tracking on Lenie state (T1–T2)
- Stage B — `Lenies.Arena` lifecycle manager (T3–T9)
- Stage C — Routing & path migration (T10–T11)
- Stage D — ArenaLive + ArenaControlsComponent + Presence (T12–T14)
- Stage E — Integration + final precommit (T15–T16)

---

## Task 1: Add `seeder_user_id` to Lenie state + snapshot

**Files:**
- Modify: `lib/lenies/lenie.ex`
- Test: `test/lenies/lenie_test.exs` (new test in the existing file)

- [ ] **Step 1: Failing test**

Open `test/lenies/lenie_test.exs`. Append a new describe block. (If the file uses `Lenies.WorldTestHelpers.start_test_world/1`, follow the same setup pattern.)

```elixir
  describe "seeder_user_id propagation (sub-project #4 lineage)" do
    setup do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
      %{world_id: world_id, handle: handle}
    end

    test "Lenie stores seeder_user_id from opts and writes it to its ETS snapshot",
         %{world_id: world_id, handle: handle} do
      codeome = Lenies.Seeds.get(:minimal_replicator).codeome
      {:ok, {id, _pos}} =
        Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0, seeder_user_id: 42)

      Process.sleep(50)  # let the Lenie process write its initial snapshot

      assert [{^id, snap}] = :ets.lookup(handle.tables.lenies, id)
      assert snap.seeder_user_id == 42
    end

    test "Lenie defaults seeder_user_id to nil when opt is absent",
         %{world_id: world_id, handle: handle} do
      codeome = Lenies.Seeds.get(:minimal_replicator).codeome
      {:ok, {id, _pos}} = Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0)
      Process.sleep(50)

      assert [{^id, snap}] = :ets.lookup(handle.tables.lenies, id)
      assert snap.seeder_user_id == nil
    end
  end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/lenie_test.exs'
```

Expected: FAIL — `Lenies.Lenie.start_link` doesn't accept `:seeder_user_id`; even if it did, the snapshot map doesn't contain it.

- [ ] **Step 3: Add the field to the Lenie state struct**

In `lib/lenies/lenie.ex`, locate the `defstruct [...]` block (around line 23). Add `:seeder_user_id` to the list with a default of `nil`:

```elixir
defstruct [
  # ...existing fields...
  :seeder_user_id   # nil for Sandbox/test Lenies; integer for Arena lineages
]
```

(Place it adjacent to `:seed_origin` if present, since they're semantically related — but order doesn't affect behaviour.)

- [ ] **Step 4: Read from opts in `init/1`**

In `lib/lenies/lenie.ex` `init({%Lenies.WorldHandle{} = handle, opts})` (around line 79), where the existing fields are pulled from opts (e.g. `Keyword.get(opts, :energy, 0.0)`, `Keyword.get(opts, :seed_origin, nil)`), add:

```elixir
seeder_user_id = Keyword.get(opts, :seeder_user_id, nil)
```

and include `seeder_user_id: seeder_user_id` in the `%__MODULE__{}` struct being assigned to `state`.

- [ ] **Step 5: Include `seeder_user_id` in the Lenie snapshot written to ETS**

Find `defp maybe_write_snapshot(state)` in `lib/lenies/lenie.ex` (around line 352). The snapshot is a map containing fields like `id`, `pos`, `dir`, `energy`, `codeome_hash`, `generation`, `lineage`, `seed_origin`, etc. Add `seeder_user_id: state.seeder_user_id` to that map.

- [ ] **Step 6: Verify the tests pass**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/lenie_test.exs'
```

Expected: both new tests pass; existing Lenie tests in the same file remain green.

Then full suite:

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0 --include integration'
```

Expected: all pass. (Adding a struct field with a nil default doesn't break any existing assertion.)

- [ ] **Step 7: Commit**

```bash
git add lib/lenies/lenie.ex test/lenies/lenie_test.exs
git commit -m "feat(lenie): seeder_user_id field on Lenie state, included in ETS snapshot"
```

---

## Task 2: Propagate `seeder_user_id` through replication

**Files:**
- Modify: `lib/lenies/world.ex` — both `child_opts` construction sites
- Test: `test/lenies/arena_test.exs` (new file — first test)

The two sites:
- `lib/lenies/world.ex` around line 230-243 — `child_opts` for external `{:spawn_lenie, ...}` requests. This site already accepts caller opts; we only need to confirm `seeder_user_id` flows through. (Probably already works because `Worlds.spawn_lenie/3` passes opts as a keyword list to the World, and the World's handler builds `child_opts` from a mix of caller opts + internal fields.)
- `lib/lenies/world.ex` around line 795-810 — `child_opts` after `:allocate`-driven gestation. This site builds `child_opts` purely from `parent_record` (the parent's snapshot row in `:lenies` ETS). It must read `parent_record.seeder_user_id` and include it.

- [ ] **Step 1: Failing test**

Create `test/lenies/arena_test.exs`:

```elixir
defmodule Lenies.ArenaTest do
  use ExUnit.Case, async: false

  describe "seeder_user_id propagation through replication" do
    setup do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
      %{world_id: world_id, handle: handle}
    end

    test "child Lenie inherits parent's seeder_user_id when replication occurs",
         %{world_id: world_id, handle: handle} do
      # Spawn a replicator tagged with seeder_user_id=7. Drive a few ticks
      # so it replicates at least once.
      codeome = Lenies.Seeds.get(:minimal_replicator).codeome
      {:ok, {parent_id, _pos}} =
        Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 10_000.0, seeder_user_id: 7)

      # Drive enough ticks to allow at least one allocate→gestation→spawn cycle.
      for _ <- 1..50 do
        :ok = Lenies.Worlds.tick_now(world_id)
      end
      Process.sleep(100)

      lenies = :ets.tab2list(handle.tables.lenies)
      assert length(lenies) >= 2, "expected at least parent + one child"

      # Every Lenie in this world (including children) must carry seeder_user_id=7.
      for {_id, snap} <- lenies do
        assert snap.seeder_user_id == 7,
               "child Lenie missing seeder_user_id; got #{inspect(snap.seeder_user_id)}"
      end

      refute parent_id in [], "sanity: parent was spawned"
    end
  end
end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: FAIL — the children have `seeder_user_id == nil` because the post-gestation site in `world.ex` doesn't read it from the parent record.

- [ ] **Step 3: Update the post-gestation `child_opts` (lib/lenies/world.ex ~ line 795)**

Find the `child_opts` keyword list construction at the post-gestation site (around lines 795-810). It currently looks something like:

```elixir
child_opts = [
  energy: child_energy,
  dir: parent_record.dir,
  lineage: {parent_id, parent_generation + 1},
  seed_origin: parent_seed_origin,
  paused?: state.paused?,
  plasmids: child_plasmids
]
```

Add `seeder_user_id: parent_record.seeder_user_id` to this list:

```elixir
child_opts = [
  energy: child_energy,
  dir: parent_record.dir,
  lineage: {parent_id, parent_generation + 1},
  seed_origin: parent_seed_origin,
  paused?: state.paused?,
  plasmids: child_plasmids,
  seeder_user_id: parent_record.seeder_user_id
]
```

(`parent_record` is the parent's ETS snapshot row; after Task 1 it carries `:seeder_user_id`.)

- [ ] **Step 4: Update the external-spawn `child_opts` (lib/lenies/world.ex ~ line 230)**

Find the external-spawn site (around lines 230-243). Check whether the existing code already threads caller opts through — typically the `child_opts` list there is built from a mix of caller-provided opts and World-internal fields. The caller (e.g. `Lenies.Worlds.spawn_lenie(world_id, codeome, [seeder_user_id: X, energy: Y])`) supplies `seeder_user_id` in the opts list.

If the handler currently does `child_opts = Keyword.merge(caller_opts, [paused?: state.paused?, plasmids: plasmids])` or equivalent, `seeder_user_id` already flows through (because it's in `caller_opts`). Verify by reading the surrounding code. If the construction is explicit (`[energy: ..., dir: ..., plasmids: ...]` listing only certain keys), then add `seeder_user_id: Keyword.get(caller_opts, :seeder_user_id, nil)` to that list.

- [ ] **Step 5: Verify the test passes**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: PASS — children inherit `seeder_user_id` from parent.

Then full suite:

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0 --include integration'
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/lenies/world.ex test/lenies/arena_test.exs
git commit -m "feat(world): propagate seeder_user_id from parent to child Lenies through replication"
```

---

## Task 3: `Lenies.Arena` skeleton + `attach_viewer/0`

**Files:**
- Create: `lib/lenies/arena.ex`
- Modify: `test/lenies/arena_test.exs`

- [ ] **Step 1: Failing test**

Append to `test/lenies/arena_test.exs`:

```elixir
  describe "Lenies.Arena lifecycle" do
    setup do
      start_supervised!({Lenies.Arena, []})
      :ok
    end

    test "first attach_viewer starts the :arena world" do
      :ok = Lenies.Arena.attach_viewer(self())
      assert Lenies.Worlds.alive?(:arena)
      :ok = Lenies.Worlds.stop_world(:arena)
    end
  end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: FAIL — `Lenies.Arena` is undefined.

- [ ] **Step 3: Create the module skeleton**

Create `lib/lenies/arena.ex`:

```elixir
defmodule Lenies.Arena do
  @moduledoc """
  Lifecycle manager for the single, publicly-viewable `:arena` world.

  Mirrors `Lenies.Sandboxes` but for a singleton world: attach on
  `LeniesWeb.ArenaLive` mount, `Process.monitor` the viewer pid,
  30 s grace timer on last detach, snapshot+stop on expiry, auto-restore
  from the `"auto"` snapshot on next first attach.

  Beyond lifecycle, owns the Arena's domain rules:

  - `seed/2` — atomic check-and-spawn (one alive lineage per user).
  - `apoptosis/1` — user-triggered self-terminate of their lineage.
  - `lineage_count/1` — count of a user's alive Lenies in the Arena.

  See `docs/superpowers/specs/2026-05-29-global-arena-design.md`.
  """
  use GenServer

  @world_id :arena

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Attach the calling viewer pid to the Arena. Idempotent; starts the world on first attach."
  @spec attach_viewer(pid) :: :ok | {:error, term}
  def attach_viewer(pid \\ self()), do: GenServer.call(__MODULE__, {:attach_viewer, pid})

  @impl true
  def init(_opts), do: {:ok, initial_state()}

  defp initial_state do
    %{
      started?: false,
      viewers: MapSet.new(),
      monitors: %{},
      pending_stop: nil,
      generation: 0
    }
  end

  @impl true
  def handle_call({:attach_viewer, pid}, _from, %{started?: false} = state) do
    case start_arena() do
      {:ok, _sup_pid} ->
        ref = Process.monitor(pid)
        new_state = %{state |
          started?: true,
          viewers: MapSet.put(state.viewers, pid),
          monitors: Map.put(state.monitors, pid, ref),
          generation: state.generation + 1
        }
        {:reply, :ok, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:attach_viewer, pid}, _from, %{started?: true} = state) do
    # Already started — add this pid (idempotent if same pid attaches twice).
    new_state =
      if MapSet.member?(state.viewers, pid) do
        %{state | generation: state.generation + 1}
      else
        ref = Process.monitor(pid)
        %{state |
          viewers: MapSet.put(state.viewers, pid),
          monitors: Map.put(state.monitors, pid, ref),
          generation: state.generation + 1
        }
      end

    {:reply, :ok, cancel_pending_stop(new_state)}
  end

  defp start_arena do
    case Lenies.Worlds.start_world(@world_id, %{}) do
      {:ok, sup_pid} -> {:ok, sup_pid}
      {:error, {:already_started, sup_pid}} -> {:ok, sup_pid}
      {:error, _} = err -> err
    end
  end

  defp cancel_pending_stop(%{pending_stop: nil} = state), do: state
  defp cancel_pending_stop(%{pending_stop: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | pending_stop: nil}
  end
end
```

- [ ] **Step 4: Verify the test passes**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: 2 tests pass (Task 2's replication test + the new first-attach test).

Compile clean:
```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix compile --warnings-as-errors'
```

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/arena.ex test/lenies/arena_test.exs
git commit -m "feat(arena): Lenies.Arena skeleton + attach_viewer/0 starts the :arena world"
```

---

## Task 4: `:DOWN` handling + grace timer + detach_viewer

**Files:**
- Modify: `lib/lenies/arena.ex`
- Modify: `test/lenies/arena_test.exs`

- [ ] **Step 1: Failing tests**

Append to the `describe "Lenies.Arena lifecycle"` block:

```elixir
    test "last viewer disconnect schedules grace timer; world still alive" do
      task =
        Task.async(fn ->
          :ok = Lenies.Arena.attach_viewer()
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(100)

      state = :sys.get_state(Lenies.Arena)
      assert MapSet.size(state.viewers) == 0
      refute is_nil(state.pending_stop)
      assert Lenies.Worlds.alive?(:arena)
      :ok = Lenies.Worlds.stop_world(:arena)
    end

    test "second viewer disconnect leaves first viewer attached, no grace timer" do
      :ok = Lenies.Arena.attach_viewer(self())
      task =
        Task.async(fn ->
          :ok = Lenies.Arena.attach_viewer()
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(100)

      state = :sys.get_state(Lenies.Arena)
      assert MapSet.size(state.viewers) == 1
      assert is_nil(state.pending_stop)
      :ok = Lenies.Worlds.stop_world(:arena)
    end

    test "explicit detach_viewer also schedules grace timer when last viewer leaves" do
      :ok = Lenies.Arena.attach_viewer(self())
      :ok = Lenies.Arena.detach_viewer(self())
      Process.sleep(50)

      state = :sys.get_state(Lenies.Arena)
      assert MapSet.size(state.viewers) == 0
      refute is_nil(state.pending_stop)
      :ok = Lenies.Worlds.stop_world(:arena)
    end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: FAIL — `detach_viewer/1` undefined; `:DOWN` not handled; `pending_stop` stays nil.

- [ ] **Step 3: Implement detach + `:DOWN` + grace scheduling**

In `lib/lenies/arena.ex`, add the public detach API and the message handlers. Add `@grace_ms` next to the existing `@world_id`:

```elixir
  @grace_ms 30_000

  @doc "Explicit detach. Usually unnecessary — :DOWN handles disconnect."
  @spec detach_viewer(pid) :: :ok
  def detach_viewer(pid \\ self()), do: GenServer.cast(__MODULE__, {:detach_viewer, pid})

  @impl true
  def handle_cast({:detach_viewer, pid}, state), do: {:noreply, remove_viewer(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, remove_viewer(state, pid)}
  end

  defp remove_viewer(state, pid) do
    if MapSet.member?(state.viewers, pid) do
      new_viewers = MapSet.delete(state.viewers, pid)
      new_monitors = Map.delete(state.monitors, pid)
      new_state = %{state | viewers: new_viewers, monitors: new_monitors}

      if MapSet.size(new_viewers) == 0 and state.started? do
        schedule_grace_stop(new_state)
      else
        new_state
      end
    else
      state
    end
  end

  defp schedule_grace_stop(state) do
    ref =
      Process.send_after(
        self(),
        {:maybe_stop, state.generation},
        grace_ms()
      )
    %{state | pending_stop: ref}
  end

  defp grace_ms, do: Application.get_env(:lenies, :arena_grace_ms, @grace_ms)
```

- [ ] **Step 4: Verify the tests pass**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/arena.ex test/lenies/arena_test.exs
git commit -m "feat(arena): :DOWN/detach handling — schedule grace timer on last viewer detach"
```

---

## Task 5: `:maybe_stop` with generation race protection + auto-save

**Files:**
- Modify: `lib/lenies/arena.ex`
- Modify: `test/lenies/arena_test.exs`

- [ ] **Step 1: Failing tests**

Append:

```elixir
    test "grace expires with no re-attach: world stops, state resets" do
      Application.put_env(:lenies, :arena_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :arena_grace_ms) end)

      task =
        Task.async(fn ->
          :ok = Lenies.Arena.attach_viewer()
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(200)

      refute Lenies.Worlds.alive?(:arena)
      state = :sys.get_state(Lenies.Arena)
      assert state.started? == false
      assert MapSet.size(state.viewers) == 0
    end

    test "re-attach during grace cancels the timer and keeps the world alive" do
      Application.put_env(:lenies, :arena_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :arena_grace_ms) end)

      task =
        Task.async(fn ->
          :ok = Lenies.Arena.attach_viewer()
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(10)  # 10 ms into the 50 ms grace

      :ok = Lenies.Arena.attach_viewer(self())
      Process.sleep(200)  # past the original grace window

      assert Lenies.Worlds.alive?(:arena)
      :ok = Lenies.Worlds.stop_world(:arena)
    end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: FAIL — `:maybe_stop` not handled; world stays alive after grace.

- [ ] **Step 3: Implement `:maybe_stop`**

In `lib/lenies/arena.ex`, add immediately after `handle_info({:DOWN, ...})` (to keep the `handle_info/2` clauses contiguous):

```elixir
  @impl true
  def handle_info({:maybe_stop, gen}, state) do
    cond do
      state.generation != gen ->
        # Generation changed (re-attach refreshed lifecycle). Ignore.
        {:noreply, state}

      MapSet.size(state.viewers) > 0 ->
        # New attaches since grace was scheduled. Ignore.
        {:noreply, state}

      true ->
        auto_save()
        _ = Lenies.Worlds.stop_world(@world_id)
        {:noreply, initial_state()}
    end
  end

  defp auto_save do
    case Lenies.Worlds.save_snapshot(@world_id, "auto") do
      :ok ->
        :ok

      :error ->
        # World already gone (race with manual stop). No-op.
        :ok

      {:error, reason} ->
        require Logger
        Logger.error("Lenies.Arena: auto-snapshot save failed: #{inspect(reason)}")
        :ok
    end
  end
```

- [ ] **Step 4: Verify the tests pass**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/arena.ex test/lenies/arena_test.exs
git commit -m "feat(arena): generation-protected :maybe_stop auto-snapshots and stops the world"
```

---

## Task 6: Auto-restore on first attach + quarantine corrupt `auto/`

**Files:**
- Modify: `lib/lenies/arena.ex`
- Modify: `test/lenies/arena_test.exs`

- [ ] **Step 1: Failing tests**

Append:

```elixir
  describe "auto-restore" do
    setup do
      start_supervised!({Lenies.Arena, []})
      Application.put_env(:lenies, :arena_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :arena_grace_ms) end)
      :ok
    end

    @tag :tmp_dir
    test "first attach restores from an existing auto snapshot", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      :ok = Lenies.Arena.attach_viewer(self())
      {:ok, handle1} = Lenies.Worlds.handle(:arena)
      Lenies.SpeciesColor.set_override(handle1, "arena-marker", "#123456")

      :ok = Lenies.Arena.detach_viewer(self())
      Process.sleep(1_000)  # grace + auto_save
      refute Lenies.Worlds.alive?(:arena)

      :ok = Lenies.Arena.attach_viewer(self())
      {:ok, handle2} = Lenies.Worlds.handle(:arena)
      assert Lenies.SpeciesColor.override(handle2, "arena-marker") == "#123456"

      :ok = Lenies.Worlds.stop_world(:arena)
    end

    @tag :tmp_dir
    test "corrupt auto snapshot is quarantined, world starts empty", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      auto_dir = Path.join([tmp, Lenies.Worlds.id_to_path(:arena), "auto"])
      File.mkdir_p!(auto_dir)
      File.write!(Path.join(auto_dir, "cells.tab"), "garbage, not a valid ets dump")

      :ok = Lenies.Arena.attach_viewer(self())
      refute File.dir?(auto_dir)
      broken =
        Path.join([tmp, Lenies.Worlds.id_to_path(:arena)])
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "auto.broken."))
      assert length(broken) == 1

      :ok = Lenies.Worlds.stop_world(:arena)
    end
  end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: FAIL — no auto-restore is attempted; the marker isn't restored; the corrupt auto/ isn't quarantined.

- [ ] **Step 3: Add auto-restore + quarantine helpers**

In `lib/lenies/arena.ex`, update `start_arena/0` to call `maybe_auto_restore/0` after a successful start, and add the helpers:

```elixir
  defp start_arena do
    case Lenies.Worlds.start_world(@world_id, %{}) do
      {:ok, sup_pid} ->
        maybe_auto_restore()
        {:ok, sup_pid}

      {:error, {:already_started, sup_pid}} ->
        {:ok, sup_pid}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_auto_restore do
    case Lenies.Snapshot.validate(@world_id, "auto") do
      :ok ->
        case Lenies.Worlds.restore_snapshot(@world_id, "auto") do
          :ok ->
            :ok

          {:error, reason} ->
            quarantine_broken_auto(reason)
            :ok
        end

      {:error, :missing_file} ->
        # No directory at all, or a partial directory. Quarantine only if it exists.
        if auto_dir_exists?(), do: quarantine_broken_auto(:missing_file), else: :ok

      {:error, reason} ->
        quarantine_broken_auto(reason)
        :ok
    end
  end

  defp auto_dir_exists? do
    root = Lenies.Snapshot.snapshot_root()
    Path.join([root, Lenies.Worlds.id_to_path(@world_id), "auto"]) |> File.dir?()
  end

  defp quarantine_broken_auto(reason) do
    require Logger

    root = Lenies.Snapshot.snapshot_root()
    dir = Path.join([root, Lenies.Worlds.id_to_path(@world_id), "auto"])

    if File.dir?(dir) do
      broken =
        Path.join([
          root,
          Lenies.Worlds.id_to_path(@world_id),
          "auto.broken.#{System.system_time(:second)}"
        ])
      File.rename(dir, broken)

      Logger.warning(
        "Lenies.Arena: auto snapshot quarantined as #{broken} (#{inspect(reason)})"
      )
    end

    :ok
  end
```

- [ ] **Step 4: Verify the tests pass**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/arena.ex test/lenies/arena_test.exs
git commit -m "feat(arena): auto-restore on first attach; quarantine corrupt auto snapshots"
```

---

## Task 7: `lineage_count/1` + atomic `seed/2`

**Files:**
- Modify: `lib/lenies/arena.ex`
- Modify: `test/lenies/arena_test.exs`

- [ ] **Step 1: Failing tests**

Append to `test/lenies/arena_test.exs`:

```elixir
  describe "lineage_count/1 and seed/2" do
    setup do
      start_supervised!({Lenies.Arena, []})
      :ok = Lenies.Arena.attach_viewer(self())
      on_exit(fn -> Lenies.Worlds.stop_world(:arena) end)
      :ok
    end

    test "lineage_count returns 0 when no Lenie carries this user's tag" do
      assert Lenies.Arena.lineage_count(123) == 0
    end

    test "seed/2 with lineage=0 spawns and bumps lineage_count to 1" do
      user = Lenies.AccountsFixtures.user_fixture()

      {:ok, codeome} =
        Lenies.Collection.create_codeome(user, %{
          name: "ArenaSeed",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      assert {:ok, :seeded} = Lenies.Arena.seed(user, codeome.id)
      Process.sleep(50)
      assert Lenies.Arena.lineage_count(user.id) == 1
    end

    test "seed/2 with lineage>0 returns {:error, :lineage_alive, N}" do
      user = Lenies.AccountsFixtures.user_fixture()

      {:ok, codeome} =
        Lenies.Collection.create_codeome(user, %{
          name: "ArenaSeed",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      {:ok, :seeded} = Lenies.Arena.seed(user, codeome.id)
      Process.sleep(50)

      assert {:error, :lineage_alive, 1} = Lenies.Arena.seed(user, codeome.id)
    end

    test "seed/2 returns {:error, :not_found} when codeome_id doesn't belong to user" do
      user = Lenies.AccountsFixtures.user_fixture()
      assert {:error, :not_found} = Lenies.Arena.seed(user, 999_999)
    end
  end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: FAIL — `lineage_count/1`/`seed/2` undefined.

- [ ] **Step 3: Implement `lineage_count` and `seed`**

In `lib/lenies/arena.ex`, add the public API and the corresponding `handle_call`:

```elixir
  @doc "Count of Lenies in the Arena whose seeder_user_id matches `user_id`."
  @spec lineage_count(integer) :: non_neg_integer()
  def lineage_count(user_id) when is_integer(user_id) do
    case Lenies.Worlds.handle(@world_id) do
      {:ok, handle} ->
        ms = [
          {{:_, %{seeder_user_id: :"$1"}}, [{:==, :"$1", user_id}], [true]}
        ]
        :ets.select_count(handle.tables.lenies, ms)

      :error ->
        0
    end
  end

  @doc """
  Atomically check the user's lineage count and (if 0) spawn one Lenie from their
  collection into the Arena. Returns:
  - `{:ok, :seeded}` on success
  - `{:error, :lineage_alive, count}` if user already has Lenies alive
  - `{:error, :not_found}` if codeome_id doesn't belong to this user
  - `{:error, term}` for other failures
  """
  @spec seed(map(), integer | binary) ::
          {:ok, :seeded}
          | {:error, :lineage_alive, non_neg_integer()}
          | {:error, term}
  def seed(user, codeome_id), do: GenServer.call(__MODULE__, {:seed, user, codeome_id})

  @impl true
  def handle_call({:seed, user, codeome_id}, _from, state) do
    reply = do_seed(user, codeome_id)
    {:reply, reply, state}
  end

  defp do_seed(user, codeome_id) do
    with %Lenies.Collection.Codeome{} = entry <- Lenies.Collection.get_codeome(user, codeome_id),
         {:ok, handle} <- Lenies.Worlds.handle(@world_id),
         0 <- lineage_count(user.id) do
      codeome = Lenies.Codeome.from_list(Lenies.Collection.to_opcode_atoms(entry))
      hash = Lenies.Codeome.hash(codeome)
      Lenies.SpeciesColor.set_override(handle, hash, entry.color_hex)

      opts = [
        energy: entry.energy_default,
        dir: Enum.random([:n, :s, :e, :w]),
        seeder_user_id: user.id,
        seed_origin: "★ " <> entry.name
      ]

      case Lenies.Worlds.spawn_lenie(@world_id, codeome, opts) do
        {:ok, {_id, _pos}} -> {:ok, :seeded}
        {:error, _} = err -> err
      end
    else
      nil -> {:error, :not_found}
      count when is_integer(count) and count > 0 -> {:error, :lineage_alive, count}
      :error -> {:error, :arena_not_running}
      {:error, _} = err -> err
    end
  end
```

- [ ] **Step 4: Verify the tests pass**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: 13 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/arena.ex test/lenies/arena_test.exs
git commit -m "feat(arena): lineage_count/1 + atomic seed/2 (one alive lineage per user)"
```

---

## Task 8: `apoptosis/1`

**Files:**
- Modify: `lib/lenies/arena.ex`
- Modify: `test/lenies/arena_test.exs`

- [ ] **Step 1: Failing tests**

Append:

```elixir
  describe "apoptosis/1" do
    setup do
      start_supervised!({Lenies.Arena, []})
      :ok = Lenies.Arena.attach_viewer(self())
      on_exit(fn -> Lenies.Worlds.stop_world(:arena) end)
      :ok
    end

    test "apoptosis on user with lineage=0 returns {:ok, 0}" do
      user = Lenies.AccountsFixtures.user_fixture()
      assert {:ok, 0} = Lenies.Arena.apoptosis(user)
    end

    test "apoptosis on user with lineage>0 kills all their Lenies; seed allowed again" do
      user = Lenies.AccountsFixtures.user_fixture()
      {:ok, codeome} =
        Lenies.Collection.create_codeome(user, %{
          name: "ArenaSeed",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      {:ok, :seeded} = Lenies.Arena.seed(user, codeome.id)
      Process.sleep(50)
      assert Lenies.Arena.lineage_count(user.id) == 1

      assert {:ok, 1} = Lenies.Arena.apoptosis(user)
      Process.sleep(100)  # allow terminate/2 to run
      assert Lenies.Arena.lineage_count(user.id) == 0

      # Now seed again succeeds.
      assert {:ok, :seeded} = Lenies.Arena.seed(user, codeome.id)
    end

    test "apoptosis only affects the calling user's Lenies; other users untouched" do
      user_a = Lenies.AccountsFixtures.user_fixture()
      user_b = Lenies.AccountsFixtures.user_fixture()

      {:ok, codeome_a} =
        Lenies.Collection.create_codeome(user_a, %{
          name: "A", color_hex: "#aa0000", energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })
      {:ok, codeome_b} =
        Lenies.Collection.create_codeome(user_b, %{
          name: "B", color_hex: "#00aa00", energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      {:ok, :seeded} = Lenies.Arena.seed(user_a, codeome_a.id)
      {:ok, :seeded} = Lenies.Arena.seed(user_b, codeome_b.id)
      Process.sleep(50)

      assert {:ok, 1} = Lenies.Arena.apoptosis(user_a)
      Process.sleep(100)
      assert Lenies.Arena.lineage_count(user_a.id) == 0
      assert Lenies.Arena.lineage_count(user_b.id) == 1
    end
  end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: FAIL — `apoptosis/1` undefined.

- [ ] **Step 3: Implement `apoptosis`**

In `lib/lenies/arena.ex`, add:

```elixir
  @doc """
  Kills all Lenies in the Arena whose seeder_user_id matches `user.id`.
  Returns `{:ok, count_killed}`. Idempotent: returns `{:ok, 0}` if the user has no
  alive Lenies in the Arena.

  Uses `Process.exit(pid, :shutdown)` so each Lenie's `terminate/2` runs naturally —
  the World cleans up the `:lenies` row and the occupied cell.
  """
  @spec apoptosis(map()) :: {:ok, non_neg_integer()}
  def apoptosis(user), do: GenServer.call(__MODULE__, {:apoptosis, user})

  @impl true
  def handle_call({:apoptosis, user}, _from, state) do
    count =
      case Lenies.Worlds.handle(@world_id) do
        {:ok, handle} ->
          ms = [
            {{:"$1", %{seeder_user_id: :"$2"}}, [{:==, :"$2", user.id}], [:"$1"]}
          ]
          ids = :ets.select(handle.tables.lenies, ms)

          Enum.reduce(ids, 0, fn id, acc ->
            case Registry.lookup(Lenies.Registry, {:lenie, @world_id, id}) do
              [{pid, _}] ->
                Process.exit(pid, :shutdown)
                acc + 1

              [] ->
                acc
            end
          end)

        :error ->
          0
      end

    {:reply, {:ok, count}, state}
  end
```

- [ ] **Step 4: Verify the tests pass**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: 16 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/arena.ex test/lenies/arena_test.exs
git commit -m "feat(arena): apoptosis/1 — user-triggered self-terminate of their Arena lineage"
```

---

## Task 9: Adopt-on-restart + `arena:manager_up` broadcast + Application supervision

**Files:**
- Modify: `lib/lenies/arena.ex`
- Modify: `lib/lenies/application.ex`
- Modify: `test/lenies/arena_test.exs`

- [ ] **Step 1: Add Arena to Application children**

In `lib/lenies/application.ex`, find the children list. Add `Lenies.Arena` AFTER `Lenies.Sandboxes`:

```elixir
Lenies.Sandboxes,
Lenies.Arena,
```

- [ ] **Step 2: Failing test**

Append:

```elixir
  describe "crash recovery / adopt" do
    test "on init, adopts a running :arena world and broadcasts arena:manager_up" do
      :ok = Lenies.Arena.attach_viewer(self())
      assert Lenies.Worlds.alive?(:arena)

      Phoenix.PubSub.subscribe(Lenies.PubSub, "arena:manager_up")
      pid = Process.whereis(Lenies.Arena)
      Process.exit(pid, :kill)

      assert_receive :arena_manager_up, 1_000

      Process.sleep(50)
      state = :sys.get_state(Lenies.Arena)
      assert state.started? == true
      assert MapSet.size(state.viewers) == 0
      refute is_nil(state.pending_stop)

      :ok = Lenies.Worlds.stop_world(:arena)
    end
  end
```

NOTE: this describe does NOT use `start_supervised!` — it relies on the Application-supervised Arena. Update the earlier describes that DO use `start_supervised!({Lenies.Arena, []})` to REMOVE those lines (the Application now supervises it). Same mechanical migration as in sub-project #3 Task 7.

- [ ] **Step 3: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: FAIL — no adopt logic; no broadcast.

- [ ] **Step 4: Replace `init/1` with adopt logic**

In `lib/lenies/arena.ex`:

```elixir
  @impl true
  def init(_opts) do
    state =
      if Lenies.Worlds.alive?(@world_id) do
        ref = Process.send_after(self(), {:maybe_stop, 1}, grace_ms())

        %{
          started?: true,
          viewers: MapSet.new(),
          monitors: %{},
          pending_stop: ref,
          generation: 1
        }
      else
        initial_state()
      end

    Phoenix.PubSub.broadcast(Lenies.PubSub, "arena:manager_up", :arena_manager_up)
    {:ok, state}
  end
```

- [ ] **Step 5: Verify the tests pass**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/arena_test.exs'
```

Expected: 17 tests pass.

Full suite:
```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0 --include integration'
```

Expected: 750 baseline + ~17 new arena tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/lenies/arena.ex lib/lenies/application.ex test/lenies/arena_test.exs
git commit -m "feat(arena): adopt running :arena world on init + arena:manager_up broadcast; supervise under Application"
```

---

## Task 10: Routing migration — Arena at `/`, Sandbox under `/sandbox/...`

**Files:**
- Modify: `lib/lenies_web/router.ex`
- Modify: `lib/lenies_web/user_auth.ex` — `signed_in_path/1` returns `~p"/sandbox"`
- Modify: `lib/lenies_web/live/dashboard_live.ex`, `editor_live.ex`, `lenie_inspector_live.ex`, `species_live.ex` — every `push_navigate`/`patch`/`redirect` to `~p"/..."` switches to `~p"/sandbox..."`
- Modify: `lib/lenies_web/components/layouts/root.html.heex` (or the layout where the navbar lives) — header navbar with conditional auth/anon links

NOTE: `lib/lenies_web/live/arena_live.ex` (the route target) is implemented in Task 13. For Task 10, route `/` to a temporary placeholder that just renders a 1-line "Arena coming soon" or — simpler — comment out the `live "/", ...` line until Task 13 lands.

- [ ] **Step 1: Update the router scopes**

In `lib/lenies_web/router.ex`, replace the existing two scopes with:

```elixir
# Public scope: Arena + auth pages
scope "/", LeniesWeb do
  pipe_through :browser

  live_session :arena_public,
    on_mount: @sandbox_on_mount ++ [{LeniesWeb.UserAuth, :mount_current_scope}] do
    # ArenaLive lives here once Task 13 ships. For now, leave a placeholder.
    # live "/", ArenaLive, :index

    live "/users/register", UserLive.Registration, :new
    live "/users/log-in", UserLive.Login, :new
    live "/users/log-in/:token", UserLive.Confirmation, :new
  end

  post "/users/log-in", UserSessionController, :create
  delete "/users/log-out", UserSessionController, :delete
end

# Authenticated scope: everything else, under /sandbox/...
scope "/", LeniesWeb do
  pipe_through [:browser, :require_authenticated_user]

  live_session :require_authenticated_user,
    on_mount: @sandbox_on_mount ++ [{LeniesWeb.UserAuth, :require_authenticated}] do
    live "/sandbox", DashboardLive, :index
    live "/sandbox/lenie/:id", LenieInspectorLive, :show
    live "/sandbox/species/:hash", SpeciesLive, :show
    live "/sandbox/editor/new", EditorLive, :new
    live "/sandbox/editor/edit/:hash", EditorLive, :edit

    live "/users/settings", UserLive.Settings, :edit
    live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
  end

  post "/users/update-password", UserSessionController, :update_password
end
```

The dev-mailbox route at `/dev/mailbox` and the `Plug.Swoosh.MailboxPreview` line are preserved as-is.

- [ ] **Step 2: Update `signed_in_path/1`**

In `lib/lenies_web/user_auth.ex`, find `def signed_in_path(_), do: ~p"/"` (or similar). Change to:

```elixir
def signed_in_path(_), do: ~p"/sandbox"
```

- [ ] **Step 3: Update internal `~p"/"` / `~p"/lenie/..."` / `~p"/editor/..."` references in LiveViews**

Grep for them:

```bash
grep -rnE '~p"/(lenie/|species/|editor/(new|edit/)|$)' lib/lenies_web/live/
```

For each:
- `~p"/"` → `~p"/sandbox"`
- `~p"/lenie/#{id}"` → `~p"/sandbox/lenie/#{id}"`
- `~p"/species/#{hash}"` → `~p"/sandbox/species/#{hash}"`
- `~p"/editor/new"` → `~p"/sandbox/editor/new"`
- `~p"/editor/edit/#{hash}"` → `~p"/sandbox/editor/edit/#{hash}"`

The LiveViews touched include:
- `dashboard_live.ex` — inspector navigation, controls panel callbacks
- `editor_live.ex` — `push_navigate(to: ~p"/")` after save
- `lenie_inspector_live.ex` — back link, edit-codeome link
- `species_live.ex` — back link

- [ ] **Step 4: Add a conditional navbar**

In `lib/lenies_web/components/layouts/root.html.heex` (or wherever the root layout's top-of-page nav lives — read the file to confirm), add a header:

```heex
<header class="lenies-navbar">
  <a href={~p"/"} class="logo">Lenies</a>
  <nav>
    <%= if @current_scope && @current_scope.user do %>
      <a href={~p"/sandbox"}>Sandbox</a>
      <a href={~p"/users/settings"}>Settings</a>
      <span class="user-email"><%= @current_scope.user.email %></span>
      <.link href={~p"/users/log-out"} method="delete">Log out</.link>
    <% else %>
      <a href={~p"/users/register"}>Register</a>
      <a href={~p"/users/log-in"}>Log in</a>
    <% end %>
  </nav>
</header>
```

Match the existing CSS/classes used by the dashboard (read the file first; the project has a dark sci-fi theme — preserve consistency).

- [ ] **Step 5: Verify compile (suite WILL be red until Task 11 fixes the tests)**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix compile --warnings-as-errors'
```

Expected: clean compile. Suite is intentionally red — Sandbox tests still hit `~p"/"` and now get redirects to login (route doesn't exist anymore) or 404. Task 11 mass-migrates them.

- [ ] **Step 6: Commit (with explicit suite-red note)**

```bash
git add lib/lenies_web/router.ex lib/lenies_web/user_auth.ex lib/lenies_web/live/ lib/lenies_web/components/
git commit -m "refactor(routing): Sandbox routes move under /sandbox/...; signed_in_path → /sandbox; conditional navbar

The Arena route at / is intentionally commented out — ArenaLive lands in
Task 13. The /sandbox routes are now the only authenticated paths.

Test suite is intentionally red between this commit and Task 11 (mass
test path migration). All Sandbox tests still hit the old / paths and
will fail until updated."
```

---

## Task 11: Mass-migrate Sandbox test paths to `/sandbox/...`

**Files:**
- Modify: all `test/lenies_web/live/*.exs` files that reference the old paths

- [ ] **Step 1: Grep for the old paths in tests**

```bash
grep -rnE '~p"/(lenie/|species/|editor/(new|edit/)|$)' test/lenies_web/
```

The matches are the migration target. Mostly:
- `live(conn, ~p"/")` → `live(conn, ~p"/sandbox")`
- `live(conn, ~p"/lenie/#{id}")` → `live(conn, ~p"/sandbox/lenie/#{id}")`
- `live(conn, ~p"/species/#{hash}")` → `live(conn, ~p"/sandbox/species/#{hash}")`
- `live(conn, ~p"/editor/new")` → `live(conn, ~p"/sandbox/editor/new")`
- `live(conn, ~p"/editor/edit/#{hash}")` → `live(conn, ~p"/sandbox/editor/edit/#{hash}")`
- Any `assert_redirect` / `assert_patch` assertions targeting these paths

For each test file, apply the migration. The test bodies themselves don't change — only the URLs.

- [ ] **Step 2: Verify no remaining old-path matches**

```bash
grep -rnE '~p"/(lenie/|species/|editor/(new|edit/)|$)' test/lenies_web/
```

Expected: zero matches.

- [ ] **Step 3: Run the suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0 --include integration'
```

Expected: all pass — Sandbox tests now hit the right URLs; new Arena unit tests still pass; the Arena route at `/` is still un-routed (commented out from Task 10), so anyone hitting `/` gets a 404 if they try — but no tests do.

- [ ] **Step 4: Commit**

```bash
git add test/lenies_web/
git commit -m "test(web): mass-migrate Sandbox LV tests to /sandbox/... paths"
```

---

## Task 12: `LeniesWeb.Presence`

**Files:**
- Create: `lib/lenies_web/presence.ex`
- Modify: `lib/lenies_web/application.ex` or `lib/lenies/application.ex` — supervise Presence
- Test: `test/lenies_web/presence_test.exs`

- [ ] **Step 1: Failing test**

Create `test/lenies_web/presence_test.exs`:

```elixir
defmodule LeniesWeb.PresenceTest do
  use ExUnit.Case, async: false

  test "track + list returns the tracked entry" do
    {:ok, _} = LeniesWeb.Presence.track(self(), "arena:presence", "session-x", %{})
    list = LeniesWeb.Presence.list("arena:presence")
    assert Map.has_key?(list, "session-x")
  end
end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/presence_test.exs'
```

Expected: FAIL — `LeniesWeb.Presence` undefined.

- [ ] **Step 3: Create the Presence module**

Create `lib/lenies_web/presence.ex`:

```elixir
defmodule LeniesWeb.Presence do
  @moduledoc """
  Phoenix.Presence for tracking Arena viewers. Topic: `"arena:presence"`.

  Each `LeniesWeb.ArenaLive` mount calls `track(self(), "arena:presence",
  session_id, %{})` and subscribes to the same topic to receive diff updates.
  The display surfaces only the count — usernames are not tracked or shown.
  """
  use Phoenix.Presence,
    otp_app: :lenies,
    pubsub_server: Lenies.PubSub
end
```

- [ ] **Step 4: Supervise Presence**

In `lib/lenies/application.ex`, add `LeniesWeb.Presence` to the children list AFTER `Phoenix.PubSub`:

```elixir
{Phoenix.PubSub, name: Lenies.PubSub},
LeniesWeb.Presence,
```

- [ ] **Step 5: Verify the test passes**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/presence_test.exs'
```

Expected: 1 test passes.

- [ ] **Step 6: Commit**

```bash
git add lib/lenies_web/presence.ex lib/lenies/application.ex test/lenies_web/presence_test.exs
git commit -m "feat(web): LeniesWeb.Presence for Arena viewers (count-only display)"
```

---

## Task 13: `LeniesWeb.ArenaLive` (mount, render, presence)

**Files:**
- Create: `lib/lenies_web/live/arena_live.ex`
- Modify: `lib/lenies_web/router.ex` — uncomment the `live "/", ArenaLive, :index` line
- Test: included in `test/lenies_web/live/arena_live_test.exs` (Task 15)

This task creates ArenaLive WITHOUT the controls component (Task 14 adds that). Mount, render canvas + sparkline + species table, Presence count. Controls area shows a placeholder.

- [ ] **Step 1: Create the ArenaLive module**

Create `lib/lenies_web/live/arena_live.ex`. Use `DashboardLive` as a structural template (it already has the canvas/sparkline/species table render logic) but adapt for Arena:

```elixir
defmodule LeniesWeb.ArenaLive do
  @moduledoc """
  Public, read-mostly view of the `:arena` world.

  Anonymous users see the canvas, sparkline, species table, and presence count.
  Authenticated users additionally see the `ArenaControlsComponent` (Task 14).
  """
  use LeniesWeb, :live_view

  alias Phoenix.PubSub

  @world_id :arena

  @impl true
  def mount(_params, _session, socket) do
    :ok = Lenies.Arena.attach_viewer(self())
    {:ok, world_handle} = Lenies.Worlds.handle(@world_id)

    session_id =
      case Phoenix.LiveView.get_connect_params(socket) do
        %{"_csrf_token" => t} -> t
        _ -> "anon-" <> Integer.to_string(:erlang.unique_integer([:positive]))
      end

    if connected?(socket) do
      prefix = world_handle.pubsub_prefix
      PubSub.subscribe(Lenies.PubSub, "#{prefix}:tick")
      PubSub.subscribe(Lenies.PubSub, "#{prefix}:control")
      PubSub.subscribe(Lenies.PubSub, "#{prefix}:fx")
      PubSub.subscribe(Lenies.PubSub, "arena:presence")
      PubSub.subscribe(Lenies.PubSub, "arena:manager_up")

      {:ok, _} = LeniesWeb.Presence.track(self(), "arena:presence", session_id, %{})
    end

    {:ok,
     socket
     |> assign(:world_id, @world_id)
     |> assign(:world_handle, world_handle)
     |> assign(:viewer_count, LeniesWeb.Presence.list("arena:presence") |> map_size())
     # Keep the dashboard's initial assigns: grid, species, sparkline buffer, etc.
     # Reuse helper functions from DashboardLive if they're public; otherwise
     # duplicate the small init shape here (better: extract to a shared helper
     # in a follow-up; for #4, just duplicate to keep scope tight).
    }
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    count = LeniesWeb.Presence.list("arena:presence") |> map_size()
    {:noreply, assign(socket, :viewer_count, count)}
  end

  def handle_info(:arena_manager_up, socket) do
    :ok = Lenies.Arena.attach_viewer(self())
    {:noreply, socket}
  end

  # Tick/control/fx handlers — clone from DashboardLive (or extract a shared mixin).
  # For #4 scope, copy them into ArenaLive verbatim.
  # def handle_info({:tick, n}, socket) do ... end
  # def handle_info({:sterilized, _}, socket) do ... end  # benign no-op in Arena
  # etc.

  @impl true
  def render(assigns) do
    # Copy DashboardLive's render but:
    # - replace the ControlsPanelComponent block with a placeholder
    #   ("Arena controls coming in Task 14"); Task 14 swaps the real component
    # - add a viewer-count badge in the header
    ~H"""
    <main class="arena-page">
      <header class="arena-header">
        <span class="viewers"><%= @viewer_count %> watching</span>
      </header>
      <section class="arena-canvas">
        <!-- canvas + sparkline + species table (clone from DashboardLive) -->
      </section>
      <aside class="arena-controls-placeholder">
        Arena controls (Task 14)
      </aside>
    </main>
    """
  end
end
```

The render body intentionally elides exact canvas/sparkline markup — copy the working `DashboardLive` `render/1` minus the controls panel and minus the inspector edit button. Read `lib/lenies_web/live/dashboard_live.ex` `render/1` and adapt.

- [ ] **Step 2: Wire the route**

In `lib/lenies_web/router.ex`, inside the `live_session :arena_public` block, uncomment / add:

```elixir
live "/", ArenaLive, :index
```

- [ ] **Step 3: Compile + sanity-check**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix compile --warnings-as-errors'
```

Expected: clean.

A quick smoke from IEx:
```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0 --include integration'
```

Expected: all existing tests pass; no Arena-specific LV tests yet (Task 15).

- [ ] **Step 4: Commit**

```bash
git add lib/lenies_web/live/arena_live.ex lib/lenies_web/router.ex
git commit -m "feat(web): LeniesWeb.ArenaLive — public mount, presence count, world subscriptions"
```

---

## Task 14: `LeniesWeb.ArenaControlsComponent` — Seed + Apoptosis

**Files:**
- Create: `lib/lenies_web/live/arena_controls_component.ex`
- Modify: `lib/lenies_web/live/arena_live.ex` — render the component, handle its events
- Test: included in `test/lenies_web/live/arena_live_test.exs` (Task 15)

This component renders one of four states: anonymous, auth-empty-collection, auth-lineage-0, auth-lineage-N. Click events bubble up to ArenaLive via `send_update`/`send(self(), …)`.

- [ ] **Step 1: Create the component**

Create `lib/lenies_web/live/arena_controls_component.ex`:

```elixir
defmodule LeniesWeb.ArenaControlsComponent do
  @moduledoc """
  Read-mostly controls for the Arena. Four states:

  - Anonymous: "Log in to seed" prompt + link.
  - Authenticated, empty collection: "Save a codeome in your Sandbox first" + link.
  - Authenticated, lineage=0: codeome dropdown + Seed button.
  - Authenticated, lineage>0: lineage count + Apoptosis (with confirm) button.
  """
  use LeniesWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:apoptosis_confirming, fn -> false end)
     |> assign_new(:flash_msg, fn -> nil end)
     |> assign(:codeomes, codeomes_for(assigns.current_scope))}
  end

  defp codeomes_for(nil), do: []
  defp codeomes_for(%{user: user}), do: Lenies.Collection.list_codeomes(user)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="arena-controls">
      <%= cond do %>
        <% is_nil(@current_scope) or is_nil(@current_scope.user) -> %>
          <p>Log in to seed your Lenie in the Arena.</p>
          <.link navigate={~p"/users/log-in"}>Log in</.link>

        <% @codeomes == [] -> %>
          <p>Save a codeome in your Sandbox first.</p>
          <.link navigate={~p"/sandbox/editor/new"}>Open the editor</.link>

        <% @lineage_count == 0 -> %>
          <.form for={%{}} as={:seed} phx-submit="seed" phx-target={@myself}>
            <select name="codeome_id">
              <%= for c <- @codeomes do %>
                <option value={c.id}><%= c.name %></option>
              <% end %>
            </select>
            <button type="submit">Seed your Lenie</button>
          </.form>

        <% @apoptosis_confirming -> %>
          <p>Stop all <%= @lineage_count %> of your Lenies in the Arena?</p>
          <button type="button" phx-click="apoptosis_confirm" phx-target={@myself}>Confirm</button>
          <button type="button" phx-click="apoptosis_cancel" phx-target={@myself}>Cancel</button>

        <% true -> %>
          <p>Your lineage: <%= @lineage_count %> Lenies alive</p>
          <button type="button" phx-click="apoptosis_init" phx-target={@myself}>
            Apoptosis (<%= @lineage_count %>)
          </button>
      <% end %>

      <%= if @flash_msg, do: raw("<p class=\"flash\">#{Phoenix.HTML.html_escape(@flash_msg)}</p>") %>
    </div>
    """
  end

  @impl true
  def handle_event("seed", %{"codeome_id" => codeome_id_str}, socket) do
    codeome_id = String.to_integer(codeome_id_str)
    user = socket.assigns.current_scope.user

    case Lenies.Arena.seed(user, codeome_id) do
      {:ok, :seeded} ->
        send(self(), {:arena_lineage_changed, user.id})
        {:noreply, assign(socket, :flash_msg, "Seeded!")}

      {:error, :lineage_alive, n} ->
        send(self(), {:arena_lineage_changed, user.id})
        {:noreply, assign(socket, :flash_msg, "Your lineage is alive (#{n}).")}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Seed failed: #{inspect(reason)}")}
    end
  end

  def handle_event("apoptosis_init", _, socket),
    do: {:noreply, assign(socket, :apoptosis_confirming, true)}

  def handle_event("apoptosis_cancel", _, socket),
    do: {:noreply, assign(socket, :apoptosis_confirming, false)}

  def handle_event("apoptosis_confirm", _, socket) do
    user = socket.assigns.current_scope.user
    {:ok, count} = Lenies.Arena.apoptosis(user)
    send(self(), {:arena_lineage_changed, user.id})
    {:noreply,
     socket
     |> assign(:apoptosis_confirming, false)
     |> assign(:flash_msg, "Apoptosis: #{count} Lenies stopped.")}
  end
end
```

- [ ] **Step 2: Wire the component into ArenaLive**

In `lib/lenies_web/live/arena_live.ex`:

(a) Add `lineage_count` to the assigns at mount:

```elixir
lineage_count =
  if socket.assigns[:current_scope] && socket.assigns.current_scope.user do
    Lenies.Arena.lineage_count(socket.assigns.current_scope.user.id)
  else
    0
  end

socket = assign(socket, :lineage_count, lineage_count)
```

(b) Handle the `:arena_lineage_changed` message from the component:

```elixir
def handle_info({:arena_lineage_changed, user_id}, socket) do
  if socket.assigns[:current_scope] && socket.assigns.current_scope.user.id == user_id do
    {:noreply, assign(socket, :lineage_count, Lenies.Arena.lineage_count(user_id))}
  else
    {:noreply, socket}
  end
end
```

(Place contiguous with other `handle_info/2` clauses.)

(c) Render the component in the controls placeholder slot:

```heex
<aside class="arena-controls">
  <.live_component
    module={LeniesWeb.ArenaControlsComponent}
    id="arena-controls"
    current_scope={@current_scope}
    world_handle={@world_handle}
    lineage_count={@lineage_count}
  />
</aside>
```

- [ ] **Step 3: Compile clean**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix compile --warnings-as-errors'
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add lib/lenies_web/live/arena_controls_component.ex lib/lenies_web/live/arena_live.ex
git commit -m "feat(web): ArenaControlsComponent — Seed + Apoptosis (4 visual states)"
```

---

## Task 15: ArenaLive integration tests

**Files:**
- Create: `test/lenies_web/live/arena_live_test.exs`

- [ ] **Step 1: Write the tests**

Create `test/lenies_web/live/arena_live_test.exs`:

```elixir
defmodule LeniesWeb.ArenaLiveTest do
  use LeniesWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "anonymous viewer" do
    test "mounts at / and sees Arena content", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "watching"
    end

    test "presence count visible (1 viewer = self)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      Process.sleep(50)  # let Presence diff propagate
      assert render(view) =~ "1 watching"
    end

    test "shows the 'Log in to seed' prompt instead of seed/apoptosis controls",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Log in to seed"
      refute html =~ "Seed your Lenie"
    end
  end

  describe "authenticated viewer (no collection codeomes)" do
    setup %{conn: conn} do
      user = Lenies.AccountsFixtures.user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "shows the 'Save a codeome in your Sandbox first' hint", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Save a codeome in your Sandbox first"
    end
  end

  describe "authenticated viewer with a codeome and lineage=0" do
    setup %{conn: conn} do
      user = Lenies.AccountsFixtures.user_fixture()
      {:ok, codeome} =
        Lenies.Collection.create_codeome(user, %{
          name: "MyArenaSeed",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      %{conn: log_in_user(conn, user), user: user, codeome: codeome}
    end

    test "shows the codeome dropdown + Seed button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Seed your Lenie"
      assert html =~ "MyArenaSeed"
    end

    test "clicking Seed spawns and updates lineage_count", %{conn: conn,
                                                            user: user,
                                                            codeome: codeome} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("form[phx-submit=seed]", %{codeome_id: to_string(codeome.id)})
      |> render_submit()

      Process.sleep(100)

      assert Lenies.Arena.lineage_count(user.id) == 1
      assert render(view) =~ "Your lineage:"
    end
  end

  describe "authenticated viewer with lineage>0" do
    setup %{conn: conn} do
      user = Lenies.AccountsFixtures.user_fixture()
      {:ok, codeome} =
        Lenies.Collection.create_codeome(user, %{
          name: "MyArenaSeed",
          color_hex: "#abcdef",
          energy_default: 500.0,
          opcodes: ["nop_1", "store", "eat", "eat", "move", "eat", "move", "eat", "move", "eat"]
        })

      :ok = Lenies.Arena.attach_viewer()
      {:ok, :seeded} = Lenies.Arena.seed(user, codeome.id)
      Process.sleep(50)

      on_exit(fn -> Lenies.Worlds.stop_world(:arena) end)
      %{conn: log_in_user(conn, user), user: user}
    end

    test "shows Apoptosis button with count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Apoptosis"
      assert html =~ "Your lineage:"
    end

    test "two-step Apoptosis (init + confirm) kills the lineage", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("button[phx-click=apoptosis_init]") |> render_click()
      assert render(view) =~ "Confirm"

      view |> element("button[phx-click=apoptosis_confirm]") |> render_click()
      Process.sleep(100)

      assert Lenies.Arena.lineage_count(user.id) == 0
    end
  end

  describe "route migration" do
    test "anonymous GET /sandbox redirects to /users/log-in", %{conn: conn} do
      conn = get(conn, ~p"/sandbox")
      assert redirected_to(conn) =~ "/users/log-in"
    end

    test "authenticated GET /sandbox is 200 DashboardLive", %{conn: conn} do
      user = Lenies.AccountsFixtures.user_fixture()
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/sandbox")
      assert html =~ "Sandbox" or html =~ "Lenies"   # depends on exact dashboard heading
    end

    test "old / path is now public (Arena), no redirect", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert conn.status == 200
    end
  end
end
```

- [ ] **Step 2: Run the tests**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/arena_live_test.exs'
```

Expected: all pass.

Full suite:
```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0 --include integration'
```

Expected: previous count + new tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add test/lenies_web/live/arena_live_test.exs
git commit -m "test(arena): ArenaLive integration tests — anon/auth states, seed, apoptosis, route migration"
```

---

## Task 16: `mix precommit` green

**Files:** (only changes that surface during this step)

- [ ] **Step 1: Sanity-grep for old paths and `:primary`**

```bash
grep -rnE '~p"/(lenie/|species/|editor/(new|edit/)|$)' lib test
grep -rn 'primary_handle\|:primary\b' lib test config
```

Expected: zero matches (or only in historical comments / docstrings).

- [ ] **Step 2: Run `mix precommit`**

```bash
bash -c '. ~/.asdf/asdf.sh && mix precommit'
```

Expected:
- compile clean (warnings-as-errors)
- deps.unlock --unused: no changes
- format: applies any pending reformats
- test: all pass

- [ ] **Step 3: Commit any format-only changes**

```bash
git status
# If any files were reformatted:
git add -A
git commit -m "chore: precommit format pass after global-arena sub-project"
```

(Skip if `format` made no changes.)

- [ ] **Step 4: Optional smoke verification**

Start `iex -S mix phx.server`. Open `/` in a browser — anonymous viewer of the Arena. Open a second browser/tab — presence count should show 2. Register an account, log in (lands at `/sandbox`). Save a codeome via the editor. Navigate to `/` (Arena). See your collection in the dropdown. Click "Seed your Lenie". Confirm a Lenie appears in the Arena. Click "Apoptosis (1)" → "Confirm". Lenie disappears.

---

## Self-Review notes (resolved inline)

- **Spec coverage:**
  - `Lenies.Arena` lifecycle (attach/detach/grace/snapshot/restore/adopt) → Tasks 3-6, 9 ✓
  - 30 s grace, configurable via `:arena_grace_ms` → Task 4 ✓
  - Auto-snapshot + auto-restore + quarantine → Tasks 5, 6 ✓
  - `seeder_user_id` propagation through replication → Tasks 1, 2 ✓
  - `lineage_count/1` via `:ets.select` → Task 7 ✓
  - Atomic `seed/2` via `GenServer.call` → Task 7 ✓
  - `apoptosis/1` with `:shutdown` → Task 8 ✓
  - Adopt-on-restart + `arena:manager_up` → Task 9 ✓
  - Routing: Arena at `/`, Sandbox under `/sandbox/...` → Task 10 ✓
  - `signed_in_path/1` → `/sandbox` → Task 10 ✓
  - Conditional navbar → Task 10 ✓
  - Mass-migrate test paths → Task 11 ✓
  - `LeniesWeb.Presence` → Task 12 ✓
  - `ArenaLive` mount + render + presence → Task 13 ✓
  - `ArenaControlsComponent` (4 states) → Task 14 ✓
  - Integration tests (anon/auth states, seed, apoptosis, route migration) → Task 15 ✓
  - `mix precommit` green → Task 16 ✓
- **Placeholder scan:** no TBD/TODO. Tasks 10, 13 explicitly note the WIP shape (commented-out route until Task 13 lands; placeholder controls panel until Task 14 swaps it). These are scheduled handoffs, not placeholders.
- **Type consistency:** `Lenies.Arena.attach_viewer/1`, `detach_viewer/1`, `seed/2`, `apoptosis/1`, `lineage_count/1` signatures match across tasks. State entry shape (`%{started?, viewers, monitors, pending_stop, generation}`) defined in Task 3 and used through 9. `seeder_user_id` field name consistent across Lenie state, Lenie snapshot, World's `child_opts`, and `Lenies.Arena.seed/2`'s opts.
- **Suite-green checkpoints:** Tasks 1-9 end green. Tasks 10-11 intentionally leave the suite red between them (the routing migration window). Tasks 12-16 end green.
