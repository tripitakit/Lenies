# Sub-project #4 — Global Arena

**Date:** 2026-05-29
**Status:** Design approved, pending spec review
**Part of:** `2026-05-27-multi-user-roadmap-design.md` (sub-project #4 of 4 — the final piece)

## Goal

A single, shared, publicly-viewable `:arena` world becomes Lenies' homepage. Anonymous visitors can watch it live; logged-in users can seed into it from their personal collection. Each user can have **at most one Lenie lineage alive in the Arena at a time** — they must wait for their lineage to die naturally, OR commit `Apoptosis` (self-terminate their lineage) to seed again. The Arena pauses + snapshots when no one is watching and auto-restores when the first viewer returns.

**Deliverable:** at `/`, anyone (logged-in or not) sees the Arena live; logged-in users can seed a Lenie from their `Lenies.Collection` subject to the lineage rule; the existing Sandbox dashboard moves to `/sandbox/...`. The whole roadmap is complete.

## Starting point (after #1, #2, #3, and the cfg/2 follow-up)

- **`Lenies.Sandboxes`** owns per-user lifecycle: attach on LiveView mount, `Process.monitor` the LV pid, 30 s grace timer on last disconnect, snapshot+stop on expiry, adopt running worlds on its own restart. Mirror this for the Arena.
- **5 authenticated LiveView routes** mount on `{:sandbox, user.id}` at `/`, `/lenie/:id`, `/species/:hash`, `/editor/new`, `/editor/edit/:hash`. Everything is behind `require_authenticated_user`.
- **`:primary` is retired entirely.** No world is auto-started at boot; `Lenies.Worlds.Supervisor` has no children until something attaches.
- **`Lenies.Worlds` facade** exposes `start_world/2`, `stop_world/1`, `handle/1`, `list/0`, `alive?/1`, `spawn_lenie/3`, `action/2`, `sterilize/1`, `pause/1`, `resume/1`, `tune/3`, `snapshot_stats/1`, `save_snapshot/2`, `restore_snapshot/2`.
- **Per-world auto-snapshot/restore** working: `Lenies.Snapshot.snapshot_root/0` is the single source of truth; snapshots live at `<root>/<id_to_path(world_id)>/<name>/`.
- **`Lenies.Collection`** holds per-user codeomes (id, name, color_hex, energy_default, opcodes). Built-in seeds are a global library separate from user collections.
- **`Lenies.Registry`** with tuple keys (`{:world, id}`, `{:lenie, world_id, lenie_id}`, etc.).
- **PubSub topics scoped per world** as `"world:#{id_to_path}:tick"` etc.

## Locked decisions (from brainstorming)

| Question | Decision |
|---|---|
| Routing | Arena at `/` (public). Sandbox dashboard + inspectors + editor move under `/sandbox/...` (auth). |
| Anonymous viewing | Yes — relax #1's "whole app behind login" gate, but ONLY for `/`. Sandbox + Editor + Inspector + Settings remain auth-gated. |
| Login redirect target | `/sandbox` (the user's lab), not `/`. Respect return-to if present. |
| Lineage rule | **One alive lineage per user at a time.** New seed allowed only when `lineage_count(user) == 0` in the Arena. |
| Seed source | **Only user-written codeomes from their `Lenies.Collection`.** Built-in seeds are not seedable in the Arena. |
| Apoptosis | A user-triggered, destructive button that kills all of their alive Lenies in the Arena. Visible only when `lineage_count > 0`. Frees the user to seed again. |
| Arena lifecycle | Singleton `:arena` world. Lazy-start on first viewer attach; snapshot+stop after 30 s grace from last viewer detach. Mirrors `Lenies.Sandboxes` but for one world, not N. |
| Presence | **Count only** ("12 watching"). No usernames, no avatars — privacy-safe and YAGNI. |
| Arena control surface | Read-mostly. Visible to all viewers: canvas, sparkline, species table, presence count, inline species/Lenie inspector sidebar. Authenticated users additionally see: collection-dropdown + Seed button (when lineage=0), or Apoptosis button (when lineage>0). **Never** visible to regular users: tuning sliders, pause/sterilize, snapshot save/restore, edit codeome. |
| Deep-link Arena routes | None. `/arena/lenie/:id` and `/arena/species/:hash` are deferred — Arena uses the inline inspector sidebar only. |
| Controls component | A NEW `LeniesWeb.ArenaControlsComponent`, separate from the existing Sandbox `ControlsPanelComponent`. No `:mode` flag on the existing component. |
| Lineage tracking | A new `seeder_user_id` field on the Lenie's state, propagated to descendants via replication. Included in the Lenie's ETS snapshot so `lineage_count/1` is an `:ets.select`, not a per-process call. |
| Spawn count | Each Arena seed action spawns exactly 1 Lenie (no count slider). |

## Design

### `Lenies.Arena` lifecycle manager

One GenServer, Application-supervised, alongside `Lenies.Sandboxes`. State holds a SINGLE world (`:arena`), not a per-user map:

```elixir
defmodule Lenies.Arena do
  use GenServer
  # State: %{started?: boolean,
  #         viewers: MapSet.t(pid),
  #         monitors: %{pid => ref},
  #         pending_stop: ref | nil,
  #         generation: integer}

  @world_id :arena
  @grace_ms 30_000

  # Public API:
  def attach_viewer(pid \\ self())     # :ok
  def detach_viewer(pid \\ self())     # :ok
  def lineage_count(user_id)           # integer
  def seed(user, codeome_id)           # :ok | {:error, :lineage_alive, count} | {:error, term}
  def apoptosis(user)                  # {:ok, count_killed}
  def viewer_count()                   # integer (for UI; or via Presence list_size)
end
```

Transitions (clone of `Lenies.Sandboxes`, with `viewers` instead of per-user `connections`):

1. **First `attach_viewer`** (viewers empty, `started? == false`):
   - `Lenies.Worlds.start_world(:arena, %{})` (treat `{:error, {:already_started, _}}` as success).
   - `maybe_auto_restore(:arena)` — same path as Sandboxes; uses `Lenies.Snapshot.snapshot_root/0` + `id_to_path(:arena) == "arena"` → `<root>/arena/auto/`.
   - Add pid to `viewers`, `Process.monitor(pid)`, set `started? = true`.

2. **Subsequent `attach_viewer`**: add pid, monitor, cancel `pending_stop` if set, bump generation.

3. **`:DOWN` / `detach_viewer`**: remove pid; if `viewers` is now empty, schedule `:maybe_stop` after `grace_ms()`.

4. **`{:maybe_stop, gen}`** (generation-protected): if generation matches and viewers still empty, `auto_save("auto") → stop_world(:arena)`, reset state.

5. **Crash recovery / adopt-on-restart**: at `init/1`, if `Lenies.Worlds.alive?(:arena)`, build state with `viewers = MapSet.new()`, `started? = true`, schedule grace timer. Broadcast `"arena:manager_up"`. ArenaLive subscribers re-attach.

6. **`auto_save` resilience**: handles `:ok`, `:error` (world already stopped), and `{:error, reason}` (logs warning, doesn't crash).

### Lineage tracking: `seeder_user_id` in Lenie state

This is the new domain concept introduced by sub-project #4.

- **Lenie state field**: `state.seeder_user_id` (integer | nil, default nil).
- **Spawn opt**: `Lenies.Worlds.spawn_lenie(:arena, codeome, [seeder_user_id: user.id, ...])` — the opt flows through `Lenies.Lenie.start_link({handle, codeome, opts})` and lands in `init/1` as `state.seeder_user_id`.
- **Replication propagation**: when a Lenie replicates (the `allocate`-driven child spawn inside `Lenie.handle_call`/`handle_info` — confirm exact site by reading `lib/lenies/lenie.ex`), the child is spawned with `seeder_user_id: state.seeder_user_id`. The tag inherits naturally.
- **Snapshot inclusion**: `maybe_write_snapshot/1` includes `seeder_user_id` in the map written to `handle.tables.lenies`. This makes `Lenies.Arena.lineage_count(user_id)` an O(N) ETS scan via `:ets.select`, not N GenServer calls:

  ```elixir
  def lineage_count(user_id) do
    case Lenies.Worlds.handle(:arena) do
      {:ok, handle} ->
        ms = [{{:_, %{seeder_user_id: :"$1"}}, [{:==, :"$1", user_id}], [true]}]
        :ets.select_count(handle.tables.lenies, ms)
      :error -> 0
    end
  end
  ```

- **Default `nil`** is benign for Sandbox lenies and test fixtures — the lineage rule only inspects the Arena's `:lenies` table.

### Seeding — atomic check-and-spawn

```elixir
def seed(user, codeome_id) do
  GenServer.call(__MODULE__, {:seed, user, codeome_id})
end

def handle_call({:seed, user, codeome_id}, _from, state) do
  reply =
    with {:ok, %Codeome{} = entry} <- Lenies.Collection.get_codeome(user, codeome_id),
         0 <- lineage_count(user.id) do
      handle = arena_handle()
      codeome = Lenies.Codeome.from_list(Lenies.Collection.to_opcode_atoms(entry))
      hash = Lenies.Codeome.hash(codeome)
      Lenies.SpeciesColor.set_override(handle, hash, entry.color_hex)

      opts = [
        energy: entry.energy_default,
        dir: Enum.random([:n, :s, :e, :w]),
        seeder_user_id: user.id,
        seed_origin: "★ " <> entry.name
      ]
      Lenies.Worlds.spawn_lenie(:arena, codeome, opts)
      {:ok, :seeded}
    else
      count when is_integer(count) and count > 0 ->
        {:error, :lineage_alive, count}
      err -> err
    end
  {:reply, reply, state}
end
```

Atomicity via `GenServer.call` prevents two-tab race (both viewers click Seed simultaneously). The second call sees `lineage_count == 1` and is rejected.

### Apoptosis

```elixir
def apoptosis(user), do: GenServer.call(__MODULE__, {:apoptosis, user})

def handle_call({:apoptosis, user}, _from, state) do
  reply =
    case Lenies.Worlds.handle(:arena) do
      {:ok, handle} ->
        ms = [{{:"$1", %{seeder_user_id: :"$2"}}, [{:==, :"$2", user.id}], [:"$1"]}]
        ids = :ets.select(handle.tables.lenies, ms)
        count =
          Enum.reduce(ids, 0, fn id, acc ->
            case Registry.lookup(Lenies.Registry, {:lenie, :arena, id}) do
              [{pid, _}] ->
                Process.exit(pid, :shutdown)
                acc + 1
              [] ->
                acc
            end
          end)
        {:ok, count}

      :error ->
        {:ok, 0}
    end
  {:reply, reply, state}
end
```

Uses `:shutdown` (not `:kill`) so the Lenie's `terminate/2` runs — the World's `:lenies` ETS row and the cell occupation are cleaned up naturally. After apoptosis, the user's `lineage_count` drops to 0 and they can seed again.

### Routing

Two scopes (the `:require_authenticated_user` gate from #1 is relaxed only for `/`):

```elixir
scope "/", LeniesWeb do
  pipe_through :browser

  live_session :arena_public,
    on_mount: @sandbox_on_mount ++ [{LeniesWeb.UserAuth, :mount_current_scope}] do
    live "/", ArenaLive, :index
    live "/users/register", UserLive.Registration, :new
    live "/users/log-in", UserLive.Login, :new
    live "/users/log-in/:token", UserLive.Confirmation, :new
  end

  post "/users/log-in", UserSessionController, :create
  delete "/users/log-out", UserSessionController, :delete
end

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

**Login redirect**: `LeniesWeb.UserAuth.signed_in_path/1` returns `~p"/sandbox"` (changed from `~p"/"`). The standard gen.auth `:user_return_to` cookie still wins when set, so a user who hit a deep `/sandbox/lenie/:id` URL while logged out and then logged in lands back on that URL.

### ArenaLive

A new LiveView module, public mount. Subscribes to:
- `"world:arena:tick"` and `"world:arena:control"` (live world updates)
- `"world:arena:fx"` (conjugation visualisation)
- `"arena:presence"` (Phoenix.Presence diffs)
- `"arena:manager_up"` (for re-attach after Arena manager crash)

Mount sequence:
1. `:ok = Lenies.Arena.attach_viewer()` — starts the world on first viewer; idempotent thereafter.
2. `{:ok, handle} = Lenies.Worlds.handle(:arena)`.
3. Subscribe to the topics above and to Presence.
4. `Phoenix.Presence.track(self(), "arena:presence", session_id, %{})` — session_id is `Phoenix.LiveView.get_connect_params(socket)["_csrf_token"]` so each tab counts separately.
5. Render canvas + sparkline + species table + presence count + `<.live_component module={ArenaControlsComponent} ... />`.

The `ArenaControlsComponent` receives `current_scope`, `world_handle`, `lineage_count`, and `collection` (the user's codeomes, if any). It renders:

- **Anonymous**: a short prompt, *"Log in to seed your Lenie in the Arena"* with a link to `~p"/users/log-in"`.
- **Authenticated, collection empty**: *"Save a codeome in your Sandbox first"* with a link to `~p"/sandbox/editor/new"`.
- **Authenticated, lineage = 0**: a dropdown of the user's codeomes + a **"Seed your Lenie"** button. Button click → `Lenies.Arena.seed(@current_scope.user, selected_codeome_id)`. Reply handling: `:ok` → flash success; `{:error, :lineage_alive, n}` → re-render with count (rare race); `{:error, _}` → flash error.
- **Authenticated, lineage > 0**: shows *"Your lineage: N Lenies alive"* + an **"Apoptosis (N)"** destructive button with a confirm step. Click sequence mirrors the existing Sandbox "Sterilize" two-step (init → confirm). Confirm → `Lenies.Arena.apoptosis(@current_scope.user)`.

The component re-fetches `lineage_count` on each tick or via a focused PubSub message (`{:lineage_changed, user_id, new_count}`) broadcast by `Lenies.Arena.seed/2` and `Lenies.Arena.apoptosis/1`. Per-user PubSub topic `"arena:user:#{user_id}"` keeps the messaging scoped.

The inline inspector sidebar (click on a species table row) is identical to the Sandbox's component but with the **"Edit codeome"** button hidden (editing is sandbox-only).

### Presence

`LeniesWeb.Presence` is a new `use Phoenix.Presence` module. Tracks viewers in topic `"arena:presence"`. The ArenaLive listens to `%Phoenix.Socket.Broadcast{event: "presence_diff"}` and updates the viewer count assign. The display is text only: `"<N> watching"`.

### Sandbox migration impact

Every reference to the old paths needs to update:

- LiveViews' `push_navigate(socket, to: ~p"/...")` calls.
- HEEx template links (sidebar nav, "back" buttons, the editor's "save and return" target).
- The header's navbar component (new): show "Sandbox" link to `/sandbox` for logged-in users; "Register | Log in" for anonymous.
- All ~30 LiveView test files using `live(conn, ~p"/")`, `~p"/lenie/:id"`, etc. — bulk rewrite to `~p"/sandbox..."`.

### Auto-snapshot for the Arena

`Lenies.Arena` calls `Lenies.Worlds.save_snapshot(:arena, "auto")` at stop and `Lenies.Worlds.restore_snapshot(:arena, "auto")` at start. The snapshot path is `<Lenies.Snapshot.snapshot_root/0>/arena/auto/` — derived via `Lenies.Worlds.id_to_path(:arena) == "arena"`. The 5 tables (`cells`, `lenies`, `child_slots`, `history`, `color_overrides`) include `seeder_user_id` in the `lenies` rows by construction (it's in the snapshot map). So a restored Arena correctly preserves lineage ownership across restarts.

The quarantine path for a corrupt `auto/` (rename to `auto.broken.<ts>/`) uses the same helper as Sandboxes.

## Testing strategy

1. **`test/lenies/arena_test.exs`** — unit tests for the manager (mirror Sandboxes' suite shape):
   - First `attach_viewer` starts the world; auto-restore from snapshot if present
   - Second viewer shares the world
   - Multi-viewer + one `:DOWN` doesn't schedule grace
   - Last viewer detach schedules grace
   - Grace expires with no re-attach → `auto` snapshot written, world stopped
   - Re-attach during grace cancels the timer and bumps generation
   - Generation race protection: stale `:maybe_stop` ignored
   - Adopt-on-restart: kill the Arena pid, expect the new instance to adopt the running `:arena` world and broadcast `"arena:manager_up"`
   - Auto-restore round-trip: spawn lenies → detach → grace → re-attach → lenies restored

2. **Lineage rule tests** (in `arena_test.exs`):
   - `lineage_count/1` returns 0 for a user with no spawns
   - `seed(user, codeome_id)` with `lineage_count == 0` returns `:ok` and bumps to 1
   - Second `seed` from the same user returns `{:error, :lineage_alive, 1}`
   - A different user can seed independently (lineage counts are per-user)
   - Child Lenies inherit `seeder_user_id` from their parent (test the replication path — drive a replicator codeome for a few ticks, assert `lineage_count` grows)
   - Lineage count refleta naturally when descendants die

3. **Apoptosis tests** (in `arena_test.exs`):
   - `apoptosis(user)` with `lineage_count > 0` kills all of the user's Lenies, returns `{:ok, n}`
   - After apoptosis, `lineage_count(user.id) == 0` (after a brief `Process.sleep` for terminate to complete)
   - After apoptosis, `seed` succeeds again
   - `apoptosis(user)` with `lineage_count == 0` returns `{:ok, 0}` (idempotent)

4. **`test/lenies_web/live/arena_live_test.exs`** — integration LV:
   - Anonymous: 200 mount, sees canvas + sparkline + species table + presence count, no Seed/Apoptosis UI, sees "Log in" prompt
   - Anonymous: presence count goes from 0 → 1 on connect, back to 0 on disconnect
   - Authenticated with empty collection: sees "Save a codeome in your Sandbox first" hint
   - Authenticated, lineage=0, with a codeome: Seed button visible; click → `lineage_count == 1`
   - Authenticated, lineage>0: Apoptosis (N) button visible; confirm → kills all, `lineage_count == 0`
   - Two authenticated viewers in two test sessions see each other in presence count (2)

5. **Router migration tests** — extend `test/lenies_web/router_test.exs` or per-page tests:
   - Anon GET `/` → 200 ArenaLive (was 302 → login)
   - Anon GET `/sandbox` → 302 → `/users/log-in`
   - Auth GET `/sandbox` → 200 DashboardLive
   - Anon GET `/lenie/:id` (old path) → 404
   - Auth GET `/sandbox/lenie/:id` → 200 LenieInspectorLive
   - Login redirect: from `/users/log-in`, a fresh auth lands on `/sandbox` (not `/`)

6. **Mass-rewrite the existing ~30 LV/integration tests** that use the old `~p"/..."` paths — bulk migration, mechanical.

## Out of scope (explicitly)

- Deep-link Arena routes (`/arena/lenie/:id`, `/arena/species/:hash`) — inspector is inline only.
- Username/avatar in presence — count only.
- Admin tooling (Arena tuning sliders, force-pause, force-apoptosis other users' lineages).
- Spawn N > 1 in Arena — one Lenie per seed action by design.
- Built-in seeds in the Arena dropdown — only user-written codeomes.
- Legacy URL redirects (`/lenie/:id` → `/sandbox/lenie/:id`) — the app hasn't been publicly pushed; URLs change cleanly.
- Anti-grief measures beyond the lineage rule (rate limits, per-action throttling). The lineage rule + Apoptosis is the design's anti-grief mechanism.

## Risks & migration notes

- **Path migration is the largest task** (~30 test files + LV templates + push_navigate targets). Mechanical but voluminous, similar to sub-project #3's T12.
- **`seeder_user_id` propagation in replication** is a critical correctness point. If any spawn-from-Lenie path forgets to thread the tag, the lineage rule silently fails for that child. Test it specifically with a replicator codeome over a few ticks.
- **Race on simultaneous seed clicks** is protected by `GenServer.call` atomicity. Tested via a deliberate "two seed requests in quick succession" scenario.
- **`Process.exit(pid, :shutdown)` semantics** for Apoptosis: Lenie's `terminate/2` runs, cell is freed, `:lenies` row is deleted. Verify this is the actual cleanup path (vs. `Process.exit(pid, :kill)` which would skip terminate). If the Lenie's terminate is too slow (>5 s), Apoptosis could feel laggy — measure in tests.
- **`Lenies.Arena.seed` includes a `Lenies.Collection.get_codeome/2` call** that hits Postgres. This is fast (single-row lookup), but in the unlikely case of DB unavailability the seed call would fail. Acceptable: the user sees an error flash.
- **Presence under load**: with the Arena as the public homepage, peak concurrent viewers could be 50+. Phoenix.Presence scales well, but worth a small load test in dev (sustain 50 simulated viewers) before going public.
- **The `cfg/2` follow-up from #2** is no longer relevant — already done at the start of #3.
