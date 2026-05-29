# Sub-project #3 — Personal sandbox

**Date:** 2026-05-28
**Status:** Design approved, pending spec review
**Part of:** `2026-05-27-multi-user-roadmap-design.md` (sub-project #3 of 4)

## Goal

Each logged-in user gets their own private simulation world (a "sandbox")
that lives only while they are connected. Their work persists between
sessions via an automatic snapshot at shutdown and an automatic restore at
next start — the sandbox feels like a workspace they come back to.

**Deliverable:** authenticated users land on `/` and see their own sandbox
(`world_id = {:sandbox, user.id}`) — never a shared world. Closing the last
LiveView tab triggers a grace period, after which the sandbox auto-snapshots
to disk and stops. The next connection auto-restores from that snapshot.
`:primary` is gone from the codebase entirely.

## Starting point

After sub-projects #1, #2, and the `cfg/2` follow-up:

- `Lenies.Worlds` exposes `start_world/2`, `stop_world/1`, `handle/1`,
  `list/0`, `alive?/1`, `spawn_lenie/3`, `action/2`, `sterilize/1`,
  `pause/1`, `resume/1`, `paused?/1`, `tune/3`, `snapshot_stats/1`,
  `save_snapshot/2`, `restore_snapshot/2`. Per-world tuning now actually
  flows through the engine (`state.config`).
- `Lenies.Worlds.Supervisor` (DynamicSupervisor) supervises per-world
  sub-trees; the `Lenies.World.Supervisor` (`rest_for_one`) supervises
  `[World, LenieSupervisor, Telemetry]` for each world.
- Snapshots live at `<snapshot_root>/<id_to_path(world_id)>/<name>/` as 5
  `.tab` files (cells, lenies, child_slots, history, color_overrides);
  legacy 4-table snapshots load with color_overrides empty.
- `Lenies.Application.start/2` auto-starts `:primary` if
  `Application.get_env(:lenies, :auto_start_simulation, true)`.
- All 5 authenticated LiveView routes (`/`, `/lenie/:id`, `/species/:hash`,
  `/editor/new`, `/editor/edit/:hash`) mount with `world_id = :primary`.
- `Lenies.Worlds.primary_handle/0` is the public compat helper used by
  Telemetry, the dashboard, and tests.
- `Lenies.World` exposes 11 module-level helpers
  (`sterilize/0`/`pause/0`/`action/1`/etc.) that delegate to
  `Lenies.Worlds.X(:primary, …)`. Kept as a #2-compat shim.

## Locked decisions (from brainstorming)

| Question | Decision |
|---|---|
| Fate of `:primary` | **Retired entirely.** App boot does NOT start any world. `auto_start_simulation` is removed. `Lenies.Worlds.primary_handle/0` is removed. The 11 `Lenies.World.X` module-level delegators are removed. |
| World per user | **Exactly one sandbox per user**, keyed `{:sandbox, user.id}`. Named/multiple-sandbox-per-user is explicitly out of scope. |
| Lifecycle | **Lazy start on first connect, snapshot+stop on grace-period expiry after last disconnect.** No idle timeout while ≥1 LiveView is connected. |
| Grace period | **30 seconds** (configurable via app env, override-able in tests). Survives refreshes and brief network blips; bounded resource overlap between users. |
| Persistence between sessions | **Auto-snapshot at stop + auto-restore at start.** Snapshot name `"auto"`, written to `<root>/sandbox-<user_id>/auto/`. Named manual snapshots coexist. |
| `auto` snapshot visibility in UI | **Hidden** from the named-snapshots list in the controls panel. System-internal; the user feels it as continuity. |
| Restore-failure recovery | Start empty; rename the corrupt directory `auto.broken.<unix_ts>/` for forensics. The next stop overwrites `auto/` cleanly. |
| Quotas | **None** in #3. Per-user single-sandbox + grace-period stops bound concurrency naturally. Document monitoring as a future task if needed. |
| Onboarding | Empty world on first ever connect. User spawns from their collection (per-user codeomes) or the built-in seeds. No pre-seeding. |
| New routes | **None.** The 5 existing authenticated routes simply mount on the user's sandbox instead of `:primary`. |

## Design

### Architecture: `Lenies.Sandboxes` lifecycle manager

One new GenServer that owns the entire lifecycle policy in one place:

```elixir
defmodule Lenies.Sandboxes do
  use GenServer
  # State: %{user_id => %{world_id, connections: MapSet.t(pid), pending_stop: ref | nil, generation: integer}}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Call from a LiveView's mount/3. Ensures the user's sandbox is up and monitors the caller."
  @spec attach(user_id :: integer) :: :ok | {:error, term}
  def attach(user_id), do: GenServer.call(__MODULE__, {:attach, user_id, self()})

  @doc "Explicit detach — usually not needed; :DOWN handles disconnect."
  @spec detach(user_id :: integer) :: :ok
  def detach(user_id), do: GenServer.cast(__MODULE__, {:detach, user_id, self()})

  @doc "world_id_for(42) => {:sandbox, 42}. Pure helper, no GenServer call."
  def world_id_for(user_id), do: {:sandbox, user_id}
end
```

Added to `Lenies.Application` children list right after `Lenies.Worlds.Supervisor`.

### Lifecycle state machine

For each `user_id` the manager holds:
- `world_id` — `{:sandbox, user_id}`
- `connections` — `MapSet` of currently-monitored LiveView pids
- `pending_stop` — `:timer.tref | nil`, the scheduled `:maybe_stop` timer
- `generation` — integer, incremented on every attach; the `:maybe_stop` message carries the generation it was scheduled with, and is ignored if a newer attach has happened in the meantime

Transitions:

1. **`{:attach, user_id, pid}`**
   - If `Map.has_key?(state, user_id)` (sandbox is already known):
     - Cancel `pending_stop` if set; clear it.
     - Add `pid` to `connections`; `Process.monitor(pid)`.
     - Bump `generation`.
     - Reply `:ok`.
   - Else (first attach for this user):
     - `Lenies.Worlds.start_world(world_id_for(user_id), %{})` — `{:error, :already_started}` is treated as success (race with a sibling node restart's recovery, etc.).
     - If `auto_snapshot_exists?(user_id)`: `Lenies.Worlds.restore_snapshot(world_id, "auto")`. On error: log, rename to `auto.broken.<ts>`, continue with empty world.
     - Create state entry; add pid + monitor.
     - Reply `:ok`.
2. **`{:DOWN, _ref, :process, pid, _reason}`** (LiveView terminated):
   - Find the `user_id` whose `connections` contains this pid (or fast-path: track `pid → user_id` reverse index).
   - Remove pid from `connections`.
   - If `connections` is now empty: schedule `Process.send_after(self(), {:maybe_stop, user_id, current_generation}, grace_ms)`. Store the ref as `pending_stop`.
3. **`{:maybe_stop, user_id, gen}`**:
   - If `user_state.generation != gen` OR `connections` is non-empty: ignore (a newer attach has refreshed the lifecycle).
   - Else: snapshot then stop.
     - `Lenies.Worlds.save_snapshot(world_id, "auto")` — on error log and continue (stopping anyway is the right call; running with un-snapshotable state is worse).
     - `Lenies.Worlds.stop_world(world_id)`.
     - Remove the entry from state.
4. **`{:detach, user_id, pid}`** (cast — explicit detach from a LV that wants to leave gracefully):
   - Same as the `:DOWN` path but explicit.

### Crash recovery

If `Lenies.Sandboxes` itself crashes, its `one_for_one` parent restarts it. **The per-user sandbox worlds keep running** (they live under `Lenies.Worlds.Supervisor`, a separate sub-tree). The Sandboxes manager's in-memory state is lost, so it must adopt the running worlds. The init sequence:

1. `Lenies.Worlds.list()` returns all currently-running world ids. Filter for `{:sandbox, _}` shape.
2. For each adopted `user_id`, create a state entry with `connections = MapSet.new()` and immediately schedule a `:maybe_stop` timer (full `grace_ms`).
3. **Then** `Phoenix.PubSub.broadcast(Lenies.PubSub, "sandboxes:manager_up", :sandboxes_manager_up)`.

The ordering matters: every authenticated LiveView subscribes to `"sandboxes:manager_up"` at mount and re-issues `Sandboxes.attach(user.id)` when the broadcast fires. The broadcast happens AFTER state entries exist, so re-attaches can find their entry, cancel the grace timer, and add their pid. If a user is genuinely idle during the grace window (no active LiveView for them) their world snapshots+stops cleanly — which is exactly the policy we want.

### Routing & LiveView migration

Every authenticated LiveView's `mount/3` becomes:

```elixir
def mount(_params, _session, socket) do
  user_id = socket.assigns.current_scope.user.id
  world_id = {:sandbox, user_id}

  :ok = Lenies.Sandboxes.attach(user_id)
  {:ok, handle} = Lenies.Worlds.handle(world_id)

  if connected?(socket) do
    prefix = handle.pubsub_prefix
    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:tick")
    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:control")
    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:fx")
    # plus :lenie:#{lenie_id} for LenieInspectorLive
    Phoenix.PubSub.subscribe(Lenies.PubSub, "sandboxes:manager_up")
  end

  {:ok, socket |> assign(world_id: world_id, world_handle: handle) |> …}
end

def handle_info(:sandboxes_manager_up, socket) do
  # Manager restarted — re-attach so it knows we're here.
  :ok = Lenies.Sandboxes.attach(socket.assigns.current_scope.user.id)
  {:noreply, socket}
end
```

The 5 authenticated routes (Dashboard, LenieInspector, Species, Editor `:new`,
Editor `:edit/:hash`) get this treatment. They already assign `world_id` /
`world_handle` after sub-project #2; only the source of these changes.

No `terminate/2` callback is needed — `Lenies.Sandboxes` `Process.monitor`s
the LiveView pid at attach time and receives `:DOWN` automatically when it
dies (refresh, navigation away, browser close, network drop).

### Data layers

| Layer | Storage | Owner | Lifetime |
|---|---|---|---|
| Codeome collection | Postgres `codeomes` table (from #1) | User | Permanent |
| Sandbox `auto` snapshot | Filesystem `<snapshot_root>/sandbox-<user_id>/auto/` (5 `.tab` files) | User (filesystem) | Overwritten at each stop |
| Manual named snapshots | Filesystem `<snapshot_root>/sandbox-<user_id>/<name>/` | User (UI) | Permanent until user deletes |

No new database tables. No new ETS tables (everything is per-world from #2).

### Cleanup of `:primary`

| Site | Action |
|---|---|
| `lib/lenies/application.ex`: `Worlds.start_world(:primary, %{})` + `auto_start_simulation` env var | Removed |
| `lib/lenies/worlds.ex`: `primary_handle/0` | Removed; callers migrate to `Worlds.handle/1` with an explicit world id, or to `Lenies.Sandboxes.world_id_for/1` for sandbox callers |
| `lib/lenies/world.ex`: the 11 module-level delegators (`sterilize/0`, `pause/0`, `action/1`, `spawn_lenie/2`, `snapshot_stats/0`, etc., all hardcoding `:primary`) | Removed; the legitimate `World.start_link/1` for sub-tree use stays, but its `world_id: :primary` default is dropped — callers MUST pass `:world_id` explicitly (`Lenies.World.Supervisor` already does this) |
| `lib/lenies/telemetry.ex:30`: `fetch_handle(:primary)` | Removed; `Lenies.Telemetry` is already started per-world from #2 (T9), the residual `:primary` reference is a dead branch |
| `lib/lenies/species.ex` doc references to `:primary` | Updated |
| `test/support/world_test_helpers.ex`: `start_primary/1` | Renamed `start_test_world/1` (accepts an `:as` opt for the world id, defaults to a generated atom that doesn't pollute the atom table because test atoms are bounded) |
| ~30 test files that call `start_primary` / reference `:primary` | Bulk-migrated to `start_test_world` or `Sandboxes.attach(user.id)` depending on test intent |

### Error handling

1. **Snapshot save fails on stop** — log error with `user_id` and `reason`; stop the world anyway (running with un-snapshotable state is worse). User loses their last session's incremental work.
2. **Snapshot restore fails on start** — log warning; rename `auto/` to `auto.broken.<unix_ts>/`; continue with empty world. Next stop writes a clean `auto/`.
3. **`Worlds.start_world` returns `{:error, :already_started}`** — treat as success (recovery race).
4. **`Worlds.start_world` returns other `{:error, reason}`** — bubble up from `Sandboxes.attach/1` to the LiveView `mount/3`; the LiveView shows an error page instead of crashing.
5. **`Lenies.Sandboxes` crash** — handled by the adopt-on-restart logic above.

## Testing strategy

1. **`test/lenies/sandboxes_test.exs`** — unit tests for the manager:
   - First `attach` for a user_id with no snapshot → world is up, empty.
   - First `attach` for a user_id WITH an `auto` snapshot → world is up, state restored.
   - Second `attach` (same user, different pid) → mondo unchanged, both pids monitored.
   - `:DOWN` on one of two pids → grace timer not scheduled (one pid still attached).
   - `:DOWN` on the only pid → grace timer scheduled.
   - Re-attach during grace → timer cancelled, generation bumped.
   - Grace expires with no re-attach → `auto` snapshot written, world stopped, state entry removed.
   - Cross-user: attach for user A and user B simultaneously → two distinct sandbox worlds, isolation respected (the per-world handles' tables are disjoint).
   - Crash recovery: kill the Sandboxes pid → restart → on init, existing `{:sandbox, _}` worlds are adopted with a fresh grace timer; `sandboxes:manager_up` is broadcast.
   - Restore-failure path: corrupt the `auto/` directory before attach → restore fails → world starts empty, `auto.broken.<ts>/` exists on disk.

2. **`test/lenies_web/live/dashboard_live_test.exs` and the 4 other LiveView test files** — mount tests now create a real user via `register_and_log_in_user` (from #1) and assert:
   - `socket.assigns.world_id == {:sandbox, user.id}`
   - `socket.assigns.world_handle.id == {:sandbox, user.id}`
   - The sandbox was started by the mount (`Lenies.Worlds.alive?({:sandbox, user.id})`)
   - Two different users in two test sessions get two different sandboxes (no cross-mount state).

3. **Auto-restore round-trip** (in `sandboxes_test.exs`):
   - Attach as user X, spawn lenies via `Worlds.spawn_lenie`, trigger detach + grace expiry → world stops with `auto` written.
   - Re-attach as user X → `Worlds.handle` returns a NEW pid (fresh world process) but the lenies/cells are restored from disk.

4. **Resource sanity smoke** (in `sandboxes_test.exs`, tagged `:integration` and possibly `:slow`):
   - Spin up 5 fake users in parallel via `attach`, verify 5 distinct worlds are running, then detach all 5 and verify all 5 stop cleanly.

5. **Existing 9 multi-world isolation tests from #2** (in `worlds_test.exs`) remain unchanged — they prove the engine layer, which #3 does not touch.

## Out of scope (explicitly)

- Quotas / hard limits on concurrent sandboxes per node (document monitoring approach as a follow-up).
- Multiple named sandboxes per user (one sandbox per user only).
- Arena (#4) — separate sub-project; no `/arena` route here.
- Admin tooling to manage other users' sandboxes.
- Migration of pre-#2 snapshot files (the 4→5 table tolerance from #2 covers).

## Risks & migration notes

- **Test infrastructure refactor is the largest piece** (~30 test files
  reference `:primary` or use `start_primary`). The migration is mechanical
  but voluminous. Plan for an extended task here.
- **Race between rapid attach/detach cycles** must be handled by the
  generation counter. Implement and test concretely.
- **`Lenies.Worlds.list/0` adopt logic on `Sandboxes` restart** assumes
  that a `{:sandbox, _}` world running with NO LiveView watchers is a
  recoverable state (rather than a sign of a bug). Document this in the
  module's `@moduledoc`.
- **LiveView reconnect semantics**: a Phoenix LiveView that disconnects
  and immediately reconnects within the WebSocket reconnect interval
  (default 1s) gets a fresh pid; `Sandboxes` sees `:DOWN` of the old pid
  and `attach` of the new pid in quick succession. The 30s grace ensures
  the world keeps running across reconnect blips. This is the intended
  behaviour — verify with an integration test.
- **`auto_start_simulation` removal** breaks any out-of-tree code (none
  in this repo, but worth a note in the commit message).
- **The `Lenies.World.X(...)` delegators removal** breaks any external
  caller. All known callers in this repo were migrated in T11/T14;
  test files that still use them are migrated in this sub-project.
