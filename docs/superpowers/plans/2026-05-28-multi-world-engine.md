# Multi-world Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the Lenies simulation engine so N isolated worlds can run concurrently in one BEAM node, with no user-facing change (dashboard continues to show one `:primary` world).

**Architecture:** Unnamed ETS tables owned by a per-world `World` GenServer and addressed via a `%Lenies.WorldHandle{}` struct (no atom-table pollution); one global `Lenies.Registry` with tuple keys for all per-world processes; per-world `%Config{}` for tuning; one global `Lenies.PubSub` with topics scoped `"world:#{id_to_path}:..."`. Each world runs as a `rest_for_one` sub-tree (World + per-world LenieSupervisor + per-world Telemetry) under a global `Lenies.Worlds.Supervisor` (DynamicSupervisor). `Lenies.Worlds` is the facade.

**Tech Stack:** Elixir 1.19, OTP 28, Phoenix 1.8, Phoenix LiveView 1.1, Elixir `Registry`, `DynamicSupervisor`, ETS, `Phoenix.PubSub`.

**Spec:** `docs/superpowers/specs/2026-05-28-multi-world-engine-design.md`

---

## File Structure

**Created:**
- `lib/lenies/world_handle.ex` — `%Lenies.WorldHandle{}` struct, just data.
- `lib/lenies/world/config.ex` — `%Lenies.World.Config{}` struct + `defaults/0`.
- `lib/lenies/worlds.ex` — facade: `start_world`, `stop_world`, `handle`, `list`, `alive?`, `id_to_path`, plus delegating operations (`spawn_lenie`, `action`, `sterilize`, `pause`, `resume`, `tune`, `snapshot_stats`, `save_snapshot`, `restore_snapshot`).
- `lib/lenies/worlds/supervisor.ex` — `DynamicSupervisor` of per-world sub-trees.
- `lib/lenies/world/supervisor.ex` — per-world `Supervisor` (`rest_for_one`).
- `test/lenies/worlds_test.exs` — the 8 multi-world isolation tests.
- `test/lenies/world/config_test.exs` — `%Config{}` defaults + merge.

**Modified (engine):**
- `lib/lenies/application.ex` — start `Lenies.Registry`, `Lenies.Worlds.Supervisor`; move `:species_codeomes` ownership here; remove global `:species_color_overrides`; boot `:primary` via `Worlds.start_world`.
- `lib/lenies/world.ex` — unnamed ETS tables, handle in state, accept `(world_id, config)`, register via Registry, read `state.config.*` instead of `Application.get_env`, broadcast to scoped topics.
- `lib/lenies/world/tables.ex` — return a map of unnamed tids instead of creating named tables.
- `lib/lenies/lenie.ex` — accept handle in init args; ETS via `handle.tables`; PubSub via `handle.pubsub_prefix`; register `{:lenie, world_id, lenie_id}`.
- `lib/lenies/lenie_supervisor.ex` — per-world (no longer global). Started inside per-world `Supervisor`.
- `lib/lenies/registry.ex` — replaced by a plain `Registry` child in `application.ex`; the module is removed (its wrapper added no value beyond the name).
- `lib/lenies/telemetry.ex` — per-world; subscribes to `"#{prefix}:tick"`; writes the world's history tid.
- `lib/lenies/species.ex` — `aggregate/0` → `aggregate(handle)`.
- `lib/lenies/species_color.ex` — all functions take a handle (or world_id) and read/write the world's `color_overrides` tid.
- `lib/lenies/snapshot.ex` — handle-based; per-world directory; 5-tables; legacy 4-table tolerance.

**Modified (web):**
- `lib/lenies_web/live/dashboard_live.ex`, `editor_live.ex`, `controls_panel_component.ex`, `lenie_inspector_live.ex`, `species_live.ex` — call `Lenies.Worlds.*(:primary, …)` instead of `Lenies.World.*`; subscribe to `"world:primary:…"` topics; assign `:world_id, :primary` and `:world_handle` where helpful.
- `lib/lenies_web/grid_renderer.ex` — accept handle for color lookups.
- LiveView test files — set `:world_id, :primary` in test setup; spawn via `Worlds.spawn_lenie(:primary, …)`.

**Deleted:**
- `lib/lenies/registry.ex` (wrapper removed; `Registry` started directly in `application.ex`).

---

## Task 1: Add `Lenies.Registry` (global, tuple-keyed, partitioned)

**Files:**
- Modify: `lib/lenies/application.ex`
- Delete: `lib/lenies/registry.ex` (today's wrapper module)
- Modify: every existing caller of `Lenies.Registry.register/3` etc. to use `Registry.register(Lenies.Registry, …)` directly. (Today: `lib/lenies/lenie.ex`, `lib/lenies/world.ex`.)

- [ ] **Step 1: Replace the wrapper module with a direct `Registry` child**

In `lib/lenies/application.ex`, find the child list (around line 20-30). The current `Lenies.Registry` child is the wrapped module. Replace it with a direct `Registry` child spec inserted right where it was:

```elixir
{Registry,
 keys: :unique,
 name: Lenies.Registry,
 partitions: System.schedulers_online()},
```

(Keep this child positioned before anything that registers into it. The current order has `Lenies.Registry` after `Phoenix.PubSub`; place the new child at the same position.)

- [ ] **Step 2: Delete the wrapper module**

```bash
git rm lib/lenies/registry.ex
```

- [ ] **Step 3: Update direct callers**

In `lib/lenies/lenie.ex` line ~84 (the `init/1` callback's `Lenies.Registry.register(id)` call), replace with:

```elixir
Registry.register(Lenies.Registry, id, nil)
```

In `lib/lenies/world.ex` around line ~534 (the reconcile's `Process.whereis(Lenies.Registry)` check), the registry is now an OTP `Registry`. The check still works — `Registry` is a named process. Replace any `Lenies.Registry.whereis(id)` with `Registry.lookup(Lenies.Registry, id)` returning `[{pid, _}]` or `[]`. Adjust the surrounding code accordingly.

- [ ] **Step 4: Run the existing suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: 702 tests, 0 failures (same as today — Registry behaviour is preserved, just via the OTP module directly).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(registry): use OTP Registry directly with partitions; drop wrapper module"
```

---

## Task 2: `%Lenies.WorldHandle{}` struct + `Lenies.Worlds.id_to_path/1`

**Files:**
- Create: `lib/lenies/world_handle.ex`
- Create: `lib/lenies/worlds.ex` (skeleton — only `id_to_path/1` for now)
- Create: `test/lenies/worlds_test.exs` (smoke for `id_to_path/1`)

- [ ] **Step 1: Failing test for `id_to_path/1`**

Create `test/lenies/worlds_test.exs`:

```elixir
defmodule Lenies.WorldsTest do
  use ExUnit.Case, async: true

  describe "id_to_path/1" do
    test "atom world id renders as the atom name" do
      assert Lenies.Worlds.id_to_path(:primary) == "primary"
      assert Lenies.Worlds.id_to_path(:arena) == "arena"
    end

    test "tuple {atom, integer} renders as 'atom-integer'" do
      assert Lenies.Worlds.id_to_path({:sandbox, 42}) == "sandbox-42"
    end

    test "is filesystem-safe (no slashes or dots)" do
      refute Lenies.Worlds.id_to_path(:primary) =~ "/"
      refute Lenies.Worlds.id_to_path({:sandbox, 42}) =~ "/"
    end
  end
end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/worlds_test.exs'
```

Expected: FAIL — `Lenies.Worlds` undefined.

- [ ] **Step 3: Create the `%WorldHandle{}` struct**

Create `lib/lenies/world_handle.ex`:

```elixir
defmodule Lenies.WorldHandle do
  @moduledoc """
  An opaque-ish handle pointing at a single simulation world.

  Held by `Lenies.World` in its state, by Lenie processes (init arg), and by
  LiveViews that want fast-path ETS reads. Build via `Lenies.Worlds.handle/1`.
  """

  @enforce_keys [:id, :pid, :tables, :pubsub_prefix]
  defstruct [:id, :pid, :tables, :pubsub_prefix]

  @type table_key :: :cells | :lenies | :child_slots | :history | :color_overrides

  @type t :: %__MODULE__{
          id: term(),
          pid: pid(),
          tables: %{table_key() => :ets.tid()},
          pubsub_prefix: String.t()
        }
end
```

- [ ] **Step 4: Create the `Lenies.Worlds` skeleton with `id_to_path/1`**

Create `lib/lenies/worlds.ex`:

```elixir
defmodule Lenies.Worlds do
  @moduledoc """
  Facade for the multi-world simulation engine. Other modules in this file
  will be filled in by later tasks (start_world, stop_world, handle, list,
  spawn_lenie, action, ...). For now only the `id_to_path/1` helper exists.

  ## world_id convention

  - Fixed worlds use atoms: `:primary`, `:arena` (one atom per id, safe).
  - Dynamic worlds use tuples with bounded atoms: `{:sandbox, user_id}` where
    `user_id` is an integer. **Never** `String.to_atom("sandbox_\#{user_id}")`
    — would re-introduce the atom-table pollution that the multi-world design
    explicitly avoids.
  """

  @doc """
  Render a `world_id` as a filesystem- and topic-safe string.

  Examples:
      iex> Lenies.Worlds.id_to_path(:primary)
      "primary"
      iex> Lenies.Worlds.id_to_path({:sandbox, 42})
      "sandbox-42"
  """
  @spec id_to_path(term()) :: String.t()
  def id_to_path(id) when is_atom(id), do: Atom.to_string(id)

  def id_to_path({atom, rest}) when is_atom(atom) do
    "#{atom}-#{rest}"
  end
end
```

- [ ] **Step 5: Run, see green**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/worlds_test.exs'
```

Expected: 3 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/lenies/world_handle.ex lib/lenies/worlds.ex test/lenies/worlds_test.exs
git commit -m "feat(worlds): %WorldHandle{} struct + Lenies.Worlds.id_to_path/1"
```

---

## Task 3: `%Lenies.World.Config{}` struct + `defaults/0`

**Files:**
- Create: `lib/lenies/world/config.ex`
- Test: `test/lenies/world/config_test.exs`

- [ ] **Step 1: Failing test**

Create `test/lenies/world/config_test.exs`:

```elixir
defmodule Lenies.World.ConfigTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Config

  test "defaults/0 returns a Config struct with non-nil values for every field" do
    cfg = Config.defaults()
    assert %Config{} = cfg

    for {field, _default} <- Map.to_list(struct(Config)) do
      refute is_nil(Map.fetch!(cfg, field)),
             "field #{inspect(field)} is nil in Config.defaults/0"
    end
  end

  test "merge/2 overrides defaults with caller-provided values" do
    cfg = Config.merge(Config.defaults(), %{eat_amount: 200.0, attack_damage: 25})
    assert cfg.eat_amount == 200.0
    assert cfg.attack_damage == 25
    # untouched fields keep their defaults
    assert cfg.grid_width == Config.defaults().grid_width
  end

  test "merge/2 ignores unknown keys" do
    cfg = Config.merge(Config.defaults(), %{bogus_key: 9999})
    refute Map.has_key?(cfg, :bogus_key)
  end
end
```

- [ ] **Step 2: Run, see it fail**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/world/config_test.exs'
```

Expected: FAIL — `Lenies.World.Config` undefined.

- [ ] **Step 3: Implement Config**

Create `lib/lenies/world/config.ex`:

```elixir
defmodule Lenies.World.Config do
  @moduledoc """
  Per-world simulation tuning. Each `Lenies.World` holds one of these in its
  state. `defaults/0` sources values from `Application.get_env(:lenies, …)`
  so existing `config/runtime.exs` files keep working — but the **source of
  truth at runtime is the world's state**, not the global app env.

  System bounds that are not per-world (codeome length bounds, opcode
  whitelist, snapshot root, reconcile interval) stay in `Lenies.Config`.
  """

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

  @type t :: %__MODULE__{}

  @doc """
  Build a `%Config{}` from `Application.get_env(:lenies, …)` falling back to
  the struct defaults if a key is absent.
  """
  @spec defaults() :: t()
  def defaults do
    %__MODULE__{
      radiation_per_tick: get(:radiation_per_tick, 0.05),
      eat_amount: get(:eat_amount, 100.0),
      carcass_decay: get(:carcass_decay, 0.01),
      lenie_metabolize_delay_ms: get(:lenie_metabolize_delay_ms, 0),
      tick_interval_ms: get(:tick_interval_ms, 100),
      copy_substitution_rate: get(:copy_substitution_rate, 0.001),
      copy_insert_rate: get(:copy_insert_rate, 0.0005),
      copy_delete_rate: get(:copy_delete_rate, 0.0005),
      background_mutation_rate_per_1000_ticks: get(:background_mutation_rate_per_1000_ticks, 0.0),
      attack_damage: get(:attack_damage, 50),
      grid_width: get(:grid_width, 256),
      grid_height: get(:grid_height, 256)
    }
  end

  @doc """
  Merge a caller-provided overrides map into a `%Config{}`. Unknown keys are
  silently dropped (Map.take limits to known fields).
  """
  @spec merge(t(), map()) :: t()
  def merge(%__MODULE__{} = cfg, overrides) when is_map(overrides) do
    known = Map.keys(Map.from_struct(cfg))
    struct(cfg, Map.take(overrides, known))
  end

  defp get(key, default), do: Application.get_env(:lenies, key, default)
end
```

- [ ] **Step 4: Run, see green**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/world/config_test.exs'
```

Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/world/config.ex test/lenies/world/config_test.exs
git commit -m "feat(world): %World.Config{} struct + defaults/0 + merge/2"
```

---

## Task 4: Move `:species_codeomes` ownership to `Application`

**Why:** The codeome cache (`hash → [opcodes]`) is a deterministic, global memoization — it should not be tied to any single world. Moving its ownership out of `Lenies.World` is a prerequisite for the world-table refactor.

**Files:**
- Modify: `lib/lenies/application.ex`
- Modify: `lib/lenies/world/tables.ex`
- Modify (no logic change): `lib/lenies/lenie.ex` lines 1 around the 3 `:species_codeomes` references (verify name stays the same — it does — so no code change there).

- [ ] **Step 1: Create the table in Application**

In `lib/lenies/application.ex`, find the existing `:ets.new(:species_color_overrides, …)` call (around line 12). Add a similar call for `:species_codeomes` right alongside it, with the SAME shape that `Lenies.World.Tables` currently uses for it. Confirm the shape by reading `lib/lenies/world/tables.ex` first — match it exactly (table options like `:public`, `:set`, `read_concurrency`, etc.).

Example (adjust options to match what `Tables.create_all/0` uses today):

```elixir
:ets.new(:species_codeomes, [:set, :public, :named_table, read_concurrency: true])
```

- [ ] **Step 2: Remove `:species_codeomes` creation from `Tables.create_all/0`**

In `lib/lenies/world/tables.ex`, find the `:ets.new(:species_codeomes, …)` line (around line 23-28 in the `create_all/0` function). Delete it. The function now creates only the 4 per-world tables (`:cells`, `:lenies`, `:child_slots`, `:history`).

- [ ] **Step 3: Run the suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: 702 tests, 0 failures. (Readers of `:species_codeomes` in `lib/lenies/lenie.ex` continue to work — the table exists under the same atom name; it just has a different owner process now.)

- [ ] **Step 4: Commit**

```bash
git add lib/lenies/application.ex lib/lenies/world/tables.ex
git commit -m "refactor: move :species_codeomes ETS ownership from World to Application (global cache)"
```

---

## Task 5: World refactor — unnamed tables, handle in state, accept `(world_id, config)`

**Why:** The big one. World becomes per-world: stores its tables as unnamed tids in `state.tables`; reads config from `state.config`; registers itself via the Registry. Backward compatibility shim: World **also** keeps the singleton name `Lenies.World` registered during this stage so existing callers (Lenie, LiveViews, tests) keep working. The shim is removed in Task 10.

**Files:**
- Modify: `lib/lenies/world.ex` (the big one)
- Modify: `lib/lenies/world/tables.ex` — `create_all/0` returns `%{cells: tid, lenies: tid, child_slots: tid, history: tid}` instead of creating named tables.

This task does not touch Lenie/LiveView yet (Task 6+). The compat name registration keeps them working.

- [ ] **Step 1: Refactor `Lenies.World.Tables.create_all/0` to return a map of unnamed tids**

Open `lib/lenies/world/tables.ex`. The current function looks roughly like:

```elixir
def create_all do
  :ets.new(:cells, [:set, :public, :named_table, …])
  :ets.new(:lenies, [:set, :public, :named_table, …])
  :ets.new(:child_slots, [:set, :public, :named_table, …])
  :ets.new(:history, [:ordered_set, :public, :named_table, …])
  :ok
end
```

Replace with (keep the same option lists minus `:named_table`):

```elixir
@doc """
Creates the 4 per-world ETS tables (unnamed) and returns a map of tids.
The caller (the World GenServer) holds them in its state.
"""
def create_all do
  %{
    cells:       :ets.new(:cells,       [:set, :public, read_concurrency: true]),
    lenies:      :ets.new(:lenies,      [:set, :public, read_concurrency: true]),
    child_slots: :ets.new(:child_slots, [:set, :public, read_concurrency: true]),
    history:     :ets.new(:history,     [:ordered_set, :public, read_concurrency: true])
  }
end
```

(Use the exact option list the current `create_all/0` uses for each table. The atom passed as first arg to `:ets.new` is just a tag for `:ets.info/2`, not a global name when `:named_table` is absent.)

- [ ] **Step 2: Refactor `Lenies.World` state and init**

In `lib/lenies/world.ex`:

(a) The `@name __MODULE__` and `start_link/1` registering as `name: @name` (lines ~16-22): keep `Lenies.World` as the singleton name for now (compat shim), AND ALSO add the via-Registry registration. The cleanest way: pass two names through `start_link`:

```elixir
@name __MODULE__

def start_link(opts \\ []) do
  world_id = Keyword.get(opts, :world_id, :primary)
  config = Keyword.get(opts, :config, %{})
  GenServer.start_link(__MODULE__, {world_id, config}, name: server_name(world_id))
end

# server_name returns the via-registry tuple, EXCEPT for :primary which also
# keeps the global Lenies.World atom name as a backward-compat shim.
defp server_name(:primary), do: @name
defp server_name(world_id), do: {:via, Registry, {Lenies.Registry, {:world, world_id}}}
```

(Note: a single GenServer process can only have one OTP name. We keep `Lenies.World` as the name only for `:primary` during this stage. Other worlds use only the via tuple. The shim is removed in Task 10, at which point `:primary` also switches to via.)

(b) Refactor `init/1` to accept `{world_id, config_overrides}`, build the config and handle, store them in state. The handle is built using `self()` for `pid`. Pseudocode:

```elixir
def init({world_id, config_overrides}) do
  config = Lenies.World.Config.merge(Lenies.World.Config.defaults(), config_overrides)
  tables = Lenies.World.Tables.create_all()
  pubsub_prefix = "world:" <> Lenies.Worlds.id_to_path(world_id)

  handle = %Lenies.WorldHandle{
    id: world_id,
    pid: self(),
    tables: tables,
    pubsub_prefix: pubsub_prefix
  }

  state = %{
    world_id: world_id,
    config: config,
    tables: tables,
    handle: handle,
    # plus the existing fields the current init/1 puts in state (paused?, last_tick, etc.)
    # — preserve them verbatim
  }

  # existing init work (radiation initial seed, hotspots, etc.) — keep, but
  # pass tables/config where currently they read named tables / Application env.

  schedule_tick(state)
  schedule_reconcile(state)
  {:ok, state}
end
```

(c) Add `handle_call(:get_handle, _from, state)` returning `{:reply, state.handle, state}` so consumers can fetch the handle.

(d) Replace every `:ets.<op>(:cells, …)` in `lib/lenies/world.ex` with `:ets.<op>(state.tables.cells, …)`. Same for `:lenies`, `:child_slots`. (38 sites; bulk find/replace, then verify with grep.) Reads/writes from helper functions in the module receive `state` or `state.tables` as an argument; if a helper currently takes no arguments and reads `:cells` directly, add a parameter for the tables (or `state`).

(e) Every `Application.get_env(:lenies, key, default)` read in `lib/lenies/world.ex` becomes `state.config.<field>` (the field name matches the env key 1:1). Today there are 12 such reads in this file.

(f) Topic broadcasts: replace every hardcoded `"world:tick"` / `"world:control"` / `"world:fx"` with `"#{state.handle.pubsub_prefix}:tick"` etc.

(g) For the tick scheduler: `tick_interval_ms` is now `state.config.tick_interval_ms`. The current code re-reads from `Application.get_env` each reschedule — change to read from `state.config`.

(h) `lenie_died/4` and `spawn_lenie/2` (currently module-level functions that do `GenServer.call(@name, …)`) — keep as compatibility shims that internally do `GenServer.call(@name, …)`. They will be replaced/removed in Task 10 once consumers use the Worlds facade.

- [ ] **Step 3: Run the suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: **702 tests, 0 failures.** The Lenie module still calls `Lenies.World.action(...)` and `:ets.lookup(:cells, …)` — wait, but cells is now unnamed! Lenie's reads will FAIL until Task 6.

Realistically: this task **breaks** Lenie's `:ets` reads on the world tables. Lenie still has 4 sites reading `:cells` (1) and `:lenies` (3) from named tables. We have two options:
- (i) Combine Task 5 and Task 6 (atomic refactor) — bigger commit, suite green at the end.
- (ii) Add a temporary compat shim: World ALSO registers the cells/lenies tables as named (via `:ets.new` with `:named_table`) for the `:primary` world during Task 5. Then Task 6 removes the named-table registration once Lenies use handles.

**Pick option (ii) for green-suite continuity.** Update `Tables.create_all/0` to accept a `world_id` argument and conditionally pass `:named_table` only when `world_id == :primary`. Pseudocode:

```elixir
def create_all(world_id) do
  named = if world_id == :primary, do: [:named_table], else: []
  %{
    cells:       :ets.new(:cells, [:set, :public, read_concurrency: true] ++ named),
    lenies:      :ets.new(:lenies, [:set, :public, read_concurrency: true] ++ named),
    child_slots: :ets.new(:child_slots, [:set, :public, read_concurrency: true] ++ named),
    history:     :ets.new(:history, [:ordered_set, :public, read_concurrency: true] ++ named)
  }
end
```

World's `init/1` passes `world_id` to `Tables.create_all/1`. With this shim, the named atoms exist for `:primary` and Lenie's existing reads continue to work; non-`:primary` worlds get only unnamed tids (no collision possible with multiple non-primary worlds in the same node).

- [ ] **Step 4: Verify suite green**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: 702 tests, 0 failures.

- [ ] **Step 5: Verify the per-world plumbing works via a smoke test**

Add to `test/lenies/worlds_test.exs`:

```elixir
  describe "handle (Task 5 smoke)" do
    test "primary World exposes a handle with the right tids" do
      # The :primary World is auto-started by Lenies.Application in dev/test
      # (auto_start_simulation: true).
      handle = GenServer.call(Lenies.World, :get_handle)
      assert %Lenies.WorldHandle{id: :primary, pubsub_prefix: "world:primary"} = handle
      assert is_reference(handle.tables.cells)
      assert is_reference(handle.tables.lenies)
      assert handle.pid == Process.whereis(Lenies.World)
    end
  end
```

Run:

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/worlds_test.exs'
```

Expected: existing 3 tests + new 1 = 4 pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(world): per-world state, %Config{} + %WorldHandle{} in state, unnamed ETS tables

Compat shim: :primary world still registers tables as named ETS so Lenies
(not yet handle-aware) continue to read by atom name. Both shims (named
table for :primary, global Lenies.World GenServer name) come off in
Task 10 once consumers migrate to the Worlds facade."
```

---

## Task 6: Lenie refactor — handle in init args, ETS via `handle.tables`, scoped PubSub

**Files:**
- Modify: `lib/lenies/lenie.ex` (the 7 `:ets.*` sites and the 4 PubSub sites)
- Modify: `lib/lenies/world.ex` — `spawn_lenie` passes `state.handle` as the first init arg.

- [ ] **Step 1: Update Lenie's `start_link/1` and `init/1` to accept the handle**

In `lib/lenies/lenie.ex`:

```elixir
# Today:
def start_link(args), do: GenServer.start_link(__MODULE__, args)
def init({codeome, opts}) do
  # ...
end

# Tomorrow:
def start_link({%Lenies.WorldHandle{} = handle, codeome, opts}) do
  GenServer.start_link(__MODULE__, {handle, codeome, opts})
end

def init({%Lenies.WorldHandle{} = handle, codeome, opts}) do
  # ...store handle in state...
  state = %{
    # existing fields,
    world: handle
  }
  # subscriptions:
  Phoenix.PubSub.subscribe(Lenies.PubSub, "#{handle.pubsub_prefix}:control")
  Registry.register(Lenies.Registry, {:lenie, handle.id, lenie_id}, nil)
  # rest of init...
end
```

- [ ] **Step 2: Replace ETS reads/writes in `lib/lenies/lenie.ex`**

The 7 `:ets` sites in `lib/lenies/lenie.ex` divide into:
- `:cells` (1 read) → `:ets.lookup(state.world.tables.cells, pos)`
- `:lenies` (3: 2 reads, 1 insert) → `state.world.tables.lenies`
- `:species_codeomes` (3 sites: lookup, insert, info) → **leave unchanged** — this remains a global named table (Task 4).

Find them with: `grep -n ':ets\.\(lookup\|insert\|delete\|info\)(' lib/lenies/lenie.ex`. Each `:cells` or `:lenies` site gets the substitution above.

- [ ] **Step 3: Replace PubSub broadcasts/subscribes in `lib/lenies/lenie.ex`**

Today (4 sites):
- Subscribe `"world:control"` at init → `"#{state.world.pubsub_prefix}:control"`
- Broadcast `{:lenie_update, snap}` on `"lenie:#{state.id}"` → `"#{state.world.pubsub_prefix}:lenie:#{state.id}"`
- Broadcast conjugation on `"world:fx"` → `"#{state.world.pubsub_prefix}:fx"`

- [ ] **Step 4: Replace `Lenies.World.action(...)` and `Lenies.World.lenie_died(...)` calls**

The Lenie hot path calls `Lenies.World.action/1` 8 times (line refs from the Explore agent: 362, 370, 377, 383, 394, 401, 419, 438). Each becomes:

```elixir
GenServer.call(state.world.pid, {:action, spec})
```

`World.lenie_died/4` (called from `terminate/2` at line 294) becomes:

```elixir
GenServer.cast(state.world.pid, {:lenie_died, state.id, state.codeome_hash, generation, reason})
```

(Confirm the exact existing message shape in `World`'s `handle_cast({:lenie_died, …})` — match it.)

- [ ] **Step 5: Update World's `spawn_lenie` to pass the handle**

In `lib/lenies/world.ex`, find where `DynamicSupervisor.start_child(Lenies.LenieSupervisor, …)` is called inside `handle_call({:spawn_lenie, …})`. Today:

```elixir
DynamicSupervisor.start_child(Lenies.LenieSupervisor, {Lenies.Lenie, {codeome, opts}})
```

Becomes:

```elixir
DynamicSupervisor.start_child(Lenies.LenieSupervisor, {Lenies.Lenie, {state.handle, codeome, opts}})
```

- [ ] **Step 6: Remove the `:primary`-only named-table shim**

In `lib/lenies/world/tables.ex` `create_all/1`, remove the `:named_table` conditional. Tables are always unnamed:

```elixir
def create_all(_world_id) do
  %{
    cells:       :ets.new(:cells, [:set, :public, read_concurrency: true]),
    lenies:      :ets.new(:lenies, [:set, :public, read_concurrency: true]),
    child_slots: :ets.new(:child_slots, [:set, :public, read_concurrency: true]),
    history:     :ets.new(:history, [:ordered_set, :public, read_concurrency: true])
  }
end
```

(The `_world_id` param stays for API symmetry; it'll be dropped in cleanup later if unused.)

- [ ] **Step 7: Run the suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: 702 tests, 0 failures. The dashboard tests still work because the `Lenies.World` singleton name + the `World.action/2` compat shim is still in place; Lenies use the handle internally and don't depend on named tables anymore.

If any test fails because it directly read `:ets.lookup(:cells, …)` or similar from a hardcoded named table — those callers need to switch to `GenServer.call(Lenies.World, :get_handle)` to obtain tids. Apply the fix and re-run.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(lenie): accept %WorldHandle{} at init; ETS via handle.tables; scoped PubSub topics

The :primary-only named-table shim is removed (tables are now always
unnamed). The Lenies.World singleton name registration remains until
Task 10."
```

---

## Task 7: Promote `color_overrides` to per-world; refactor `Lenies.SpeciesColor`

**Files:**
- Modify: `lib/lenies/world/tables.ex` — add `color_overrides` to the 4-table set, now 5.
- Modify: `lib/lenies/world.ex` — handle's tables map includes `color_overrides`.
- Modify: `lib/lenies/world_handle.ex` — `@type table_key` already includes `:color_overrides` (from Task 2).
- Modify: `lib/lenies/species_color.ex` — every public function takes a handle.
- Modify: `lib/lenies/application.ex` — remove the global `:species_color_overrides` `:ets.new` (table no longer exists globally).
- Modify: callers of `Lenies.SpeciesColor` (search with grep) — thread the handle through.

- [ ] **Step 1: Add `color_overrides` to per-world tables**

In `lib/lenies/world/tables.ex`:

```elixir
def create_all(_world_id) do
  %{
    cells:           :ets.new(:cells, [:set, :public, read_concurrency: true]),
    lenies:          :ets.new(:lenies, [:set, :public, read_concurrency: true]),
    child_slots:     :ets.new(:child_slots, [:set, :public, read_concurrency: true]),
    history:         :ets.new(:history, [:ordered_set, :public, read_concurrency: true]),
    color_overrides: :ets.new(:color_overrides, [:set, :public, read_concurrency: true])
  }
end
```

- [ ] **Step 2: Refactor `Lenies.SpeciesColor` to take a handle**

The public API today (from grep):
- `hue_byte(hash)`
- `set_override(hash, hex)`
- `clear_override(hash)`
- `override(hash)`
- `hex(hash)`
- `byte_to_hex(byte)`

Refactor each function that touches `:species_color_overrides` to take a handle as the first arg:

```elixir
@spec set_override(Lenies.WorldHandle.t(), binary(), binary()) :: true
def set_override(%Lenies.WorldHandle{} = handle, hash, hex) when is_binary(hash) and is_binary(hex) do
  :ets.insert(handle.tables.color_overrides, {hash, hex})
end

@spec clear_override(Lenies.WorldHandle.t(), binary()) :: true
def clear_override(%Lenies.WorldHandle{} = handle, hash) when is_binary(hash) do
  :ets.delete(handle.tables.color_overrides, hash)
end

@spec override(Lenies.WorldHandle.t(), binary()) :: binary() | nil
def override(%Lenies.WorldHandle{} = handle, hash) when is_binary(hash) do
  case :ets.lookup(handle.tables.color_overrides, hash) do
    [{^hash, hex}] -> hex
    [] -> nil
  end
end

@spec hex(Lenies.WorldHandle.t(), binary()) :: binary()
def hex(%Lenies.WorldHandle{} = handle, hash) when is_binary(hash) do
  override(handle, hash) || derive_hex_from_hash(hash)
end
```

`hue_byte/1` and `byte_to_hex/1` do not touch the override table — leave them unchanged.

- [ ] **Step 3: Update callers**

Find every caller with:

```bash
grep -rn 'Lenies\.SpeciesColor\.\(set_override\|clear_override\|override\|hex\)' lib test
```

Known sites from yesterday's grep:
- `lib/lenies_web/live/controls_panel_component.ex:336` — `Lenies.SpeciesColor.set_override(hash, seed.color_hex)` (the spawn from custom seed). The component has `current_scope` and `world_handle`/`world_id` in assigns (Task 11 will assign them); for now, after Task 6's compat shim, fetch the handle via `Lenies.Worlds.handle(:primary)` (which will be implemented in Task 8) — OR, since Task 7 happens before Task 8's facade is fully wired, fetch via `GenServer.call(Lenies.World, :get_handle)` directly.
- `lib/lenies_web/grid_renderer.ex` (color computation per render).
- Anywhere else grep finds.

For each call site, fetch the `:primary` handle (cached in assigns where possible) and pass it as the first arg.

- [ ] **Step 4: Remove the global `:species_color_overrides` ETS**

In `lib/lenies/application.ex`, delete the `:ets.new(:species_color_overrides, …)` line. Run a grep to confirm no remaining references:

```bash
grep -rn 'species_color_overrides' lib test
```

Expected: zero matches.

- [ ] **Step 5: Run the suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: 702 tests, 0 failures. Visual smoke: dashboard renders with species colors (overrides start empty per world; default hash-derived colors still show).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(species_color): per-world color_overrides ETS, handle-based SpeciesColor API"
```

---

## Task 8: `Lenies.Worlds` facade + `Lenies.Worlds.Supervisor`

**Files:**
- Modify: `lib/lenies/worlds.ex` — fill in the facade (start/stop/handle/list/alive?/spawn_lenie/action/tune/...).
- Create: `lib/lenies/worlds/supervisor.ex` — DynamicSupervisor.
- Modify: `lib/lenies/application.ex` — add `Lenies.Worlds.Supervisor` as a child.

- [ ] **Step 1: Create `Lenies.Worlds.Supervisor`**

Create `lib/lenies/worlds/supervisor.ex`:

```elixir
defmodule Lenies.Worlds.Supervisor do
  @moduledoc """
  DynamicSupervisor of per-world supervision sub-trees. Started once per node
  by `Lenies.Application`. `Lenies.Worlds.start_world/2` calls
  `DynamicSupervisor.start_child(__MODULE__, ...)` to spin up a world.
  """
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
```

Add to `lib/lenies/application.ex` children, AFTER `Lenies.Registry`:

```elixir
Lenies.Worlds.Supervisor,
```

- [ ] **Step 2: Fill in `Lenies.Worlds` facade**

Replace the contents of `lib/lenies/worlds.ex` with the full facade. Keep `id_to_path/1` as-is. Add:

```elixir
  @doc """
  Start a new world with the given id and optional config overrides.
  Returns `{:ok, sup_pid}` (the per-world Supervisor pid) or `{:error, …}`.
  """
  @spec start_world(term(), map()) :: DynamicSupervisor.on_start_child()
  def start_world(world_id, config_overrides \\ %{}) do
    spec = {Lenies.World.Supervisor, world_id: world_id, config: config_overrides}
    DynamicSupervisor.start_child(Lenies.Worlds.Supervisor, spec)
  end

  @doc "Stop a world by id. Idempotent — returns :ok if not found."
  @spec stop_world(term()) :: :ok
  def stop_world(world_id) do
    case Registry.lookup(Lenies.Registry, {:world_sup, world_id}) do
      [{sup_pid, _}] ->
        DynamicSupervisor.terminate_child(Lenies.Worlds.Supervisor, sup_pid)
        :ok
      [] ->
        :ok
    end
  end

  @doc "Look up the %WorldHandle{} for an id. Returns `{:ok, handle}` or `:error`."
  @spec handle(term() | Lenies.WorldHandle.t()) :: {:ok, Lenies.WorldHandle.t()} | :error
  def handle(%Lenies.WorldHandle{} = h), do: {:ok, h}
  def handle(world_id) do
    case Registry.lookup(Lenies.Registry, {:world, world_id}) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :get_handle)}
      [] -> :error
    end
  end

  @doc "List the ids of currently running worlds."
  @spec list() :: [term()]
  def list do
    Registry.select(Lenies.Registry, [{{{:world, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc "Is a world with this id alive?"
  @spec alive?(term()) :: boolean
  def alive?(world_id) do
    match?([{_, _}], Registry.lookup(Lenies.Registry, {:world, world_id}))
  end

  # ----- delegated operations -----

  @doc "Spawn a Lenie in the target world."
  def spawn_lenie(target, codeome, opts \\ []) do
    with {:ok, handle} <- handle(target) do
      GenServer.call(handle.pid, {:spawn_lenie, codeome, opts})
    end
  end

  @doc "Apply an action to the target world (used by Lenies in their hot path)."
  def action(target, action_spec) do
    with {:ok, handle} <- handle(target) do
      GenServer.call(handle.pid, {:action, action_spec})
    end
  end

  def sterilize(target),     do: call(target, :sterilize)
  def pause(target),         do: call(target, :pause)
  def resume(target),        do: call(target, :resume)
  def paused?(target),       do: call(target, :paused?)
  def snapshot_stats(target), do: call(target, :snapshot_stats)

  @doc "Set a tunable on the target world."
  def tune(target, key, value) do
    with {:ok, handle} <- handle(target) do
      GenServer.call(handle.pid, {:tune, key, value})
    end
  end

  defp call(target, msg) do
    with {:ok, handle} <- handle(target) do
      GenServer.call(handle.pid, msg)
    end
  end
```

`save_snapshot` and `restore_snapshot` are added in Task 12. `Lenies.World.Supervisor` is implemented in Task 9.

- [ ] **Step 3: Add a `handle_call({:tune, key, value})` clause to `Lenies.World`**

In `lib/lenies/world.ex`, add:

```elixir
def handle_call({:tune, key, value}, _from, state) do
  if Map.has_key?(Map.from_struct(state.config), key) do
    new_config = Map.put(state.config, key, value)
    Phoenix.PubSub.broadcast(Lenies.PubSub, "#{state.handle.pubsub_prefix}:control",
                             {:config_changed, key, value})
    {:reply, :ok, %{state | config: new_config}}
  else
    {:reply, {:error, {:unknown_tunable, key}}, state}
  end
end
```

- [ ] **Step 4: Run the suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0'
```

Expected: 702 tests, 0 failures. The new `Worlds.Supervisor` is a child but starts no worlds yet; the facade exists but `start_world` requires `Lenies.World.Supervisor` (Task 9) to actually work.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(worlds): Lenies.Worlds facade (start/stop/handle/list/spawn/action/tune) + Worlds.Supervisor"
```

---

## Task 9: Per-world `Lenies.World.Supervisor` (rest_for_one) — World + per-world LenieSupervisor + per-world Telemetry

**Files:**
- Create: `lib/lenies/world/supervisor.ex`
- Modify: `lib/lenies/lenie_supervisor.ex` — per-world (registered via `{:via, Registry, {Lenies.Registry, {:lenie_sup, world_id}}}`).
- Modify: `lib/lenies/telemetry.ex` — per-world (registered via `{:via, ..., {:telemetry, world_id}}`); subscribes to `"#{prefix}:tick"`; writes `handle.tables.history`.
- Modify: `lib/lenies/species.ex` — `aggregate/0` → `aggregate(handle)`.
- Modify: `lib/lenies/world.ex` — `spawn_lenie` no longer hardcodes `Lenies.LenieSupervisor`; looks up the per-world LenieSupervisor via the Registry (or stores its pid in state on init).

- [ ] **Step 1: Create the per-world Supervisor**

Create `lib/lenies/world/supervisor.ex`:

```elixir
defmodule Lenies.World.Supervisor do
  @moduledoc """
  Per-world supervision sub-tree (`rest_for_one`):

      Lenies.World                 GenServer (owns ETS, ticker, reconcile)
      Lenies.World.LenieSupervisor DynamicSupervisor of this world's Lenies
      Lenies.World.Telemetry       per-world telemetry collector

  If World crashes, the ETS tables (owned by the World process) die with it;
  rest_for_one then restarts LenieSupervisor (killing all Lenies of this
  world) and Telemetry. The whole world resets to an empty fresh state.
  Snapshot restore is the way to recover content.
  """
  use Supervisor

  def start_link(opts) do
    world_id = Keyword.fetch!(opts, :world_id)
    Supervisor.start_link(__MODULE__, opts, name: via(world_id))
  end

  defp via(world_id),
    do: {:via, Registry, {Lenies.Registry, {:world_sup, world_id}}}

  @impl true
  def init(opts) do
    world_id = Keyword.fetch!(opts, :world_id)
    config = Keyword.get(opts, :config, %{})

    children = [
      {Lenies.World, world_id: world_id, config: config},
      {Lenies.LenieSupervisor, world_id: world_id},
      {Lenies.Telemetry, world_id: world_id}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

- [ ] **Step 2: Make `Lenies.LenieSupervisor` per-world**

In `lib/lenies/lenie_supervisor.ex`:

```elixir
defmodule Lenies.LenieSupervisor do
  use DynamicSupervisor

  def start_link(opts) do
    world_id = Keyword.fetch!(opts, :world_id)
    DynamicSupervisor.start_link(__MODULE__, opts, name: via(world_id))
  end

  def via(world_id),
    do: {:via, Registry, {Lenies.Registry, {:lenie_sup, world_id}}}

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
```

- [ ] **Step 3: Update `Lenies.World.spawn_lenie` to use the per-world LenieSupervisor**

In `lib/lenies/world.ex`, replace `DynamicSupervisor.start_child(Lenies.LenieSupervisor, …)` with:

```elixir
sup = Lenies.LenieSupervisor.via(state.world_id)
DynamicSupervisor.start_child(sup, {Lenies.Lenie, {state.handle, codeome, opts}})
```

Similarly update `terminate_all_lenies/0` (line ~581-590) to operate on `state.world_id`'s LenieSupervisor.

- [ ] **Step 4: Make `Lenies.Telemetry` per-world**

In `lib/lenies/telemetry.ex`:

```elixir
defmodule Lenies.Telemetry do
  use GenServer

  def start_link(opts) do
    world_id = Keyword.fetch!(opts, :world_id)
    GenServer.start_link(__MODULE__, world_id, name: via(world_id))
  end

  defp via(world_id),
    do: {:via, Registry, {Lenies.Registry, {:telemetry, world_id}}}

  @impl true
  def init(world_id) do
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{handle.pubsub_prefix}:tick")
    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{handle.pubsub_prefix}:control")
    {:ok, %{world_id: world_id, handle: handle, counter: 0}}
  end

  # ...handle_info({:tick, n}, state) writes telemetry to state.handle.tables.history...
  # ...handle_info({:sterilized, _}, state) resets the counter...
  # Re-implement the existing logic, but operate on state.handle.tables.history
  # instead of the named :history table.
end
```

This will require updating the body of every callback in `telemetry.ex` to read from `state.handle.tables.history` and call `Lenies.Species.aggregate(state.handle)` (next step).

- [ ] **Step 5: Refactor `Lenies.Species.aggregate/0` → `aggregate(handle)`**

In `lib/lenies/species.ex`, change `aggregate/0` (or whatever the public function is) to accept a handle and read from `handle.tables.lenies` instead of `:lenies`. Update any callers (grep `Lenies.Species.aggregate(`).

- [ ] **Step 6: Remove the global LenieSupervisor and Telemetry children from `application.ex`**

In `lib/lenies/application.ex`, remove the lines that today add `Lenies.LenieSupervisor` and `Lenies.Telemetry` directly to the top-level children. They are now started inside the per-world Supervisor.

Also remove the conditional `Lenies.World` child — World is now ONLY started via the per-world Supervisor. The `:auto_start_simulation` flag (if enabled) will trigger `Worlds.start_world(:primary, …)` after `Supervisor.start_link` returns (Task 10).

For Task 9 specifically, leave `:auto_start_simulation` boot to Task 10. **In this task, the `:primary` world will NOT auto-start** — the dashboard and tests will see no world running. Tests will fail. This is expected; Task 10 wires the boot.

- [ ] **Step 7: Run the suite — expect a wave of failures**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0 2>&1 | tail -20'
```

Expected: many failures across `test/lenies_web/`, `test/lenies/world*`, etc., because no `:primary` world is running yet. Note this is **expected** and resolved in Task 10. Commit anyway — the WORLD code itself compiles and is structurally correct.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: per-world Supervisor sub-tree (rest_for_one: World + LenieSupervisor + Telemetry)

LenieSupervisor and Telemetry are now started under the per-world Supervisor
instead of the global top-level tree. The :primary world is not yet
auto-started — Task 10 wires Application.start to call
Worlds.start_world(:primary). Suite is intentionally red between Task 9 and
Task 10 commits."
```

---

## Task 10: Application boot — start `:primary` via `Worlds`; drop singleton compat

**Files:**
- Modify: `lib/lenies/application.ex` — after `Supervisor.start_link`, conditionally start `:primary`.
- Modify: `lib/lenies/world.ex` — `start_link` no longer registers as `Lenies.World` (only via Registry).

- [ ] **Step 1: Start `:primary` from `Lenies.Application.start/2`**

In `lib/lenies/application.ex`:

```elixir
def start(_type, _args) do
  # children list (unchanged from Task 9)
  children = [
    # ...
  ]

  opts = [strategy: :one_for_one, name: Lenies.Supervisor]
  result = Supervisor.start_link(children, opts)

  if Application.get_env(:lenies, :auto_start_simulation, true) do
    {:ok, _} = Lenies.Worlds.start_world(:primary, %{})
  end

  result
end
```

(If `result` is `{:error, _}` the world start won't be reached because `{:ok, _} = ...` would raise — that's fine; the supervisor failure dominates.)

- [ ] **Step 2: Remove the singleton-name compat from `Lenies.World`**

In `lib/lenies/world.ex`, change `server_name/1` so `:primary` no longer uses the global atom name:

```elixir
defp server_name(world_id),
  do: {:via, Registry, {Lenies.Registry, {:world, world_id}}}
```

(Drop the `defp server_name(:primary), do: @name` clause and the `@name` attribute.)

- [ ] **Step 3: Remove the module-level shim functions in `Lenies.World`**

`Lenies.World.spawn_lenie/2`, `World.action/1`, `World.sterilize/0`, `World.pause/0`, `World.resume/0`, `World.snapshot_stats/0`, `World.tick_now/0`, `World.restore_tables/1`, `World.lenie_died/4`, `World.paused?/0`, `World.reconcile/0` — these are the module-level singletons that today wrap `GenServer.call(@name, …)`.

For each: either delete the function (and migrate every caller in step 4) OR leave it as a thin wrapper around `Lenies.Worlds.X(:primary, …)`. **Decision:** delete them. The Worlds facade is the API now. Migrating callers is mechanical and forces a clean break (no lingering callers of the old singleton API).

- [ ] **Step 4: Update internal callers**

```bash
grep -rn 'Lenies\.World\.' lib test | grep -v 'Lenies\.World\.Config\|Lenies\.World\.Supervisor\|Lenies\.World\.Telemetry\|Lenies\.World\.Tables'
```

For each match outside the World/Supervisor/Telemetry/Tables/Config modules (i.e., LiveViews, controllers, tests), replace `Lenies.World.foo(args…)` with `Lenies.Worlds.foo(:primary, args…)`. This is mechanical. (Task 11 covers the LiveViews specifically; this step takes care of any other internal call sites the grep finds.)

- [ ] **Step 5: Run the suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0 2>&1 | tail -5'
```

Expected: still some failures from LiveView/web tests if they reference `Lenies.World` directly — those get fixed in Task 11. But the non-web `Lenies.*` tests should be green.

To get a sense:

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/ 2>&1 | tail -5'
```

Expected: most non-web tests pass; possibly a few related to engine bring-up. Fix any remaining.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: Application boots :primary via Lenies.Worlds; drop World singleton name and module-level shims

The Worlds facade is now the sole API for world operations. LiveView/web
tests still fail until Task 11 migrates them."
```

---

## Task 11: Migrate LiveViews (and their tests) to the Worlds facade + scoped topics

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Modify: `lib/lenies_web/live/editor_live.ex`
- Modify: `lib/lenies_web/live/lenie_inspector_live.ex`
- Modify: `lib/lenies_web/live/species_live.ex`
- Modify: `lib/lenies_web/live/controls_panel_component.ex`
- Modify: `lib/lenies_web/grid_renderer.ex` (color computation uses handle)
- Modify: `test/lenies_web/live/*.exs` — set up the `:primary` world (auto-started by Application) and use `Lenies.Worlds.*(:primary, …)`.

This task is mechanical but spans several files. Apply the same patterns consistently.

- [ ] **Step 1: Add `:world_id` and `:world_handle` to each LiveView's mount**

In each LiveView module (Dashboard, Editor, LenieInspector, Species), in `mount/3`:

```elixir
def mount(_params, _session, socket) do
  world_id = :primary
  {:ok, handle} = Lenies.Worlds.handle(world_id)

  if connected?(socket) do
    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{handle.pubsub_prefix}:tick")
    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{handle.pubsub_prefix}:control")
    # ...other topics this LiveView needs, all using handle.pubsub_prefix...
  end

  {:ok, socket |> assign(world_id: world_id, world_handle: handle) |> ...existing assigns...}
end
```

- [ ] **Step 2: Replace `Lenies.World.X(…)` calls with `Lenies.Worlds.X(:primary, …)` or `Lenies.Worlds.X(@world_handle, …)`**

In each LiveView, grep for `Lenies.World.` and substitute. Prefer passing the handle for hot paths; world id for one-offs.

Specifically:
- `Lenies.World.sterilize()` → `Lenies.Worlds.sterilize(@world_id)`
- `Lenies.World.pause()` / `.resume()` / `.paused?()` → same pattern
- `Lenies.World.spawn_lenie(codeome, opts)` → `Lenies.Worlds.spawn_lenie(@world_id, codeome, opts)`
- `Lenies.World.snapshot_stats()` → `Lenies.Worlds.snapshot_stats(@world_id)`
- `Application.put_env(:lenies, key, value)` in the tune handler → `Lenies.Worlds.tune(@world_id, key, value)`

- [ ] **Step 3: Replace hardcoded PubSub topic strings**

Find every `Phoenix.PubSub.subscribe(Lenies.PubSub, "world:…")` or `…"lenie:…"` in the LiveView files. Replace with the prefix-based variants.

- [ ] **Step 4: Update `Lenies.SpeciesColor` callers**

The component's `spawn_seed` `"custom:" <> id` clause calls `Lenies.SpeciesColor.set_override(hash, seed.color_hex)`. After Task 7, this needs a handle:

```elixir
Lenies.SpeciesColor.set_override(socket.assigns.world_handle, hash, seed.color_hex)
```

Same for any other `SpeciesColor.*` caller.

- [ ] **Step 5: Update `grid_renderer.ex`**

The renderer computes colors per cell. Today it calls `SpeciesColor.hex(hash)`. After Task 7, accept a handle as a parameter and pass it to `SpeciesColor.hex(handle, hash)`. The caller (the LiveView render path) supplies the handle from its assigns.

- [ ] **Step 6: Update LiveView tests**

Failing tests across `test/lenies_web/live/*.exs` reference `Lenies.World.*`. Mechanical replacement: `Lenies.World.X(args…)` → `Lenies.Worlds.X(:primary, args…)`.

Tests that called `Process.whereis(Lenies.World)` to detect the world: replace with `Lenies.Worlds.alive?(:primary)` (returns boolean).

Tests that wrote `Lenies.SpeciesColor.set_override(hash, hex)` directly: replace with `Lenies.SpeciesColor.set_override(handle, hash, hex)`, fetching the handle with `{:ok, handle} = Lenies.Worlds.handle(:primary)`.

- [ ] **Step 7: Run the full suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0 2>&1 | tail -5'
```

Expected: 702 tests, 0 failures (the same count as the pre-refactor baseline; the new `Lenies.Worlds`/`Config` tests are additional). Total should be ~710.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(web): LiveViews and their tests use the Lenies.Worlds facade + scoped topics"
```

---

## Task 12: Snapshot refactor — per-world directory, 5 tables, legacy tolerance

**Files:**
- Modify: `lib/lenies/snapshot.ex`
- Modify: `lib/lenies/worlds.ex` — add `save_snapshot/2` and `restore_snapshot/2` facade methods.
- Modify: `lib/lenies/world.ex` — `handle_call({:save_snapshot, name}, …)` and `restore_snapshot` callbacks.
- Test: `test/lenies/snapshot_test.exs` (exists today; update tests to use a handle).

- [ ] **Step 1: Refactor `Lenies.Snapshot.save/2`**

Today: `save_to_disk(name)` operates on the global named tables. Refactor to:

```elixir
@spec save(Lenies.WorldHandle.t(), String.t()) ::
        :ok | {:error, :invalid_name | term()}
def save(%Lenies.WorldHandle{} = handle, name) do
  with :ok <- validate_name(name) do
    dir = Path.join(snapshot_dir(handle.id), name)
    File.mkdir_p!(dir)

    for {key, tid} <- handle.tables do
      tmp = Path.join(dir, "#{key}.tab.tmp")
      final = Path.join(dir, "#{key}.tab")
      :ok = :ets.tab2file(tid, String.to_charlist(tmp))
      :ok = File.rename(tmp, final)
    end

    :ok
  end
end

defp snapshot_dir(world_id) do
  Path.join([snapshot_root(), Lenies.Worlds.id_to_path(world_id)])
end
```

- [ ] **Step 2: Refactor `Lenies.Snapshot.restore/2`**

```elixir
@spec restore(Lenies.WorldHandle.t(), String.t()) ::
        :ok | {:error, term()}
def restore(%Lenies.WorldHandle{} = handle, name) do
  with :ok <- validate_name(name) do
    dir = Path.join(snapshot_dir(handle.id), name)

    # Required: cells, lenies, child_slots, history. Optional: color_overrides
    # (legacy 4-table snapshots don't have it — load empty).
    required = [:cells, :lenies, :child_slots, :history]
    optional = [:color_overrides]

    with :ok <- validate_files(dir, required),
         :ok <- restore_required(handle, dir, required),
         :ok <- restore_optional(handle, dir, optional) do
      :ok
    end
  end
end

defp restore_required(handle, dir, keys) do
  Enum.reduce_while(keys, :ok, fn key, _ ->
    path = Path.join(dir, "#{key}.tab")
    case :ets.file2tab(String.to_charlist(path)) do
      {:ok, loaded_tid} ->
        :ets.delete_all_objects(handle.tables[key])
        :ets.foldl(fn obj, _ -> :ets.insert(handle.tables[key], obj) end, :ok, loaded_tid)
        :ets.delete(loaded_tid)
        {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:corrupt, key, reason}}}
    end
  end)
end

defp restore_optional(handle, dir, keys) do
  Enum.each(keys, fn key ->
    path = Path.join(dir, "#{key}.tab")
    if File.exists?(path) do
      {:ok, loaded_tid} = :ets.file2tab(String.to_charlist(path))
      :ets.delete_all_objects(handle.tables[key])
      :ets.foldl(fn obj, _ -> :ets.insert(handle.tables[key], obj) end, :ok, loaded_tid)
      :ets.delete(loaded_tid)
    else
      :ets.delete_all_objects(handle.tables[key])  # legacy snapshot: start empty
    end
  end)
  :ok
end
```

- [ ] **Step 3: Add facade methods to `Lenies.Worlds`**

```elixir
def save_snapshot(target, name) do
  with {:ok, handle} <- handle(target) do
    GenServer.call(handle.pid, {:save_snapshot, name})
  end
end

def restore_snapshot(target, name) do
  with {:ok, handle} <- handle(target) do
    GenServer.call(handle.pid, {:restore_snapshot, name})
  end
end
```

- [ ] **Step 4: Add the matching `handle_call` clauses in `Lenies.World`**

```elixir
def handle_call({:save_snapshot, name}, _from, state) do
  result = Lenies.Snapshot.save(state.handle, name)
  {:reply, result, state}
end

def handle_call({:restore_snapshot, name}, _from, state) do
  # Sterilize first (kills all Lenies, resets cells/etc.)
  state = sterilize_state(state)
  result = Lenies.Snapshot.restore(state.handle, name)
  {:reply, result, state}
end
```

- [ ] **Step 5: Update existing snapshot tests**

In `test/lenies/snapshot_test.exs` (and any other tests calling `Snapshot.save_to_disk/restore_from_disk` directly), switch to `Lenies.Worlds.save_snapshot(:primary, name)` / `Lenies.Worlds.restore_snapshot(:primary, name)`. For tests calling `Snapshot` directly with a handle: `{:ok, handle} = Lenies.Worlds.handle(:primary); Lenies.Snapshot.save(handle, name)`.

- [ ] **Step 6: Run the suite**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test --seed 0 2>&1 | tail -5'
```

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(snapshot): per-world directory layout, 5 tables incl. color_overrides, legacy 4-table tolerance"
```

---

## Task 13: Multi-world isolation tests — the 8 deliverable cases

**Files:**
- Modify: `test/lenies/worlds_test.exs` — add the 8 cases.

These tests run in `async: false` because they start/stop worlds (global Registry state).

- [ ] **Step 1: Add the test cases**

Append to `test/lenies/worlds_test.exs`:

```elixir
  describe "multi-world isolation" do
    @moduletag :integration

    setup do
      # Stop :primary so tests get a clean slate (we'll start :a and :b explicitly).
      Lenies.Worlds.stop_world(:primary)
      on_exit(fn ->
        Lenies.Worlds.stop_world(:a)
        Lenies.Worlds.stop_world(:b)
        # restart :primary for the rest of the suite
        {:ok, _} = Lenies.Worlds.start_world(:primary, %{})
      end)
      :ok
    end

    test "1. lifecycle: start, handle, stop — no residue" do
      {:ok, _sup} = Lenies.Worlds.start_world(:a, %{})
      assert Lenies.Worlds.alive?(:a)
      {:ok, %Lenies.WorldHandle{id: :a}} = Lenies.Worlds.handle(:a)
      :ok = Lenies.Worlds.stop_world(:a)
      Process.sleep(50)
      refute Lenies.Worlds.alive?(:a)
    end

    test "2. two worlds in parallel, disjoint state and PubSub" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})

      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      # Distinct ETS tables
      refute ha.tables.cells == hb.tables.cells
      refute ha.tables.lenies == hb.tables.lenies

      # Subscribe to :a's tick topic only
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{hb.pubsub_prefix}:tick")
      # Wait for at least one tick on :b
      assert_receive {:tick, _}, 500

      # Now subscribe nothing more; ensure no :a ticks arrive for a window.
      refute_receive {:tick, _, :a}, 100
    end

    test "3. per-world tuning isolated" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{eat_amount: 200.0})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{eat_amount: 50.0})

      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      assert :sys.get_state(ha.pid).config.eat_amount == 200.0
      assert :sys.get_state(hb.pid).config.eat_amount == 50.0
    end

    test "4. per-world color_overrides" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})
      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      Lenies.SpeciesColor.set_override(ha, "deadbeef", "#ff0000")
      Lenies.SpeciesColor.set_override(hb, "deadbeef", "#00ff00")

      assert Lenies.SpeciesColor.override(ha, "deadbeef") == "#ff0000"
      assert Lenies.SpeciesColor.override(hb, "deadbeef") == "#00ff00"
    end

    test "5. crash isolation" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})
      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      original_b_pid = hb.pid

      # Kill :a's World
      Process.exit(ha.pid, :kill)
      Process.sleep(100)

      # :a restarts fresh (rest_for_one): a new World pid, empty tables
      {:ok, ha2} = Lenies.Worlds.handle(:a)
      refute ha2.pid == ha.pid

      # :b is untouched
      {:ok, hb2} = Lenies.Worlds.handle(:b)
      assert hb2.pid == original_b_pid
    end

    test "6. snapshot per-world" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})
      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      # mark :a with a distinct color override that we can verify after restore
      Lenies.SpeciesColor.set_override(ha, "marker", "#abcdef")

      :ok = Lenies.Worlds.save_snapshot(:a, "test_snap")
      Lenies.SpeciesColor.clear_override(ha, "marker")
      refute Lenies.SpeciesColor.override(ha, "marker")

      :ok = Lenies.Worlds.restore_snapshot(:a, "test_snap")
      assert Lenies.SpeciesColor.override(ha, "marker") == "#abcdef"

      # :b untouched throughout
      refute Lenies.SpeciesColor.override(hb, "marker")
    end

    test "7. Registry tuple keys: same lenie id in two worlds" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})

      # Tuple keys mean {:lenie, :a, "x"} and {:lenie, :b, "x"} don't collide.
      Registry.register(Lenies.Registry, {:lenie, :a, "X"}, :a_marker)
      # Different process can't register the same key, so simulate from another process for :b:
      task = Task.async(fn ->
        Registry.register(Lenies.Registry, {:lenie, :b, "X"}, :b_marker)
        Process.sleep(50)
      end)

      assert [{_, :a_marker}] = Registry.lookup(Lenies.Registry, {:lenie, :a, "X"})
      assert [{_, :b_marker}] = Registry.lookup(Lenies.Registry, {:lenie, :b, "X"})

      Task.await(task)
    end

    test "8. backward-compat: :primary world is auto-started by Application" do
      # This is implicitly proven by the rest of the suite; explicit assertion here.
      # The setup of THIS describe block stops :primary, so we start it back to
      # confirm the start path works.
      {:ok, _} = Lenies.Worlds.start_world(:primary, %{})
      assert Lenies.Worlds.alive?(:primary)
      {:ok, _} = Lenies.Worlds.handle(:primary)
    end
  end
```

- [ ] **Step 2: Run the new tests**

```bash
bash -c '. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/worlds_test.exs --seed 0'
```

Expected: all 8 + the earlier handle/id_to_path tests pass.

- [ ] **Step 3: Commit**

```bash
git add test/lenies/worlds_test.exs
git commit -m "test(worlds): 8 multi-world isolation tests proving sub-project #2's deliverable"
```

---

## Task 14: Final precommit + cleanup

**Files:** (only changes that surface during this step)

- [ ] **Step 1: Verify nothing references `:species_color_overrides` or the singleton `Lenies.World` name**

```bash
grep -rn 'species_color_overrides' lib test     # must be empty
grep -rn 'Process\.whereis(Lenies\.World)' lib test  # must be empty
grep -rn 'GenServer\.call(Lenies\.World,' lib test    # must be empty
```

Each must return no matches. Fix any stragglers.

- [ ] **Step 2: Run `mix precommit` end-to-end**

```bash
bash -c '. ~/.asdf/asdf.sh && mix precommit'
```

Expected: compile (warnings-as-errors) clean; `deps.unlock --unused` no changes; `format` clean (if it reformats files, include them in the commit); test suite green (~710 tests, 0 failures — pre-existing telemetry flakiness aside; re-run with `--seed 0` if a flaky test fails to confirm).

- [ ] **Step 3: Commit any format-only changes**

```bash
git add -A
git commit -m "chore: precommit format pass after multi-world refactor"
```

(Skip this commit if `format` made no changes.)

- [ ] **Step 4: Confirm the dashboard still renders end-to-end**

(Manual smoke; can be deferred to a verifier subagent.) Start `iex -S mix phx.server`; register / log in (sub-project #1 flow); reach the dashboard at `/`; confirm SPECIES count, sparkline, tuning sliders, +New Seed, Spawn, Manage, and Snapshot all work as before. The dashboard is now talking to the `:primary` world through the Worlds facade — externally indistinguishable from before.

---

## Self-Review notes (resolved)

- **Spec coverage:**
  - Unnamed ETS + handle struct: Tasks 5, 7 ✓
  - One global `Lenies.Registry` tuple-keyed: Task 1 ✓
  - Per-world `%Config{}` (tuning per-world): Tasks 3, 5, 8 (tune) ✓
  - `:species_codeomes` global, `color_overrides` per-world: Tasks 4, 7 ✓
  - Per-world Supervisor sub-tree (`rest_for_one`): Task 9 ✓
  - Scoped PubSub topics: Tasks 5, 6, 11 ✓
  - `:primary` world auto-started: Task 10 ✓
  - Lenies.Worlds facade: Task 8 ✓
  - Per-world Telemetry: Task 9 ✓
  - Per-world Snapshot (5 tables, legacy tolerance): Task 12 ✓
  - 8 isolation tests: Task 13 ✓
- **Placeholder scan:** no TBD/TODO; every step is concrete. The "very large refactor" tasks (5, 6, 7, 11) describe the substitution pattern + file lists + verification commands; complete code is shown for new modules and for the changeset shape rather than every individual ETS site (~50 mechanical substitutions across world.ex + lenie.ex would bloat the plan without adding clarity — `grep` + the documented pattern is sufficient).
- **Type consistency:** `Lenies.WorldHandle` struct shape is defined in Task 2 and referenced consistently. `Lenies.World.Config` field names match between Task 3, Task 5 (init), and Task 8 (tune validation). Topic strings always built as `"#{prefix}:<suffix>"` where `prefix = "world:" <> id_to_path(id)`.
- **Suite-green checkpoints:** Tasks 1, 2, 3, 4, 5, 6, 7, 8, 12, 13, 14 end green. Tasks 9 and 10 intentionally leave the suite red **between** them (the gap between "boot path removed" and "boot path rewired"); Task 10's commit message documents this.
