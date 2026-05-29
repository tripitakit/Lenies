# Personal Sandbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each authenticated user gets a private simulation world (`{:sandbox, user.id}`) that lives only while they are connected; auto-snapshot at stop and auto-restore at next start make it feel like a workspace. `:primary` is retired entirely.

**Architecture:** A new `Lenies.Sandboxes` GenServer owns the lifecycle policy (attach on LiveView mount, `Process.monitor` the LV pid, schedule a 30 s grace timer on last disconnect, snapshot+stop on expiry, adopt running worlds on its own restart). The 5 authenticated LiveView routes migrate to mount on `{:sandbox, current_scope.user.id}` instead of `:primary`.

**Tech Stack:** Elixir 1.19, OTP 28, Phoenix 1.8, Phoenix LiveView 1.1, `Phoenix.PubSub`, the multi-world engine from sub-project #2 (`Lenies.Worlds` facade, per-world `Supervisor` sub-tree, per-world snapshots).

**Spec:** `docs/superpowers/specs/2026-05-28-personal-sandbox-design.md`

---

## File Structure

**Created:**
- `lib/lenies/sandboxes.ex` — the lifecycle manager GenServer.
- `test/lenies/sandboxes_test.exs` — unit tests for the manager.

**Modified:**
- `lib/lenies/application.ex` — add `Lenies.Sandboxes` to children; remove `:primary` auto-boot and `:auto_start_simulation`.
- `lib/lenies/worlds.ex` — remove `primary_handle/0`.
- `lib/lenies/world.ex` — remove the 11 module-level delegators (`sterilize/0`, `pause/0`, `resume/0`, `paused?/0`, `action/1`, `spawn_lenie/2`, `snapshot_stats/0`, `tick_now/0`, `reconcile/0`, `restore_tables/1`, `lenie_died/4`); drop the `world_id: :primary` default from `start_link/1`.
- `lib/lenies/telemetry.ex` — remove the `:primary` reference at line 30 (dead branch after manager-driven lifecycle).
- `lib/lenies_web/live/dashboard_live.ex` — mount migrates to `{:sandbox, user.id}` + `Sandboxes.attach/1`.
- `lib/lenies_web/live/editor_live.ex` — same.
- `lib/lenies_web/live/lenie_inspector_live.ex` — same.
- `lib/lenies_web/live/species_live.ex` — same.
- (Editor's `:new` and `:edit/:hash` are the same LiveView module.)
- `test/support/world_test_helpers.ex` — `start_primary/1` → `start_test_world/1` (parameterized).
- ~28 test files that reference `:primary` / `primary_handle` / `start_primary` — bulk migrated.

**Spec deliverable cross-reference:**
- Lifecycle manager → Tasks 1-7
- LiveView migration → Tasks 8-9
- `:primary` cleanup → Tasks 10-12
- Auto-restore round-trip + 5-user smoke + precommit → Tasks 13-14

---

## Task 1: `Lenies.Sandboxes` skeleton + `world_id_for/1`

**Files:**
- Create: `lib/lenies/sandboxes.ex`
- Test: `test/lenies/sandboxes_test.exs`

- [ ] **Step 1: Failing test**

Create `test/lenies/sandboxes_test.exs`:

```elixir
defmodule Lenies.SandboxesTest do
  use ExUnit.Case, async: false

  describe "world_id_for/1" do
    test "wraps a user id as a {:sandbox, id} tuple" do
      assert Lenies.Sandboxes.world_id_for(42) == {:sandbox, 42}
      assert Lenies.Sandboxes.world_id_for(1) == {:sandbox, 1}
    end
  end
end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: FAIL — `Lenies.Sandboxes` undefined.

- [ ] **Step 3: Create the module skeleton**

Create `lib/lenies/sandboxes.ex`:

```elixir
defmodule Lenies.Sandboxes do
  @moduledoc """
  Per-user sandbox lifecycle manager.

  Each logged-in user has exactly one sandbox — a `Lenies.Worlds`
  instance keyed `{:sandbox, user.id}` — that lives only while the user
  is connected. The first LiveView mount attaches; subsequent mounts
  (multi-tab, editor + dashboard) share the same world. The last
  disconnect schedules a grace-period timer; if no re-attach happens
  within that window, the world auto-snapshots to disk and stops. The
  next connection auto-restores from that snapshot.

  See `docs/superpowers/specs/2026-05-28-personal-sandbox-design.md`.
  """
  use GenServer

  @grace_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the world id for a user id. Pure helper."
  @spec world_id_for(integer) :: {:sandbox, integer}
  def world_id_for(user_id) when is_integer(user_id), do: {:sandbox, user_id}

  @impl true
  def init(_opts), do: {:ok, %{}}
end
```

- [ ] **Step 4: Verify the test passes**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: 1 test, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/sandboxes.ex test/lenies/sandboxes_test.exs
git commit -m "feat(sandboxes): Lenies.Sandboxes skeleton + world_id_for/1"
```

---

## Task 2: `attach/1` — first attach starts a world

**Files:**
- Modify: `lib/lenies/sandboxes.ex`
- Modify: `test/lenies/sandboxes_test.exs`

- [ ] **Step 1: Failing test**

Append to `test/lenies/sandboxes_test.exs`:

```elixir
  describe "attach/1 — first attach" do
    setup do
      # Start a fresh Sandboxes manager isolated to this test (or rely on the
      # one started by Application — but for unit isolation, start our own).
      start_supervised!({Lenies.Sandboxes, []})
      :ok
    end

    test "starts the user's sandbox world and registers the caller" do
      user_id = unique_user_id()
      assert :ok = Lenies.Sandboxes.attach(user_id)
      assert Lenies.Worlds.alive?({:sandbox, user_id})
      # cleanup
      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end
  end

  defp unique_user_id, do: :erlang.unique_integer([:positive])
```

(The `Lenies.Sandboxes` may already be running under the Application supervisor — in that case `start_supervised!` raises. If so, switch to a per-test `GenServer.start_link/1` with a name like `Module.concat(Lenies.Sandboxes, "Test\#{System.unique_integer()}")`. For NOW, before Task 7 adds it to the supervision tree, `start_supervised!` works.)

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: FAIL — `Lenies.Sandboxes.attach/1 is undefined or private`.

- [ ] **Step 3: Add `attach/1` and the start-world path**

Edit `lib/lenies/sandboxes.ex`:

```elixir
  @doc """
  Attach the calling LiveView pid to `user_id`'s sandbox. Ensures the world is
  running (starting it and auto-restoring from snapshot if needed) and
  monitors the caller so disconnect is detected automatically.
  """
  @spec attach(integer) :: :ok | {:error, term}
  def attach(user_id) when is_integer(user_id) do
    GenServer.call(__MODULE__, {:attach, user_id, self()})
  end

  @impl true
  def handle_call({:attach, user_id, pid}, _from, state) do
    case Map.get(state, user_id) do
      nil ->
        case start_sandbox(user_id) do
          {:ok, _world_pid} ->
            ref = Process.monitor(pid)
            entry = %{
              world_id: world_id_for(user_id),
              connections: MapSet.new([pid]),
              monitors: %{pid => ref},
              pending_stop: nil,
              generation: 1
            }
            {:reply, :ok, Map.put(state, user_id, entry)}
          {:error, _} = err ->
            {:reply, err, state}
        end

      %{} = _entry ->
        # Already attached (Task 3); reply :ok for now and bump in next task.
        {:reply, :ok, state}
    end
  end

  defp start_sandbox(user_id) do
    case Lenies.Worlds.start_world(world_id_for(user_id), %{}) do
      {:ok, sup_pid} -> {:ok, sup_pid}
      {:error, {:already_started, sup_pid}} -> {:ok, sup_pid}
      {:error, _} = err -> err
    end
  end
```

- [ ] **Step 4: Verify the test passes**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/sandboxes.ex test/lenies/sandboxes_test.exs
git commit -m "feat(sandboxes): attach/1 — first attach starts the user's sandbox world"
```

---

## Task 3: `attach/1` — second attach adds the pid

**Files:**
- Modify: `lib/lenies/sandboxes.ex`
- Modify: `test/lenies/sandboxes_test.exs`

- [ ] **Step 1: Failing test**

Append to `test/lenies/sandboxes_test.exs` inside the existing `describe "attach/1 — first attach"` block (or a new describe — your call):

```elixir
    test "second attach shares the same world, registers both pids" do
      user_id = unique_user_id()
      assert :ok = Lenies.Sandboxes.attach(user_id)

      task = Task.async(fn ->
        :ok = Lenies.Sandboxes.attach(user_id)
        send_back = self()
        receive do {:exit, parent} -> send(parent, :done) end
      end)

      # Give the task time to register
      Process.sleep(50)

      state = :sys.get_state(Lenies.Sandboxes)
      entry = state[user_id]
      assert MapSet.size(entry.connections) == 2

      # cleanup the task
      send(task.pid, {:exit, self()})
      assert_receive :done, 1_000
      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: FAIL — `entry.connections` still contains only the first pid (the second attach hit the "already attached, reply :ok" branch).

- [ ] **Step 3: Update the existing-entry branch**

Replace the `%{} = _entry` clause in `handle_call({:attach, …})` with:

```elixir
      %{} = entry ->
        new_entry =
          entry
          |> add_connection(pid)
          |> cancel_pending_stop()
          |> bump_generation()
        {:reply, :ok, Map.put(state, user_id, new_entry)}
```

Add the helpers:

```elixir
  defp add_connection(entry, pid) do
    if MapSet.member?(entry.connections, pid) do
      entry
    else
      ref = Process.monitor(pid)
      %{entry |
        connections: MapSet.put(entry.connections, pid),
        monitors: Map.put(entry.monitors, pid, ref)}
    end
  end

  defp cancel_pending_stop(%{pending_stop: nil} = entry), do: entry
  defp cancel_pending_stop(%{pending_stop: ref} = entry) do
    _ = Process.cancel_timer(ref)
    %{entry | pending_stop: nil}
  end

  defp bump_generation(entry), do: %{entry | generation: entry.generation + 1}
```

- [ ] **Step 4: Verify the test passes**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/sandboxes.ex test/lenies/sandboxes_test.exs
git commit -m "feat(sandboxes): second attach shares world, monitors additional pids, cancels pending stop"
```

---

## Task 4: Detach via `:DOWN` schedules the grace timer

**Files:**
- Modify: `lib/lenies/sandboxes.ex`
- Modify: `test/lenies/sandboxes_test.exs`

- [ ] **Step 1: Failing test**

Append:

```elixir
  describe "detach via :DOWN" do
    setup do
      start_supervised!({Lenies.Sandboxes, []})
      :ok
    end

    test "last pid disconnect schedules a grace timer; world still running" do
      user_id = unique_user_id()
      task =
        Task.async(fn ->
          :ok = Lenies.Sandboxes.attach(user_id)
          receive do :exit -> :ok end
        end)
      Process.sleep(50)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(100)

      state = :sys.get_state(Lenies.Sandboxes)
      entry = state[user_id]
      assert MapSet.size(entry.connections) == 0
      refute is_nil(entry.pending_stop), "expected a pending_stop timer ref"
      assert Lenies.Worlds.alive?({:sandbox, user_id}), "world must still be running during grace"

      # cleanup
      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end

    test "one pid disconnect of two does NOT schedule a grace timer" do
      user_id = unique_user_id()
      :ok = Lenies.Sandboxes.attach(user_id)

      task =
        Task.async(fn ->
          :ok = Lenies.Sandboxes.attach(user_id)
          receive do :exit -> :ok end
        end)
      Process.sleep(50)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(100)

      state = :sys.get_state(Lenies.Sandboxes)
      entry = state[user_id]
      assert MapSet.size(entry.connections) == 1
      assert is_nil(entry.pending_stop)

      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end
  end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: FAIL — `:DOWN` is not handled, `entry.pending_stop` stays `nil`.

- [ ] **Step 3: Handle `:DOWN`**

Add to `lib/lenies/sandboxes.ex`:

```elixir
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case find_user_for_pid(state, pid) do
      nil -> {:noreply, state}
      user_id -> {:noreply, remove_pid(state, user_id, pid)}
    end
  end

  defp find_user_for_pid(state, pid) do
    Enum.find_value(state, fn {user_id, entry} ->
      if MapSet.member?(entry.connections, pid), do: user_id
    end)
  end

  defp remove_pid(state, user_id, pid) do
    entry = state[user_id]
    new_connections = MapSet.delete(entry.connections, pid)
    new_monitors = Map.delete(entry.monitors, pid)
    new_entry = %{entry | connections: new_connections, monitors: new_monitors}

    new_entry =
      if MapSet.size(new_connections) == 0 do
        schedule_grace_stop(new_entry, user_id)
      else
        new_entry
      end

    Map.put(state, user_id, new_entry)
  end

  defp schedule_grace_stop(entry, user_id) do
    ref =
      Process.send_after(
        self(),
        {:maybe_stop, user_id, entry.generation},
        grace_ms()
      )
    %{entry | pending_stop: ref}
  end

  defp grace_ms, do: Application.get_env(:lenies, :sandbox_grace_ms, @grace_ms)
```

- [ ] **Step 4: Verify the tests pass**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/sandboxes.ex test/lenies/sandboxes_test.exs
git commit -m "feat(sandboxes): :DOWN handling — schedule grace timer on last disconnect"
```

---

## Task 5: Generation-protected `:maybe_stop` snapshots and stops the world

**Files:**
- Modify: `lib/lenies/sandboxes.ex`
- Modify: `test/lenies/sandboxes_test.exs`

- [ ] **Step 1: Failing test**

Append:

```elixir
  describe ":maybe_stop" do
    setup do
      start_supervised!({Lenies.Sandboxes, []})
      # Speed up grace period for tests so we don't wait 30 s.
      Application.put_env(:lenies, :sandbox_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :sandbox_grace_ms) end)
      :ok
    end

    test "grace expires with no re-attach: world stops, entry removed" do
      user_id = unique_user_id()
      task =
        Task.async(fn ->
          :ok = Lenies.Sandboxes.attach(user_id)
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task.pid, :exit)
      Task.await(task)
      # Wait grace (50 ms) plus a safety margin.
      Process.sleep(200)

      refute Lenies.Worlds.alive?({:sandbox, user_id}),
             "expected world to stop after grace expiry"
      state = :sys.get_state(Lenies.Sandboxes)
      refute Map.has_key?(state, user_id),
             "expected sandbox entry to be removed"
    end

    test "re-attach during grace cancels the timer and keeps the world" do
      user_id = unique_user_id()
      task1 =
        Task.async(fn ->
          :ok = Lenies.Sandboxes.attach(user_id)
          receive do :exit -> :ok end
        end)
      Process.sleep(20)
      send(task1.pid, :exit)
      Task.await(task1)
      Process.sleep(10)  # 10 ms into the 50 ms grace

      # Re-attach
      :ok = Lenies.Sandboxes.attach(user_id)
      Process.sleep(200)  # Past the original grace window

      assert Lenies.Worlds.alive?({:sandbox, user_id}),
             "expected world to survive after re-attach"
      # cleanup
      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end
  end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: FAIL — `:maybe_stop` not handled, world stays running.

- [ ] **Step 3: Handle `:maybe_stop`**

Add to `lib/lenies/sandboxes.ex`:

```elixir
  @impl true
  def handle_info({:maybe_stop, user_id, gen}, state) do
    case state[user_id] do
      nil ->
        # User entry already gone (manual stop_world from elsewhere?). No-op.
        {:noreply, state}

      %{generation: ^gen, connections: conns} when conns == MapSet.new() or map_size(conns) == 0 ->
        # The generation matches AND no one has re-attached.
        # (MapSet.size on an empty MapSet is 0; map_size handles either.)
        # Save the auto snapshot (best-effort), then stop the world.
        auto_save(user_id)
        _ = Lenies.Worlds.stop_world({:sandbox, user_id})
        {:noreply, Map.delete(state, user_id)}

      _other ->
        # Either generation changed (re-attach) or connections is non-empty.
        # Ignore — the new state has been refreshed.
        {:noreply, state}
    end
  end

  defp auto_save(user_id) do
    case Lenies.Worlds.save_snapshot({:sandbox, user_id}, "auto") do
      :ok ->
        :ok
      {:error, reason} ->
        require Logger
        Logger.error("Lenies.Sandboxes: auto-snapshot save failed for user #{user_id}: #{inspect(reason)}")
        :ok
    end
  end
```

(Note: the `when conns == MapSet.new()` pattern is iffy — `MapSet.new()` builds at runtime. Use a guard call `MapSet.size(conns) == 0` in a `cond` body instead; the cleaner form is:)

```elixir
  def handle_info({:maybe_stop, user_id, gen}, state) do
    case state[user_id] do
      nil ->
        {:noreply, state}

      %{generation: ^gen} = entry ->
        if MapSet.size(entry.connections) == 0 do
          auto_save(user_id)
          _ = Lenies.Worlds.stop_world({:sandbox, user_id})
          {:noreply, Map.delete(state, user_id)}
        else
          {:noreply, state}
        end

      _other ->
        # Generation changed (re-attach happened).
        {:noreply, state}
    end
  end
```

Use the cleaner form.

- [ ] **Step 4: Verify the tests pass**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/sandboxes.ex test/lenies/sandboxes_test.exs
git commit -m "feat(sandboxes): generation-protected :maybe_stop auto-snapshots and stops the world"
```

---

## Task 6: Auto-restore on first attach when an `auto` snapshot exists

**Files:**
- Modify: `lib/lenies/sandboxes.ex`
- Modify: `test/lenies/sandboxes_test.exs`

- [ ] **Step 1: Failing test**

Append:

```elixir
  describe "auto-restore" do
    setup do
      start_supervised!({Lenies.Sandboxes, []})
      Application.put_env(:lenies, :sandbox_grace_ms, 50)
      # Snapshot directory under a tmp_dir per test for cleanliness.
      :ok
    end

    @tag :tmp_dir
    test "first attach restores from an existing auto snapshot", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      user_id = unique_user_id()
      world_id = {:sandbox, user_id}

      # Attach, set a distinct color override, detach + wait grace.
      task =
        Task.async(fn ->
          :ok = Lenies.Sandboxes.attach(user_id)
          {:ok, handle} = Lenies.Worlds.handle(world_id)
          Lenies.SpeciesColor.set_override(handle, "auto-marker", "#abcdef")
          send(self(), :ok)
          receive do :exit -> :ok end
        end)
      Process.sleep(50)
      send(task.pid, :exit)
      Task.await(task)
      Process.sleep(200)

      refute Lenies.Worlds.alive?(world_id), "world stopped after grace"

      # Re-attach in a fresh task; the new world should restore the marker.
      task2 =
        Task.async(fn ->
          :ok = Lenies.Sandboxes.attach(user_id)
          {:ok, handle} = Lenies.Worlds.handle(world_id)
          color = Lenies.SpeciesColor.override(handle, "auto-marker")
          send(self(), :ok)
          receive do {:check, parent} -> send(parent, color) end
        end)
      Process.sleep(100)
      send(task2.pid, {:check, self()})
      assert_receive "#abcdef", 1_000

      send(task2.pid, :exit)
      Task.await(task2)
      :ok = Lenies.Worlds.stop_world(world_id)
    end

    @tag :tmp_dir
    test "first attach with NO auto snapshot starts an empty world", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      user_id = unique_user_id()
      world_id = {:sandbox, user_id}

      :ok = Lenies.Sandboxes.attach(user_id)
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      assert :ets.tab2list(handle.tables.lenies) == []
      :ok = Lenies.Worlds.stop_world(world_id)
    end
  end
```

(Use `task1.pid`'s mailbox trick to keep the task alive while we operate on the world from its inside, since `Lenies.SpeciesColor.set_override` writes to ETS owned by World — actually it's the world's ETS, not the caller's, so we don't need the task at all for the writes. Simplify: do the operations from the test process.)

A cleaner version that the implementer should use:

```elixir
    @tag :tmp_dir
    test "first attach restores from an existing auto snapshot", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      user_id = unique_user_id()
      world_id = {:sandbox, user_id}

      # 1) Attach as the test process, plant a marker, detach.
      :ok = Lenies.Sandboxes.attach(user_id)
      {:ok, handle1} = Lenies.Worlds.handle(world_id)
      Lenies.SpeciesColor.set_override(handle1, "auto-marker", "#abcdef")

      # Manually fire detach via :DOWN by exiting in a child task and monitoring.
      # Simpler: explicit detach + wait grace.
      :ok = Lenies.Sandboxes.detach(user_id)
      Process.sleep(200)   # grace = 50 ms; safety margin.

      refute Lenies.Worlds.alive?(world_id)

      # 2) Re-attach; the marker should be restored.
      :ok = Lenies.Sandboxes.attach(user_id)
      {:ok, handle2} = Lenies.Worlds.handle(world_id)
      assert Lenies.SpeciesColor.override(handle2, "auto-marker") == "#abcdef"

      # cleanup
      :ok = Lenies.Worlds.stop_world(world_id)
    end
```

This requires adding `detach/1` as an explicit cast (the spec calls for it). If you've not added it yet, add it now alongside the auto-restore changes. The `:DOWN` path remains for actual LV disconnect.

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: FAIL — either `detach/1` undefined OR (after adding it) auto-restore returns the empty marker because no restore happens.

- [ ] **Step 3: Add `detach/1` and the auto-restore logic**

Add to `lib/lenies/sandboxes.ex`:

```elixir
  @doc "Explicit detach from the user's sandbox. Useful in tests."
  @spec detach(integer) :: :ok
  def detach(user_id) when is_integer(user_id) do
    GenServer.cast(__MODULE__, {:detach, user_id, self()})
  end

  @impl true
  def handle_cast({:detach, user_id, pid}, state) do
    case Map.get(state, user_id) do
      nil -> {:noreply, state}
      %{} -> {:noreply, remove_pid(state, user_id, pid)}
    end
  end
```

Refactor `start_sandbox/1` to also attempt the auto-restore:

```elixir
  defp start_sandbox(user_id) do
    world_id = world_id_for(user_id)
    case Lenies.Worlds.start_world(world_id, %{}) do
      {:ok, sup_pid} ->
        maybe_auto_restore(world_id)
        {:ok, sup_pid}
      {:error, {:already_started, sup_pid}} ->
        {:ok, sup_pid}
      {:error, _} = err ->
        err
    end
  end

  defp maybe_auto_restore(world_id) do
    case Lenies.Snapshot.validate(world_id, "auto") do
      :ok ->
        case Lenies.Worlds.restore_snapshot(world_id, "auto") do
          :ok ->
            :ok
          {:error, reason} ->
            quarantine_broken_auto(world_id, reason)
            :ok
        end

      {:error, :not_found} ->
        # No auto snapshot — fresh empty world.
        :ok

      {:error, reason} ->
        quarantine_broken_auto(world_id, reason)
        :ok
    end
  end

  defp quarantine_broken_auto(world_id, reason) do
    require Logger
    root = Application.get_env(:lenies, :snapshot_root, System.tmp_dir!())
    dir = Path.join([root, Lenies.Worlds.id_to_path(world_id), "auto"])
    if File.dir?(dir) do
      broken = Path.join([root, Lenies.Worlds.id_to_path(world_id), "auto.broken.#{System.system_time(:second)}"])
      File.rename(dir, broken)
      Logger.warning("Lenies.Sandboxes: auto snapshot for #{inspect(world_id)} quarantined as #{broken} (#{inspect(reason)})")
    end
    :ok
  end
```

(Adapt to the actual `Lenies.Snapshot.validate/2` return shape. Per the spec, it returns `:ok | {:error, term}`. The implementer should check `lib/lenies/snapshot.ex:123` to confirm what `:not_found` looks like — it might be `{:error, :missing_files}` or similar. Adjust the pattern match.)

- [ ] **Step 4: Verify the tests pass**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: 9 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/sandboxes.ex test/lenies/sandboxes_test.exs
git commit -m "feat(sandboxes): auto-restore on first attach; quarantine broken auto snapshots"
```

---

## Task 7: Adopt-on-restart + `sandboxes:manager_up` broadcast

**Files:**
- Modify: `lib/lenies/sandboxes.ex`
- Modify: `lib/lenies/application.ex` — add `Lenies.Sandboxes` to children
- Modify: `test/lenies/sandboxes_test.exs`

- [ ] **Step 1: Add Sandboxes to the supervision tree**

In `lib/lenies/application.ex` children list, after `Lenies.Worlds.Supervisor`, add:

```elixir
Lenies.Sandboxes,
```

(Keep `:primary` auto-boot intact for THIS task — the cleanup is Task 12.)

- [ ] **Step 2: Failing test**

Append:

```elixir
  describe "crash recovery / adopt" do
    test "on init, adopts running {:sandbox, _} worlds and broadcasts sandboxes:manager_up" do
      # The Application-supervised Sandboxes is already running. Start a sandbox
      # under it, then kill the manager and verify the new instance adopts the
      # running world and broadcasts.
      user_id = unique_user_id()
      :ok = Lenies.Sandboxes.attach(user_id)
      assert Lenies.Worlds.alive?({:sandbox, user_id})

      Phoenix.PubSub.subscribe(Lenies.PubSub, "sandboxes:manager_up")
      pid = Process.whereis(Lenies.Sandboxes)
      Process.exit(pid, :kill)

      assert_receive :sandboxes_manager_up, 1_000

      # Adopted: the state has an entry for user_id with empty connections and
      # a pending stop timer.
      Process.sleep(50)  # let init complete
      state = :sys.get_state(Lenies.Sandboxes)
      assert Map.has_key?(state, user_id)
      assert MapSet.size(state[user_id].connections) == 0
      refute is_nil(state[user_id].pending_stop)

      # cleanup
      :ok = Lenies.Worlds.stop_world({:sandbox, user_id})
    end
  end
```

(This test requires that `start_supervised!` from earlier describes NOT be used here — adapt your describe block to NOT start a per-test Sandboxes; rely on the Application-supervised one. Tag this describe `@moduletag :integration` if needed.)

- [ ] **Step 3: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: FAIL — `Application` doesn't yet supervise `Lenies.Sandboxes`, OR (after Step 1) the broadcast doesn't fire on init.

- [ ] **Step 4: Implement adopt + broadcast**

Replace `init/1` in `lib/lenies/sandboxes.ex`:

```elixir
  @impl true
  def init(_opts) do
    state =
      Lenies.Worlds.list()
      |> Enum.filter(&match?({:sandbox, _}, &1))
      |> Enum.reduce(%{}, fn {:sandbox, user_id} = world_id, acc ->
        ref = Process.send_after(self(), {:maybe_stop, user_id, 1}, grace_ms())
        Map.put(acc, user_id, %{
          world_id: world_id,
          connections: MapSet.new(),
          monitors: %{},
          pending_stop: ref,
          generation: 1
        })
      end)

    Phoenix.PubSub.broadcast(Lenies.PubSub, "sandboxes:manager_up", :sandboxes_manager_up)
    {:ok, state}
  end
```

- [ ] **Step 5: Verify the test passes**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs'
```

Expected: 10 tests, 0 failures.

Also run the full suite to confirm nothing else broke (Application now supervises one more child):

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: previous count + 10 new sandboxes tests, 0 failures (the new tests may overlap counts with existing ones; verify visually).

- [ ] **Step 6: Commit**

```bash
git add lib/lenies/sandboxes.ex lib/lenies/application.ex test/lenies/sandboxes_test.exs
git commit -m "feat(sandboxes): adopt running sandbox worlds on init + sandboxes:manager_up broadcast; supervise under Application"
```

---

## Task 8: Migrate `DashboardLive` to user's sandbox

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Modify: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 1: Update mount**

In `lib/lenies_web/live/dashboard_live.ex`, the current `mount/3` starts:

```elixir
  def mount(_params, _session, socket) do
    world_id = :primary
    world_handle = fetch_primary_handle()
    ...
```

Replace with:

```elixir
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    user_id = user.id
    world_id = {:sandbox, user_id}

    :ok = Lenies.Sandboxes.attach(user_id)
    {:ok, world_handle} = Lenies.Worlds.handle(world_id)

    if connected?(socket) do
      prefix = world_handle.pubsub_prefix
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:tick")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:control")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:fx")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "sandboxes:manager_up")
    end

    # … rest of existing mount body unchanged …
  end

  @impl true
  def handle_info(:sandboxes_manager_up, socket) do
    :ok = Lenies.Sandboxes.attach(socket.assigns.current_scope.user.id)
    {:noreply, socket}
  end
```

Drop the obsolete `fetch_primary_handle/0` private helper if it exists in this file (or leave for Task 10 cleanup if it's referenced elsewhere).

- [ ] **Step 2: Update tests to log a user in**

`test/lenies_web/live/dashboard_live_test.exs` likely already uses `register_and_log_in_user` (added in sub-project #1). Verify that the setup is:

```elixir
  setup %{conn: conn} do
    user = Lenies.AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end
```

If not, add it.

Add an assertion to one of the existing tests (or a new test) that confirms the dashboard mounts on the user's sandbox:

```elixir
    test "mount uses {:sandbox, user.id} as the world_id", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/")
      world_id = :sys.get_state(view.pid).socket.assigns.world_id
      assert world_id == {:sandbox, user.id}
      assert Lenies.Worlds.alive?(world_id)
    end
```

- [ ] **Step 3: Run the dashboard tests**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/dashboard_live_test.exs'
```

Expected: all pass. If a test fails because it referenced `:primary` directly in an assertion or in setup, update it.

- [ ] **Step 4: Run the full suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: all pass (other LiveView tests may still hit `:primary` — that's Task 9).

- [ ] **Step 5: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat(web): DashboardLive mounts on {:sandbox, user.id} via Lenies.Sandboxes"
```

---

## Task 9: Migrate the other 4 authenticated LiveView routes

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`
- Modify: `lib/lenies_web/live/lenie_inspector_live.ex`
- Modify: `lib/lenies_web/live/species_live.ex`
- Modify: their `test/` counterparts

The other 4 LiveViews (`editor_live.ex`, `lenie_inspector_live.ex`, `species_live.ex`, and the Editor's `:edit/:hash` action which is the same module as `:new`) currently mount with `world_id = :primary`. Apply the same pattern as Task 8:

- [ ] **Step 1: Update each LiveView's `mount/3`**

For each file, replace the `world_id = :primary` + `world_handle = …` opener with:

```elixir
  def mount(_params_or_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    world_id = {:sandbox, user_id}

    :ok = Lenies.Sandboxes.attach(user_id)
    {:ok, world_handle} = Lenies.Worlds.handle(world_id)

    if connected?(socket) do
      prefix = world_handle.pubsub_prefix
      # Subscribe to whatever scoped topics THIS LiveView needs (lenie:<id>
      # for the inspector, etc.). Reuse the existing `prefix`-based subscribes
      # that Task 11 of sub-project #2 already put in place.
    end

    {:ok, socket |> assign(world_id: world_id, world_handle: world_handle) |> ...existing assigns...}
  end

  @impl true
  def handle_info(:sandboxes_manager_up, socket) do
    :ok = Lenies.Sandboxes.attach(socket.assigns.current_scope.user.id)
    {:noreply, socket}
  end
```

The Editor's `mount/3` may have a `params` map for `:edit/:hash` — adapt the parameter name but keep the same body shape.

- [ ] **Step 2: Update each test file**

Each `test/lenies_web/live/<name>_test.exs` likely already does `register_and_log_in_user`. If a test asserts on `world_id == :primary` or sets up a `:primary` world directly, switch to `{:sandbox, user.id}`. Most tests should still work transparently because the LiveView mount handles the sandbox start.

- [ ] **Step 3: Compile and run the 4 test files**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs test/lenies_web/live/lenie_inspector_live_test.exs test/lenies_web/live/species_live_test.exs'
```

Expected: all pass.

- [ ] **Step 4: Run the full suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex lib/lenies_web/live/lenie_inspector_live.ex lib/lenies_web/live/species_live.ex test/lenies_web/live/editor_live_test.exs test/lenies_web/live/lenie_inspector_live_test.exs test/lenies_web/live/species_live_test.exs
git commit -m "feat(web): EditorLive, LenieInspectorLive, SpeciesLive mount on user's sandbox"
```

---

## Task 10: Remove `Lenies.Worlds.primary_handle/0` and Telemetry's `:primary` reference

**Files:**
- Modify: `lib/lenies/worlds.ex`
- Modify: `lib/lenies/telemetry.ex`
- Modify: callers (grep + migrate)

- [ ] **Step 1: Grep for callers**

```bash
grep -rn 'primary_handle\b' lib test
```

Expected callers (from prior work):
- `lib/lenies/telemetry.ex:30` (the `:primary` fetch)
- `lib/lenies_web/live/controls_panel_component.ex` (custom seed spawn)
- `lib/lenies_web/grid_renderer.ex` (color computation)
- `lib/lenies_web/live/editor_live.ex` (suggested_color)
- ~10-15 test files

- [ ] **Step 2: Migrate each caller**

For LiveView callers, source the handle from socket assigns: change `Lenies.Worlds.primary_handle()` to `socket.assigns.world_handle` (or pass the handle explicitly to component functions). After Tasks 8-9, every LV has `:world_handle` in assigns.

For component-internal helpers that don't have socket access (e.g. a grid renderer function called with raw data), accept the handle as a parameter from the caller.

For `lib/lenies/telemetry.ex:30`, the `:primary` reference is in the `fetch_handle(:primary)` fallback inside Telemetry's `init/1`. Since Telemetry is started per-world (T9 of #2), the world_id comes from its start args. Trace whether this `:primary` literal is still reachable — if it's a dead fallback, remove it. If it's still used as a default, change it to require world_id explicitly.

For test files: each call to `Lenies.Worlds.primary_handle()` becomes either:
- `start_test_world/1` + `handle` lookup (for tests that don't have a user), or
- `Lenies.Sandboxes.attach(user_id)` + `Lenies.Worlds.handle({:sandbox, user_id})` (for tests with a user).

Migrate them mechanically.

- [ ] **Step 3: Delete `primary_handle/0`**

In `lib/lenies/worlds.ex`, remove the `primary_handle/0` function and its `@doc`.

- [ ] **Step 4: Verify no remaining references**

```bash
grep -rn 'primary_handle\b' lib test
```

Expected: zero matches.

- [ ] **Step 5: Run the full suite + compile**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix compile --warnings-as-errors'
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: clean compile + all pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: drop Lenies.Worlds.primary_handle/0; migrate callers to socket assigns / explicit world_id"
```

---

## Task 11: Remove the 11 `Lenies.World.X` module-level delegators

**Files:**
- Modify: `lib/lenies/world.ex`
- Modify: callers (grep + migrate)

The functions to remove (kept as #2 compat shims):
- `sterilize/0`, `pause/0`, `resume/0`, `paused?/0`
- `action/1`, `spawn_lenie/2`, `lenie_died/4`
- `snapshot_stats/0`, `tick_now/0`, `reconcile/0`, `restore_tables/1`

Plus drop the `world_id: :primary` default from `start_link/1` so callers must pass `:world_id`.

- [ ] **Step 1: Grep for callers**

```bash
grep -rnE 'Lenies\.World\.(sterilize|pause|resume|paused\?|action|spawn_lenie|lenie_died|snapshot_stats|tick_now|reconcile|restore_tables)\b' lib test
```

Each match is a caller. For each, replace with `Lenies.Worlds.<fn>(world_id, ...)` where `world_id` comes from:
- LiveViews: `@world_id` from assigns (already in place after Tasks 8-9)
- Tests: depends on test intent — either `{:sandbox, user.id}` from test setup or a generic atom from `start_test_world/1`.

- [ ] **Step 2: Drop the `:primary` default in `start_link/1`**

In `lib/lenies/world.ex`, find:

```elixir
def start_link(opts \\ []) do
  world_id = Keyword.get(opts, :world_id, :primary)
  ...
end
```

Change to:

```elixir
def start_link(opts) do
  world_id = Keyword.fetch!(opts, :world_id)
  ...
end
```

(Drop the default `\\ []`. Callers MUST pass opts with `:world_id`.)

- [ ] **Step 3: Delete the 11 module helpers**

In `lib/lenies/world.ex`, find the helper block near the top (around lines 60-120 after T10 of #2) and delete the 11 functions listed above. Keep `start_link/1`, `init/1`, all `handle_call`/`handle_cast`/`handle_info` clauses, and private helpers.

- [ ] **Step 4: Verify no remaining references**

```bash
grep -rnE 'Lenies\.World\.(sterilize|pause|resume|paused\?|action|spawn_lenie|lenie_died|snapshot_stats|tick_now|reconcile|restore_tables)\b' lib test
```

Expected: zero matches.

- [ ] **Step 5: Compile + run the full suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix compile --warnings-as-errors'
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: clean + all pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: drop the 11 Lenies.World.X delegators; World.start_link/1 requires :world_id"
```

---

## Task 12: Remove `:primary` auto-boot; migrate test infrastructure

**Files:**
- Modify: `lib/lenies/application.ex`
- Modify: `test/support/world_test_helpers.ex`
- Modify: ~28 test files that reference `:primary` / `start_primary`

- [ ] **Step 1: Remove the `:primary` boot from Application**

In `lib/lenies/application.ex`, find:

```elixir
if Application.get_env(:lenies, :auto_start_simulation, true) do
  {:ok, _} = Lenies.Worlds.start_world(:primary, %{})
end
```

Delete the block. The `Lenies.Worlds.Supervisor` (already a child) remains; it just has no children at boot.

Also remove any documentation comments or moduledoc references to `:auto_start_simulation` in this file.

- [ ] **Step 2: Refactor the test helper**

In `test/support/world_test_helpers.ex`, the current `start_primary/1` (and its sibling `stop_primary/0`) hardcode `:primary`. Replace with a parameterized version:

```elixir
defmodule Lenies.WorldTestHelpers do
  @moduledoc """
  Test-only helpers for spinning up isolated worlds without going through
  Lenies.Sandboxes. Use `start_test_world/1` for tests that don't care
  about user-scoping; use `Lenies.Sandboxes.attach(user.id)` directly for
  tests that exercise the per-user lifecycle.
  """

  @doc """
  Starts an isolated world keyed by a unique atom and returns its world_id.
  Caller is responsible for calling `stop_test_world/1` (typically in
  `on_exit/1`).

  ## Options
  - `:tick_interval_ms` — overrides the world's tick interval (default unchanged)
  - `:as` — explicit world id (e.g. `:primary` is no longer reserved; pass any atom)

  If `:as` is not given, generates a per-test atom from the test's pid.
  """
  def start_test_world(opts \\ []) do
    world_id = Keyword.get_lazy(opts, :as, &generate_test_world_id/0)
    config =
      opts
      |> Keyword.take([:tick_interval_ms, :eat_amount, :radiation_per_tick])
      |> Map.new()

    case Lenies.Worlds.start_world(world_id, config) do
      {:ok, _sup} -> {:ok, world_id}
      {:error, {:already_started, _}} -> {:ok, world_id}
      other -> other
    end
  end

  def stop_test_world(world_id) do
    Lenies.Worlds.stop_world(world_id)
  end

  defp generate_test_world_id do
    # Tests are bounded; using inspect(self()) keeps the atom table from
    # growing unbounded across test runs because pids are reused.
    String.to_atom("test_world_" <> inspect(self()))
  end
end
```

(Note the atom-pollution concern in `generate_test_world_id`. Tests within a single suite run share PIDs to some extent; across separate runs the BEAM atom table is reset. The total atom count grows with the number of distinct pids in tests — bounded. If this is a concern, switch to `{:test_world, integer}` tuples and adjust the helper signature.)

- [ ] **Step 3: Bulk-migrate the test files**

Run a grep to find every test that uses the old helpers:

```bash
grep -rln 'start_primary\|Lenies\.WorldTestHelpers\.stop_primary' test/
```

For each, replace:
- `Lenies.WorldTestHelpers.start_primary(opts)` → `{:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(opts)` and adapt subsequent references that expected `:primary` to use `world_id`.
- `Lenies.WorldTestHelpers.stop_primary()` → `Lenies.WorldTestHelpers.stop_test_world(world_id)`.

For tests that directly used `:primary` as a literal (without going through the helper):

```bash
grep -rn ':primary' test/
```

For each, decide:
- Test exercises sandbox lifecycle → use a user fixture + `Lenies.Sandboxes.attach(user.id)`.
- Test exercises a world in isolation → use `start_test_world/1` and pass the returned `world_id` through.

This step touches ~28 files but is mechanical. A `find/sed` script can do most of it; review individually because some tests have semantic dependencies on the world id (e.g. PubSub topic names with `"world:primary:"`).

For PubSub topic strings that include `"world:primary:"`, they all need updating to use the test's world id via `Lenies.Worlds.id_to_path/1`:

```elixir
prefix = "world:" <> Lenies.Worlds.id_to_path(world_id)
Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:tick")
```

- [ ] **Step 4: Verify no remaining `:primary` literals in test/**

```bash
grep -rn ':primary' test/
```

Expected: zero matches OR only in comments / docstring text.

- [ ] **Step 5: Verify no remaining `:primary` or `start_primary` in lib/**

```bash
grep -rn ':primary\|start_primary' lib/
```

Expected: zero matches OR only in comments.

- [ ] **Step 6: Compile + run the full suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix compile --warnings-as-errors'
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: clean + all pass.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: retire :primary entirely — drop app boot, rename test helper to start_test_world, migrate ~28 test files"
```

---

## Task 13: Auto-restore round-trip and 5-user smoke

**Files:**
- Modify: `test/lenies/sandboxes_test.exs`

- [ ] **Step 1: Add the integration tests**

Append to `test/lenies/sandboxes_test.exs`:

```elixir
  describe "auto-restore round-trip (integration)" do
    @moduletag :integration

    @tag :tmp_dir
    test "spawn lenies, detach, wait grace, re-attach: lenies restored", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      Application.put_env(:lenies, :sandbox_grace_ms, 50)
      on_exit(fn ->
        Application.delete_env(:lenies, :snapshot_root)
        Application.delete_env(:lenies, :sandbox_grace_ms)
      end)

      user_id = unique_user_id()
      world_id = {:sandbox, user_id}

      :ok = Lenies.Sandboxes.attach(user_id)
      {:ok, handle1} = Lenies.Worlds.handle(world_id)

      # Spawn 3 lenies of the minimal_replicator seed.
      %{codeome: codeome, default_options: opts} = Lenies.Seeds.get(:minimal_replicator)
      energy = Map.get(opts, :energy, 500.0)
      for _ <- 1..3, do: Lenies.Worlds.spawn_lenie(world_id, codeome, energy: energy)
      Process.sleep(50)

      lenies_before = :ets.tab2list(handle1.tables.lenies)
      assert length(lenies_before) >= 3

      # Detach + wait past grace.
      :ok = Lenies.Sandboxes.detach(user_id)
      Process.sleep(200)
      refute Lenies.Worlds.alive?(world_id)

      # Re-attach — auto-restore brings the lenies back.
      :ok = Lenies.Sandboxes.attach(user_id)
      {:ok, handle2} = Lenies.Worlds.handle(world_id)
      lenies_after = :ets.tab2list(handle2.tables.lenies)
      assert length(lenies_after) == length(lenies_before)

      :ok = Lenies.Worlds.stop_world(world_id)
    end
  end

  describe "concurrent users (smoke)" do
    @moduletag :integration

    test "5 users get 5 distinct worlds; all stop cleanly" do
      Application.put_env(:lenies, :sandbox_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:lenies, :sandbox_grace_ms) end)

      user_ids = for _ <- 1..5, do: unique_user_id()

      for user_id <- user_ids do
        :ok = Lenies.Sandboxes.attach(user_id)
      end

      for user_id <- user_ids do
        assert Lenies.Worlds.alive?({:sandbox, user_id})
      end

      # Detach all + wait past grace
      for user_id <- user_ids, do: Lenies.Sandboxes.detach(user_id)
      Process.sleep(200)

      for user_id <- user_ids do
        refute Lenies.Worlds.alive?({:sandbox, user_id})
      end
    end
  end
```

(Adapt `Lenies.Seeds.codeome_for/1` to the actual API exposed by the seeds module — read `lib/lenies/seeds.ex` to confirm. Substitute with the right function name.)

- [ ] **Step 2: Run the new tests**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/sandboxes_test.exs --seed 0'
```

Expected: all pass.

- [ ] **Step 3: Run the full suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add test/lenies/sandboxes_test.exs
git commit -m "test(sandboxes): auto-restore round-trip + 5-user concurrent smoke"
```

---

## Task 14: `mix precommit` green

**Files:** (none, unless `mix format` touches files)

- [ ] **Step 1: Sanity-grep for residual `:primary` references**

```bash
grep -rn ':primary\|primary_handle\|start_primary' lib test
```

Expected: empty (or only in comments / docstrings that are now historical).

- [ ] **Step 2: Run `mix precommit`**

```bash
bash -c '. ~/.asdf/asdf.sh && mix precommit'
```

Expected:
- `compile --warning-as-errors` clean
- `deps.unlock --unused` no changes
- `format` clean (if it reformats files, include them in this commit)
- full test suite 0 failures

- [ ] **Step 3: Commit any `mix format` changes**

```bash
git add -A
git commit -m "chore: precommit format pass after personal-sandbox sub-project"
```

(Skip if `format` made no changes.)

- [ ] **Step 4: Optional manual smoke**

(Defer to controller / human.) Start `iex -S mix phx.server`, register a user, log in, navigate to `/`, observe the sandbox dashboard mounts. Open `/editor/new`, save a codeome, spawn it from the dashboard, close the tab, wait 30+ s, reopen — verify the lenies are still there (auto-restore).

---

## Self-Review notes (resolved inline)

- **Spec coverage:**
  - `Lenies.Sandboxes` manager (attach/detach/grace/snapshot/restore/adopt) → Tasks 1-7 ✓
  - 5 LiveView routes mount on `{:sandbox, user.id}` → Tasks 8-9 ✓
  - `:primary` cleanup (app boot, `primary_handle/0`, 11 delegators, ~28 test files) → Tasks 10-12 ✓
  - Auto-snapshot at stop, auto-restore at first attach → Task 6 + verified end-to-end in Task 13 ✓
  - Generation counter race protection → Task 5 ✓
  - Adopt-on-restart + `sandboxes:manager_up` ordering → Task 7 ✓
  - Hidden `auto` snapshot from UI list → handled by the controls panel filtering (manual; if it iterates the per-world directory and filters out `"auto"`, add a one-line filter in Task 8 or 9; otherwise it surfaces naturally because the auto file is in a subdirectory the SAVE/RESTORE UI doesn't list)
  - Quarantine corrupt `auto/` as `auto.broken.<ts>/` → Task 6 ✓
  - 30 s grace, configurable via `:sandbox_grace_ms` → Tasks 4 + 5 ✓
  - Error handling (save fails / restore fails / start fails) → Tasks 5 + 6 ✓
  - Testing strategy (unit + LiveView integration + auto-restore round-trip + 5-user smoke) → Tasks 1-9, 13 ✓
- **Placeholder scan:** No "TBD"/"TODO". Tasks 9, 10, 11, 12 describe mechanical migrations with grep verification rather than enumerating each call site — pragmatic for a refactor that touches dozens of files; the patterns + greps are sufficient for the implementer.
- **Type consistency:** `Lenies.Sandboxes.attach/1`, `detach/1`, `world_id_for/1` signatures consistent across tasks. `%Lenies.WorldHandle{}` usage matches the spec. Snapshot name `"auto"` consistent. State entry shape `%{world_id, connections, monitors, pending_stop, generation}` defined in Task 2 and used through 7.
