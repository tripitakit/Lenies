# Sub-project #2 — Multi-world engine

**Date:** 2026-05-28
**Status:** Design approved, pending spec review
**Part of:** `2026-05-27-multi-user-roadmap-design.md` (sub-project #2 of 4)

## Goal

Parameterize the Lenies simulation engine so that N isolated worlds can run
concurrently inside one BEAM node. No user-facing change: the dashboard
continues to show a single world (a fixed `:primary` world started at boot).
The deliverable is proven by tests showing two worlds running in parallel with
no cross-talk on state, processes, or PubSub.

**Deliverable:** `Lenies.Worlds.start_world(id, config)` / `Worlds.stop_world(id)`,
plus a facade for every operation today exposed by `Lenies.World`. Two live
worlds in one node with disjoint ETS tables, scoped PubSub topics, isolated
crashes, per-world tuning, and per-world snapshots.

## Starting point (engine state after sub-project #1)

Every "single global thing" in the engine that today assumes one world per node:

- **`Lenies.World`** — GenServer registered globally as `name: __MODULE__`. All
  public functions (`spawn_lenie`, `action`, `sterilize`, `pause`/`resume`,
  `tune`, `snapshot_stats`, `restore_tables`, `reconcile`, `lenie_died`) bake in
  the singleton name.
- **`Lenies.LenieSupervisor`** — global `DynamicSupervisor` (name = module).
- **`Lenies.Registry`** — global Registry; Lenie ids are unique globally (would
  collide cross-world without scoping).
- **`Lenies.Telemetry`** — singleton GenServer subscribed to `"world:tick"`,
  writes the global `:history` table.
- **6 ETS tables with hardcoded atom names:**
  - Owned by World (`Tables.create_all/0`): `:cells`, `:lenies`, `:child_slots`,
    `:history`, `:species_codeomes`.
  - Owned by `Application`: `:species_color_overrides`.
- **4 PubSub topics** hardcoded as bare strings: `"world:tick"`, `"world:control"`,
  `"world:fx"`, `"lenie:<id>"`.
- **Config** read globally via `Application.get_env(:lenies, …)` everywhere —
  tuning sliders today write to app env, so two worlds couldn't have different
  tuning.
- **Ticker and reconcile** are self-timers inside the `World` GenServer
  (`Process.send_after(self(), :tick, …)` / `:reconcile`). They start/stop
  with the World.
- **Snapshot** root is a single global directory; the snapshot table list
  (`@tables [:cells, :lenies, :child_slots, :history]`) is hardcoded and does
  NOT include color overrides today.

## Locked decisions (from brainstorming)

| Question | Decision |
|---|---|
| ETS isolation (roadmap open Q) | **Unnamed tables + `%WorldHandle{}` struct.** World creates ETS without `:named_table`; tids live in `state.tables` and in the handle. Eliminates atom-table pollution (critical for sandboxes that come and go). Refactor is mechanical: every `:ets.lookup(:cells, …)` → `:ets.lookup(handle.tables.cells, …)`. |
| Per-world tuning | **Yes, now (in #2).** Each World owns a `%Lenies.World.Config{}` in its state. Engine reads become `state.config.<key>`. `Worlds.tune/3` mutates the world's state. The existing `Lenies.Config` module stays for **system bounds** (codeome length bounds, opcode whitelist, snapshot root) — those remain global. |
| Species tables split | `:species_codeomes` (hash → opcodes cache, deterministic content): **global**, one ETS named table owned by `Lenies.Application`. `color_overrides` (hash → hex): **per-world** — promoted from the old global `:species_color_overrides` into a per-world unnamed table owned by World. |
| Process registry | **One global `Lenies.Registry`** with tuple keys. Per-world Registry would re-introduce atom pollution (Registry names must be atoms). Tuple keys partition cleanly. |
| PubSub | **One global `Lenies.PubSub`**; all topics scoped per world id: `"world:#{id}:tick"`, `:control`, `:fx`, `:lenie:#{lenie_id}`. |
| `world_id` type | Any Erlang term; **convention**: atoms for fixed (`:primary`, `:arena`), tuples with bounded atoms for dynamic (`{:sandbox, user_id}`). Never `String.to_atom("…#{user_id}")` — would defeat the atom-pollution avoidance. |
| Scope of #2 | **No UI change.** The dashboard talks to a fixed `:primary` world started at boot. The "N worlds isolated in one node" guarantee is proven by tests, not UI. Sandbox per-user (#3) and Arena (#4) are the real consumers of N worlds. |

## Design

### Supervision tree

```
Lenies.Supervisor (one_for_one)
├── Lenies.Repo                       (unchanged)
├── LeniesWeb.Telemetry               (unchanged)
├── DNSCluster                        (unchanged)
├── Phoenix.PubSub :Lenies.PubSub     (unchanged — global; topics scoped per world)
├── Lenies.Snippets.Store             (unchanged)
├── Lenies.Manual                     (unchanged)
├── :species_codeomes (named ETS)     NEW — created by Lenies.Application as a public
│                                       named ETS table (same pattern today's
│                                       :species_color_overrides uses). No dedicated
│                                       process; readers/writers use the atom directly.
├── Lenies.Registry                   NEW signature — same name, now used with tuple keys
│                                       (partitioned: System.schedulers_online())
├── Lenies.Worlds.Supervisor          NEW — DynamicSupervisor of per-world sub-trees
└── LeniesWeb.Endpoint                (unchanged)
```

In `Lenies.Application.start/2`, after `Supervisor.start_link` succeeds, if
`Application.get_env(:lenies, :auto_start_simulation, true)` is true, the
application starts the `:primary` world:

```elixir
Lenies.Worlds.start_world(:primary, %{})
```

**Per-world sub-tree** (started by `Lenies.Worlds.Supervisor.start_child` per
`world_id`):

```
Lenies.World.Supervisor (rest_for_one)
├── Lenies.World                  GenServer — owns the 5 unnamed ETS tables,
│                                   %Config{}, ticker, reconcile timer.
│                                   Registered via {:via, Registry, {Lenies.Registry, {:world, id}}}.
├── Lenies.World.LenieSupervisor  DynamicSupervisor (:temporary children).
│                                   Registered as {:lenie_sup, id}.
└── Lenies.World.Telemetry        GenServer subscribed to "world:#{id}:tick";
                                    writes the world's history tid.
                                    Registered as {:telemetry, id}.
```

`rest_for_one` with World first: if World crashes, its ETS tables (owned by
the World process) die with it; LenieSupervisor and Telemetry are restarted
behind it, which drops all Lenies of that world (they reference dead tids).
The world restarts fresh-and-empty (state loss on crash is acceptable; restore
from snapshot to recover).

### Public API: `Lenies.Worlds` facade + `%WorldHandle{}`

```elixir
%Lenies.WorldHandle{
  id: term(),                       # world_id
  pid: pid(),                       # World GenServer pid
  tables: %{
    cells:           :ets.tid(),
    lenies:          :ets.tid(),
    child_slots:     :ets.tid(),
    history:         :ets.tid(),
    color_overrides: :ets.tid()
  },
  pubsub_prefix: String.t()         # e.g. "world:primary", "world:sandbox-42" —
                                    # constructed at World init as
                                    # "world:" <> Lenies.Worlds.id_to_path(id)
                                    # so non-atom ids interpolate cleanly
}
```

The handle is built by World at init and made available via
`Lenies.Worlds.handle(world_id)` (one GenServer.call to read the world's
handle). Consumers (LiveViews, Lenies) cache it in their own state.

```elixir
# Facade module Lenies.Worlds:

start_world(world_id, config_overrides \\ %{}) :: {:ok, pid} | {:error, term}
stop_world(world_id)                           :: :ok | {:error, :not_found}
list()                                         :: [world_id]
handle(world_id_or_handle)                     :: {:ok, %WorldHandle{}} | :error
alive?(world_id)                               :: boolean

# Operations (accept either world_id or %WorldHandle{}):
spawn_lenie(target, codeome, opts)
action(target, action_spec)
sterilize(target)
pause(target) / resume(target) / paused?(target)
tune(target, key, value)
snapshot_stats(target)
save_snapshot(target, name)   / restore_snapshot(target, name)
reconcile(target)
```

Functions accept either a `world_id` or a `%WorldHandle{}`: id-based callers
(LiveViews) do a Registry lookup; handle-based callers (Lenies) skip the
lookup.

### Per-world state owned by World

Owned by the World GenServer (unnamed ETS):

| Table | Key | Value | Snapshotted? |
|---|---|---|---|
| `cells` | `{x, y}` | `%Cell{lenie_id, resource, carcass, …}` | yes |
| `lenies` | id | snapshot map | yes |
| `child_slots` | slot_id | gestation record | yes |
| `history` | counter | telemetry entry | yes |
| `color_overrides` | hash | `"#RRGGBB"` | **yes (new)** |

Snapshot files list grows from 4 to **5**. Legacy snapshots on disk that only
contain the original 4 tables load with `color_overrides` empty (defensive
tolerance in the restore path).

### Per-world config

```elixir
defmodule Lenies.World.Config do
  defstruct radiation_per_tick: 0.05,
            eat_amount: 100.0,
            carcass_decay: 0.01,
            lenie_metabolize_delay_ms: 0,
            tick_interval_ms: 100,
            copy_substitution_rate: 0.001,
            copy_insert_rate: 0.0005,
            copy_delete_rate: 0.0005,
            background_mutation_rate_per_1000_ticks: 0.0,
            attack_damage: 50,
            grid_width: 256,
            grid_height: 256

  @doc "Defaults read from Application env to stay compatible with config/runtime.exs."
  def defaults do
    %__MODULE__{
      radiation_per_tick: Application.get_env(:lenies, :radiation_per_tick, 0.05),
      eat_amount: Application.get_env(:lenies, :eat_amount, 100.0),
      # ...every field above, read from Application env with the struct default as fallback...
      grid_height: Application.get_env(:lenies, :grid_height, 256)
    }
  end
end
```

The 10 tunable params (the same `@tunable_params` list the dashboard exposes
today) plus 2 grid dimensions. `start_world(id, overrides)` merges overrides
with `Config.defaults/0`. Engine reads in World/Lenie change from
`Application.get_env(:lenies, :eat_amount)` → `state.config.eat_amount` (and
via `handle.config` for Lenie hot-path reads, with the handle re-fetched on
config change via a PubSub broadcast on `"world:#{id}:control"`).

System-level bounds remain in `Lenies.Config`: `codeome_length_bounds/0`,
`reconcile_interval_ms/0`, snapshot root, opcode whitelist. They are not
per-world.

### Registry strategy — one global `Lenies.Registry`, tuple keys

```elixir
{:world,        world_id}            => World GenServer pid
{:lenie_sup,    world_id}            => per-world LenieSupervisor pid
{:telemetry,    world_id}            => per-world Telemetry pid
{:lenie,        world_id, lenie_id}  => Lenie GenServer pid
```

All processes register themselves via `name: {:via, Registry, {Lenies.Registry,
key}}` in their child specs. The Registry is started with
`partitions: System.schedulers_online()` so lookups scale linearly with cores.

### PubSub topics

All topics are built from `WorldHandle.pubsub_prefix` (= `"world:" <> id_to_path(id)`):

| Topic suffix | Producer | Subscribers |
|---|---|---|
| `"#{prefix}:tick"` | World on each tick | per-world Telemetry; Dashboard LiveView |
| `"#{prefix}:control"` | World on pause/resume/sterilize/restore/tune | Lenies (their own world); Dashboard |
| `"#{prefix}:fx"` | Lenies on conjugation | Dashboard |
| `"#{prefix}:lenie:#{lenie_id}"` | Lenies on snapshot update | LenieInspector LiveView |

Subscribers do `Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:tick")`.
For the `:primary` world the topics read `"world:primary:tick"` etc.;
non-atom ids (e.g. `{:sandbox, 42}`) render as `"world:sandbox-42:tick"`.

### Lenie ↔ World wiring

```elixir
# Today
Lenies.Lenie.start_link({codeome, opts})           # implicit global World
GenServer.call(Lenies.World, {:action, spec})      # singleton call
Phoenix.PubSub.subscribe(Lenies.PubSub, "world:control")

# Sub-project #2
Lenies.Lenie.start_link({handle, codeome, opts})   # handle in init args
GenServer.call(state.world.pid, {:action, spec})   # state.world is the handle
Phoenix.PubSub.subscribe(Lenies.PubSub, "#{state.world.pubsub_prefix}:control")
```

The Lenie registers in `Lenies.Registry` under `{:lenie, world_id, lenie_id}`.
On `terminate/2` it sends `{:lenie_died, id, …}` as a cast to
`state.world.pid` (today's `Lenies.World.lenie_died/4` direct call).

### Telemetry per-world

The `Lenies.World.Telemetry` GenServer (one per world, child of the per-world
Supervisor) holds the world's handle. At init it subscribes to
`"#{prefix}:tick"`. On each tick it reads stats from `handle.tables` directly
(no GenServer round-trip), aggregates species scoped to this world's `lenies`
table (refactor `Lenies.Species.aggregate/0` → `aggregate(handle)`), and
writes to `handle.tables.history`. Worlds' Telemetry processes are completely
independent.

### Snapshot per-world

Directory layout:

```
<snapshot_root>/<id_to_path(world_id)>/<name>/
  ├── cells.tab
  ├── lenies.tab
  ├── child_slots.tab
  ├── history.tab
  └── color_overrides.tab   # NEW
```

Where `Lenies.Worlds.id_to_path/1`:

| world_id | path component |
|---|---|
| `:primary` | `"primary"` |
| `:arena` | `"arena"` |
| `{:sandbox, 42}` | `"sandbox-42"` |

API: `Worlds.save_snapshot(handle, name)`, `Worlds.restore_snapshot(handle, name)`.
The `Lenies.Snapshot` module is refactored to operate on the handle's 5 tids
instead of hardcoded atom names. Legacy snapshots missing `color_overrides.tab`
load with an empty overrides table (tolerated defensively).

## Testing strategy — the proof of #2

A new `test/lenies/worlds_test.exs` covers, at minimum:

1. **Lifecycle.** `start_world(:a)` → `handle(:a)` returns a handle →
   `stop_world(:a)` → no remaining processes (`alive?(:a) == false`), no
   leaked ETS tables.
2. **Two worlds in parallel, disjoint state.** Start `:a` and `:b`, spawn
   lenies in each; assert no key appears in both worlds' `cells`/`lenies`/
   `child_slots`; PubSub broadcasts on `"world:a:tick"` do NOT reach `:b`
   subscribers.
3. **Per-world tuning isolated.** `tune(:a, :eat_amount, 200)` vs
   `tune(:b, :eat_amount, 50)`; identical lenie in each; assert per-world
   consumption matches each world's setting.
4. **Per-world color overrides.** Same codeome hash spawned in both worlds
   with different colors → `color_overrides` tables diverge.
5. **Crash isolation.** Kill `:a`'s World; assert `:a`'s lenies all die
   (rest_for_one propagation) and `:a` restarts fresh; assert `:b` ticks
   continue, lenies alive, tables intact throughout.
6. **Snapshot per-world.** `save_snapshot(:a, "s")` → `sterilize(:a)` →
   `restore_snapshot(:a, "s")` → `:a`'s state restored; `:b` never touched.
7. **Registry tuple keys.** `{:lenie, :a, "x"}` and `{:lenie, :b, "x"}`
   (identical formal id) resolve to two distinct lenie pids.
8. **Backward compatibility.** The pre-existing dashboard/editor/inspector
   LiveView tests pass after a mechanical update of their setup to spawn
   into `world_id: :primary`.

## Out of scope (explicitly)

- No UI changes. The dashboard continues to show the `:primary` world as
  today. Sandbox per-user (#3) and Arena (#4) are separate sub-projects.
- No durable persistence of the active-world set. Worlds exist only in
  memory; the start/stop is driven by consumers (sandbox at user connect,
  arena at boot, tests at setup).
- No cross-world communication. Worlds are BEAM-isolated by construction.
- Admin role for tuning/pause/sterilize — out of the multi-user roadmap
  for now.

## Risks & migration notes

- **Highest-risk sub-project of the roadmap.** Touches the engine hot path
  (every `:ets.lookup`, every PubSub subscribe/broadcast, every
  `Application.get_env(:lenies, …)` read). The refactor is mechanical but
  pervasive — expect a long diff and the dashboard's existing LiveView tests
  needing setup tweaks.
- **`config/runtime.exs` tuning becomes a default source** rather than the
  source of truth. The `:tunable_params` whitelist in the dashboard maps
  to the `%Config{}` field set; the dashboard's `tune_param` event becomes
  `Worlds.tune(:primary, key, value)` (still affecting only the primary
  world).
- **Atom-pollution discipline.** Document the `world_id` convention in
  `Lenies.Worlds`' moduledoc and reject (or at least warn on) ids that
  would create new atoms (e.g. binaries passed where the caller probably
  meant an atom). Hard rejection is risky during dev; a `Logger.warning`
  with a clear hint is enough.
- **Snapshot format change** (4 → 5 tables) is forward-compatible: writers
  write 5; readers tolerate 4 (treat missing `color_overrides.tab` as empty).
- **`Lenies.Species.aggregate/0`** becomes `aggregate(handle)`. Confirm no
  other consumers besides Telemetry; if there are, they all need the world
  argument too.
- The change touches **`Lenies.Snapshot`**, **`Lenies.Telemetry`**,
  **`Lenies.Species`**, **`Lenies.SpeciesColor`** (now per-world via handle),
  and every LiveView (assign `world_id: :primary` and route every call
  through `Lenies.Worlds.*`). The dashboard's tests need a mechanical
  update to the new API.
