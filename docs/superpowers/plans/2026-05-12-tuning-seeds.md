# Tuning Live + Seeds Implementation Plan (Sotto-progetto 7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere il pannello Controllo finale al dashboard: Seed dropdown per spawnare Codeome predefiniti (`minimal_replicator`, `carnivore`, `random`), slider live per i parametri di simulazione configurabili (radiazione, mutation rates, attack damage, eat amount), e snapshot/restore di base dello stato del mondo (dump/load ETS).

**Architecture:**
- `Lenies.Seeds` registra una mappa di id → seed (Codeome + descrizione + default options); `World.spawn_lenie/2` posiziona un Lenie su una cella libera scelta randomamente
- Dashboard aggiunge: pannello Seed (dropdown + count + button "Spawn") e pannello Tuning (~7 slider per chiavi config note)
- Slider events: `phx-change` → `Application.put_env(:lenies, key, value)` (immediato, no broadcast — il prossimo tick legge il nuovo valore)
- `Lenies.Snapshot.save_to_disk/1` dumps :cells, :lenies, :child_slots, :history via `:ets.tab2file/2`; `Lenies.Snapshot.restore_from_disk/1` sterilizes + clears + `:ets.file2tab/1`
- Limitazione documentata: il restore NON respawna i Lenie processes (lo stato ETS è "ghost"; serve come fotografia ispezionabile, non per riprendere live)

**Tech Stack:** Phoenix LiveView (slider components), `:ets.tab2file/2` + `:ets.file2tab/1` (built-in Erlang), `:rand` per posizionamento random.

**Spec di riferimento:** [docs/superpowers/specs/2026-05-11-lenies-design.md](../specs/2026-05-11-lenies-design.md) — §7.1 Controllo (Seed, Tuning live, snapshot/restore in §11 esplicitato come fuori scope ma incluso qui in versione minima).

**Criterio di completamento end-to-end:**
1. Dashboard ha 3 nuovi pannelli/elementi: Seed dropdown + count + Spawn button; Tuning sliders; Save/Restore buttons
2. Spawn di `minimal_replicator × 5` produce 5 Lenie attivi sulla griglia
3. Slider radiation_per_tick → cambio immediato visibile nel canvas
4. Save su /tmp/lenies-snapshot.tabs dumps lo stato; Restore lo ricarica
5. Tutti i test passano; tag `v0.7.0-tuning-seeds` su HEAD

---

## File structure

| File | Stato | Responsabilità |
|---|---|---|
| `lib/lenies/seeds.ex` | new | Registry seed: id → %{name, codeome, default_options} |
| `lib/lenies/world.ex` | modify | `spawn_lenie/2` (random free cell placement) |
| `lib/lenies/snapshot.ex` | new | save_to_disk / restore_from_disk via tab2file/file2tab |
| `lib/lenies_web/live/dashboard_live.ex` | modify | Pannelli Seed + Tuning + Save/Restore |
| `config/runtime.exs` | modify | Limiti default per slider |

| Test file | Nuovo/modifica |
|---|---|
| `test/lenies/seeds_test.exs` | new |
| `test/lenies/world_spawn_test.exs` | new |
| `test/lenies/snapshot_test.exs` | new |
| `test/lenies_web/live/dashboard_live_test.exs` | modify (Seed + Tuning + Save) |

---

## Task 1: Lenies.Seeds registry

**Files:**
- Create: `lib/lenies/seeds.ex`
- Test: `test/lenies/seeds_test.exs`

- [ ] **Step 1.1: Test seeds registry**

Create `test/lenies/seeds_test.exs`:
```elixir
defmodule Lenies.SeedsTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Seeds}

  test "all/0 returns a list of seed records" do
    seeds = Seeds.all()
    assert is_list(seeds)
    assert length(seeds) >= 2  # at least minimal_replicator and carnivore
    for s <- seeds do
      assert is_atom(s.id)
      assert is_binary(s.name)
      assert %Codeome{} = s.codeome
      assert is_map(s.default_options)
    end
  end

  test "all/0 includes minimal_replicator, carnivore, random" do
    ids = Seeds.all() |> Enum.map(& &1.id)
    assert :minimal_replicator in ids
    assert :carnivore in ids
    assert :random in ids
  end

  test "get/1 returns a seed by id" do
    minimal = Seeds.get(:minimal_replicator)
    assert minimal.id == :minimal_replicator
    assert %Codeome{} = minimal.codeome
  end

  test "get/1 returns nil for unknown id" do
    assert Seeds.get(:nonexistent) == nil
  end

  test "build_random_codeome/0 returns a Codeome of reasonable length" do
    c = Seeds.build_random_codeome()
    n = Codeome.size(c)
    assert n >= 20 and n <= 200
  end

  test "build_random_codeome/0 returns different Codeomes on successive calls" do
    c1 = Seeds.build_random_codeome()
    c2 = Seeds.build_random_codeome()
    # Probabilistic: with random length and random opcodes, two consecutive calls almost never collide
    refute Codeome.to_list(c1) == Codeome.to_list(c2)
  end
end
```

- [ ] **Step 1.2: Run test (should fail)**

```bash
export PATH="$HOME/.asdf/shims:$PATH"
mix test test/lenies/seeds_test.exs
```

- [ ] **Step 1.3: Implement Seeds**

Create `lib/lenies/seeds.ex`:
```elixir
defmodule Lenies.Seeds do
  @moduledoc """
  Registry of seed Codeomes for the dashboard Seed dropdown.

  Each seed has:
  - `id`: atom identifier (used in dropdown values)
  - `name`: human-readable label
  - `codeome`: a `Lenies.Codeome.t()` (or a 0-arity function for lazy/random ones)
  - `default_options`: keyword/map with initial energy, etc.

  Vedi spec §7.1 (Controllo / Seed) e §5.5 (seed predefiniti).
  """

  alias Lenies.Codeome
  alias Lenies.Codeome.Opcodes
  alias Lenies.Codeomes.{Carnivore, MinimalReplicator}

  @random_min_len 30
  @random_max_len 120

  @doc "All available seeds as a list of records."
  def all do
    [
      %{
        id: :minimal_replicator,
        name: "Minimal Replicator",
        codeome: MinimalReplicator.codeome(),
        default_options: %{energy: 2000.0}
      },
      %{
        id: :carnivore,
        name: "Carnivore",
        codeome: Carnivore.codeome(),
        default_options: %{energy: 2000.0}
      },
      %{
        id: :random,
        name: "Random (probabilmente sterile)",
        codeome: build_random_codeome(),
        default_options: %{energy: 200.0}
      }
    ]
  end

  @doc "Look up a seed by id. Returns nil if not found."
  def get(id) when is_atom(id) do
    Enum.find(all(), &(&1.id == id))
  end

  @doc """
  Build a random Codeome of length between @random_min_len and @random_max_len,
  with opcodes uniformly sampled from the whitelist.
  """
  def build_random_codeome do
    len = :rand.uniform(@random_max_len - @random_min_len + 1) + @random_min_len - 1
    whitelist = Opcodes.all()

    opcodes = for _ <- 1..len, do: Enum.random(whitelist)
    Codeome.from_list(opcodes)
  end
end
```

- [ ] **Step 1.4: Run tests (should pass)**

```bash
mix test test/lenies/seeds_test.exs
```

- [ ] **Step 1.5: Full suite**

```bash
mix test
```

- [ ] **Step 1.6: Commit**

```bash
git add lib/lenies/seeds.ex test/lenies/seeds_test.exs
git commit -m "feat: add Lenies.Seeds registry with minimal_replicator/carnivore/random"
```

---

## Task 2: World spawn_lenie helper

**Files:**
- Modify: `lib/lenies/world.ex`
- Test: `test/lenies/world_spawn_test.exs`

- [ ] **Step 2.1: Test spawn_lenie**

Create `test/lenies/world_spawn_test.exs`:
```elixir
defmodule Lenies.WorldSpawnTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, World}
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      case Process.whereis(Lenies.LenieSupervisor) do
        sup_pid when is_pid(sup_pid) ->
          DynamicSupervisor.which_children(sup_pid)
          |> Enum.each(fn {_, child_pid, _, _} ->
            if is_pid(child_pid), do: DynamicSupervisor.terminate_child(sup_pid, child_pid)
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

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    :ok
  end

  test "spawn_lenie/2 places a new Lenie on a random free cell" do
    codeome = Codeome.from_list([:nop_0, :nop_0, :nop_0])
    result = World.spawn_lenie(codeome, energy: 500.0)

    assert {:ok, {lenie_id, {x, y}}} = result
    assert is_binary(lenie_id)
    assert x in 0..255
    assert y in 0..255

    [{_, cell}] = :ets.lookup(:cells, {x, y})
    assert cell.lenie_id == lenie_id

    # Registry confirms a live process
    pid = Lenies.Registry.whereis(lenie_id)
    assert is_pid(pid)
    Process.unlink(pid)
    GenServer.stop(pid)
  end

  test "spawn_lenie/2 returns :no_free_cell when grid is full" do
    # Fill every cell with a fake lenie_id
    for x <- 0..255, y <- 0..255 do
      [{key, cell}] = :ets.lookup(:cells, {x, y})
      :ets.insert(:cells, {key, %{cell | lenie_id: "FAKE"}})
    end

    codeome = Codeome.from_list([:nop_0])
    assert {:error, :no_free_cell} = World.spawn_lenie(codeome, energy: 100.0)
  end
end
```

- [ ] **Step 2.2: Run test (should fail)**

```bash
mix test test/lenies/world_spawn_test.exs
```

- [ ] **Step 2.3: Add spawn_lenie to World**

In `lib/lenies/world.ex`, add public API + handler:

```elixir
@doc """
Spawn a new Lenie with `codeome` on a random free cell.

Options:
- `:energy` (default 500.0)
- `:dir` (default `:n`)
- `:lineage` (default `{nil, 0}`)

Returns `{:ok, {id, pos}}` on success or `{:error, :no_free_cell}` if the grid is full.
"""
def spawn_lenie(codeome, opts \\ []) do
  GenServer.call(@name, {:spawn_lenie, codeome, opts})
end
```

Add `handle_call({:spawn_lenie, codeome, opts}, ...)` clause (placed alongside other handle_call clauses, before handle_info):

```elixir
@impl true
def handle_call({:spawn_lenie, codeome, opts}, _from, state) do
  case find_random_free_cell(state.grid) do
    {:ok, pos} ->
      lenie_id = generate_lenie_id()
      energy = Keyword.get(opts, :energy, 500.0)
      dir = Keyword.get(opts, :dir, :n)
      lineage = Keyword.get(opts, :lineage, {nil, 0})

      child_opts = [
        id: lenie_id,
        codeome: codeome,
        energy: energy * 1.0,
        pos: pos,
        dir: dir,
        lineage: lineage
      ]

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Lenies.LenieSupervisor,
          Supervisor.child_spec({Lenies.Lenie, child_opts}, restart: :temporary)
        )

      # Mark cell occupied
      [{key, cell}] = :ets.lookup(:cells, pos)
      :ets.insert(:cells, {key, %{cell | lenie_id: lenie_id}})

      {:reply, {:ok, {lenie_id, pos}}, state}

    :no_free_cell ->
      {:reply, {:error, :no_free_cell}, state}
  end
end
```

Add helpers (with other defp helpers at the bottom):

```elixir
defp find_random_free_cell({w, h}) do
  # Sample random cells up to N times; if all are occupied, fall back to scan
  max_tries = 100

  case sample_free_cell({w, h}, max_tries) do
    {:ok, pos} ->
      {:ok, pos}

    :exhausted ->
      scan_for_free_cell({w, h})
  end
end

defp sample_free_cell(_grid, 0), do: :exhausted

defp sample_free_cell({w, h} = grid, tries) do
  x = :rand.uniform(w) - 1
  y = :rand.uniform(h) - 1

  case :ets.lookup(:cells, {x, y}) do
    [{_, %{lenie_id: nil}}] -> {:ok, {x, y}}
    _ -> sample_free_cell(grid, tries - 1)
  end
end

defp scan_for_free_cell({w, h}) do
  Enum.find_value(0..(w - 1), :no_free_cell, fn x ->
    Enum.find_value(0..(h - 1), nil, fn y ->
      case :ets.lookup(:cells, {x, y}) do
        [{_, %{lenie_id: nil}}] -> {:ok, {x, y}}
        _ -> nil
      end
    end)
  end)
end

defp generate_lenie_id do
  :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
```

(Note: the `generate_lenie_id/0` may already exist for child spawning — check the file. If present, reuse; otherwise add.)

- [ ] **Step 2.4: Run tests (should pass)**

```bash
mix test test/lenies/world_spawn_test.exs
```

- [ ] **Step 2.5: Full suite**

```bash
mix test
```

- [ ] **Step 2.6: Commit**

```bash
git add lib/lenies/world.ex test/lenies/world_spawn_test.exs
git commit -m "feat: add World.spawn_lenie with random free cell placement"
```

---

## Task 3: Seed UI in DashboardLive

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Test: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 3.1: Test Seed UI**

Append to `test/lenies_web/live/dashboard_live_test.exs`:
```elixir
  test "Seed dropdown is rendered with available seeds", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Seed"
    assert html =~ "Minimal Replicator"
    assert html =~ "Carnivore"
  end

  test "clicking Spawn triggers world spawn_lenie", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Initially no lenies
    pop_before = :ets.info(:lenies, :size) || 0

    view
    |> form("form[phx-submit='spawn_seed']", %{seed_id: "minimal_replicator", count: "1"})
    |> render_submit()

    # Wait a tick for the new Lenie to write its snapshot
    Process.sleep(100)

    pop_after = :ets.info(:lenies, :size) || 0
    assert pop_after >= pop_before + 1
  end
```

- [ ] **Step 3.2: Run test (should fail)**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

- [ ] **Step 3.3: Update DashboardLive with Seed UI**

In `lib/lenies_web/live/dashboard_live.ex`:

1. Add a Seed panel inside `render/1` (in the controls-panel area, after the existing buttons):

```heex
<form phx-submit="spawn_seed" class="seed-form">
  <h3>Seed</h3>
  <label>
    Seed:
    <select name="seed_id">
      <%= for s <- Lenies.Seeds.all() do %>
        <option value={Atom.to_string(s.id)}>{s.name}</option>
      <% end %>
    </select>
  </label>
  <label>
    Count:
    <input type="number" name="count" value="1" min="1" max="50" />
  </label>
  <button type="submit">Spawn</button>
</form>
```

2. Add `handle_event/3` clause for `"spawn_seed"`:

```elixir
def handle_event("spawn_seed", %{"seed_id" => seed_id_str, "count" => count_str}, socket) do
  seed_id = String.to_existing_atom(seed_id_str)
  count = String.to_integer(count_str) |> max(1) |> min(50)

  case Lenies.Seeds.get(seed_id) do
    %{codeome: codeome, default_options: opts} ->
      energy = Map.get(opts, :energy, 500.0)
      for _ <- 1..count do
        Lenies.World.spawn_lenie(codeome, energy: energy)
      end

    nil ->
      :ok
  end

  {:noreply, socket}
end
```

(Place this clause alongside the other handle_event clauses.)

- [ ] **Step 3.4: Run tests (should pass)**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

- [ ] **Step 3.5: Full suite**

```bash
mix test
```

- [ ] **Step 3.6: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat: add Seed dropdown + Spawn button to dashboard"
```

---

## Task 4: Tuning live sliders

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Modify: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 4.1: Test tuning slider event**

Append to `test/lenies_web/live/dashboard_live_test.exs`:
```elixir
  test "Tuning slider changes Application config in place", %{conn: conn} do
    Application.put_env(:lenies, :radiation_per_tick, 100)
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("form[phx-change='tune_param']", %{key: "radiation_per_tick", value: "250"})
    |> render_change()

    assert Application.get_env(:lenies, :radiation_per_tick) == 250

    # Cleanup
    Application.put_env(:lenies, :radiation_per_tick, 100)
  end
```

- [ ] **Step 4.2: Run test (should fail)**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

- [ ] **Step 4.3: Add Tuning UI to DashboardLive**

In `lib/lenies_web/live/dashboard_live.ex`:

1. Add a tunable_params list as a module attribute or a helper function. Place at top of module after `use`:

```elixir
@tunable_params [
  %{key: :radiation_per_tick, label: "Radiation per tick", min: 0, max: 1000, step: 10},
  %{key: :copy_substitution_rate, label: "Copy substitution rate", min: 0.0, max: 0.1, step: 0.001},
  %{key: :copy_insert_rate, label: "Copy insert rate", min: 0.0, max: 0.05, step: 0.0005},
  %{key: :copy_delete_rate, label: "Copy delete rate", min: 0.0, max: 0.05, step: 0.0005},
  %{key: :background_mutation_interval_ticks, label: "BG mutation interval (ticks, 0=off)", min: 0, max: 10000, step: 100},
  %{key: :attack_damage, label: "Attack damage", min: 0, max: 50, step: 1},
  %{key: :eat_amount, label: "Eat amount", min: 1, max: 1000, step: 10}
]
```

2. Add a helper `tunable_params/0`:
```elixir
defp tunable_params, do: @tunable_params
```

3. Add the Tuning panel in `render/1` (inside or alongside the controls):

```heex
<div class="tuning-panel">
  <h3>Tuning Live</h3>
  <%= for p <- tunable_params() do %>
    <form phx-change="tune_param" class="tuning-row">
      <label>
        <span>{p.label}</span>
        <input
          type="range"
          name="value"
          min={p.min}
          max={p.max}
          step={p.step}
          value={Application.get_env(:lenies, p.key, p.min)}
        />
        <span class="tuning-current">{Application.get_env(:lenies, p.key, p.min)}</span>
      </label>
      <input type="hidden" name="key" value={Atom.to_string(p.key)} />
    </form>
  <% end %>
</div>
```

4. Add `handle_event("tune_param", ...)`:

```elixir
def handle_event("tune_param", %{"key" => key_str, "value" => value_str}, socket) do
  key = String.to_existing_atom(key_str)
  value = parse_tune_value(value_str)
  Application.put_env(:lenies, key, value)
  {:noreply, socket}
end

defp parse_tune_value(s) do
  case Float.parse(s) do
    {f, ""} -> if f == trunc(f), do: trunc(f), else: f
    _ ->
      case Integer.parse(s) do
        {i, ""} -> i
        _ -> s
      end
  end
end
```

The `parse_tune_value/1` handles both integers (e.g., 250) and floats (e.g., 0.005) coming from the HTML number input as strings.

- [ ] **Step 4.4: Run tests**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

- [ ] **Step 4.5: Full suite**

```bash
mix test
```

- [ ] **Step 4.6: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat: add Tuning live sliders for 7 simulation parameters"
```

---

## Task 5: Snapshot save/restore module

**Files:**
- Create: `lib/lenies/snapshot.ex`
- Test: `test/lenies/snapshot_test.exs`

- [ ] **Step 5.1: Test Snapshot**

Create `test/lenies/snapshot_test.exs`:
```elixir
defmodule Lenies.SnapshotTest do
  use ExUnit.Case, async: false

  alias Lenies.{Snapshot, World}
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
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
      File.rm_rf!("/tmp/lenies-snapshot-test")
    end)

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    File.mkdir_p!("/tmp/lenies-snapshot-test")
    :ok
  end

  test "save_to_disk/1 and restore_from_disk/1 round-trip cells" do
    base = "/tmp/lenies-snapshot-test"

    # Put known state in :cells
    [{key, cell}] = :ets.lookup(:cells, {3, 3})
    :ets.insert(:cells, {key, %{cell | resource: 88, carcass: 17, lenie_id: "TEST"}})

    :ok = Snapshot.save_to_disk(base)

    # Mutate :cells in-place
    :ets.insert(:cells, {key, %{cell | resource: 0, carcass: 0, lenie_id: nil}})

    # Restore
    :ok = Snapshot.restore_from_disk(base)

    [{_, restored}] = :ets.lookup(:cells, {3, 3})
    assert restored.resource == 88
    assert restored.carcass == 17
    assert restored.lenie_id == "TEST"
  end

  test "save_to_disk/1 creates expected files" do
    base = "/tmp/lenies-snapshot-test"
    :ok = Snapshot.save_to_disk(base)

    for table <- [:cells, :lenies, :child_slots, :history] do
      path = Path.join(base, "#{table}.tab")
      assert File.exists?(path), "expected #{path} to exist"
    end
  end

  test "restore_from_disk/1 returns {:error, :missing_file} if files don't exist" do
    base = "/tmp/lenies-snapshot-nonexistent"
    assert {:error, :missing_file} = Snapshot.restore_from_disk(base)
  end
end
```

- [ ] **Step 5.2: Run test (should fail)**

```bash
mix test test/lenies/snapshot_test.exs
```

- [ ] **Step 5.3: Implement Snapshot**

Create `lib/lenies/snapshot.ex`:
```elixir
defmodule Lenies.Snapshot do
  @moduledoc """
  Save and restore the World's ETS state to/from disk.

  Uses Erlang's built-in `:ets.tab2file/2` and `:ets.file2tab/1` for compact
  binary serialization. The 4 tables saved: `:cells`, `:lenies`, `:child_slots`,
  `:history`.

  **Limitazione**: restore reloads the ETS records but does NOT respawn Lenie
  processes. The Lenies in `:lenies` after restore are "ghost" snapshots —
  visible in the Inspector but not running.

  For a real "resume" of a simulation, one would need to also save each Lenie's
  full process state (interpreter state, call_stack) and respawn them. SP7
  ships only the data-state save/restore.
  """

  @tables [:cells, :lenies, :child_slots, :history]

  @doc """
  Save all 4 ETS tables to files under `base_dir`. Creates the directory if missing.
  Returns `:ok` or `{:error, reason}`.
  """
  def save_to_disk(base_dir) do
    case File.mkdir_p(base_dir) do
      :ok ->
        Enum.reduce_while(@tables, :ok, fn table, _acc ->
          path = Path.join(base_dir, "#{table}.tab") |> String.to_charlist()

          case :ets.tab2file(table, path) do
            :ok -> {:cont, :ok}
            error -> {:halt, {:error, {table, error}}}
          end
        end)

      error ->
        error
    end
  end

  @doc """
  Restore all 4 ETS tables from files under `base_dir`. First sterilizes the
  current World (kills all Lenie processes + clears tables), then loads.
  Returns `:ok`, `{:error, :missing_file}`, or `{:error, reason}`.
  """
  def restore_from_disk(base_dir) do
    if all_files_exist?(base_dir) do
      Lenies.World.sterilize()

      # Wait briefly for sterilize to clear the tables
      Process.sleep(50)

      Enum.reduce_while(@tables, :ok, fn table, _acc ->
        path = Path.join(base_dir, "#{table}.tab") |> String.to_charlist()

        # Delete existing table first; file2tab will recreate it
        if :ets.whereis(table) != :undefined, do: :ets.delete(table)

        case :ets.file2tab(path) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, {:error, {table, error}}}
        end
      end)
    else
      {:error, :missing_file}
    end
  end

  defp all_files_exist?(base_dir) do
    Enum.all?(@tables, fn table ->
      File.exists?(Path.join(base_dir, "#{table}.tab"))
    end)
  end
end
```

- [ ] **Step 5.4: Run tests (should pass)**

```bash
mix test test/lenies/snapshot_test.exs
```

- [ ] **Step 5.5: Full suite**

```bash
mix test
```

- [ ] **Step 5.6: Commit**

```bash
git add lib/lenies/snapshot.ex test/lenies/snapshot_test.exs
git commit -m "feat: add Lenies.Snapshot save/restore via ets.tab2file"
```

---

## Task 6: Snapshot UI in dashboard

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Modify: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 6.1: Test snapshot UI**

Append to `test/lenies_web/live/dashboard_live_test.exs`:
```elixir
  test "Save snapshot button triggers Snapshot.save_to_disk", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Put a known cell state
    [{key, cell}] = :ets.lookup(:cells, {2, 2})
    :ets.insert(:cells, {key, %{cell | resource: 42}})

    base = "/tmp/lenies-ui-snapshot-test"
    File.rm_rf!(base)

    view
    |> form("form[phx-submit='save_snapshot']", %{path: base})
    |> render_submit()

    # File should exist
    assert File.exists?(Path.join(base, "cells.tab"))
    File.rm_rf!(base)
  end
```

- [ ] **Step 6.2: Run test (should fail)**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

- [ ] **Step 6.3: Add snapshot UI**

In `lib/lenies_web/live/dashboard_live.ex`, add inside the controls panel area:

```heex
<form phx-submit="save_snapshot" class="snapshot-form">
  <h3>Snapshot</h3>
  <label>
    Path:
    <input type="text" name="path" value="/tmp/lenies-snapshot" />
  </label>
  <button type="submit">Save</button>
  <button type="button" phx-click="restore_snapshot" phx-value-path="/tmp/lenies-snapshot">Restore</button>
</form>
<%= if @snapshot_status do %>
  <p class="snapshot-status">{@snapshot_status}</p>
<% end %>
```

Add `:snapshot_status` assign in `mount/3` (initial value `nil`):
```elixir
socket = socket |> assign(:snapshot_status, nil)
```

Add `handle_event` clauses:
```elixir
def handle_event("save_snapshot", %{"path" => path}, socket) do
  status =
    case Lenies.Snapshot.save_to_disk(path) do
      :ok -> "Saved to #{path}"
      {:error, reason} -> "Save failed: #{inspect(reason)}"
    end

  {:noreply, assign(socket, :snapshot_status, status)}
end

def handle_event("restore_snapshot", %{"path" => path}, socket) do
  status =
    case Lenies.Snapshot.restore_from_disk(path) do
      :ok -> "Restored from #{path}"
      {:error, :missing_file} -> "Missing snapshot files at #{path}"
      {:error, reason} -> "Restore failed: #{inspect(reason)}"
    end

  {:noreply, assign(socket, :snapshot_status, status)}
end
```

- [ ] **Step 6.4: Run tests**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

- [ ] **Step 6.5: Full suite**

```bash
mix test
```

- [ ] **Step 6.6: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat: add Save/Restore snapshot buttons to dashboard"
```

---

## Task 7: Final verification + tag v0.7.0

- [ ] **Step 7.1: Stability check (3x)**

```bash
mix test 2>&1 | tail -3
mix test 2>&1 | tail -3
mix test 2>&1 | tail -3
```

Expected: stable count across runs.

- [ ] **Step 7.2: Format check**

```bash
mix format --check-formatted
```

- [ ] **Step 7.3: Browser smoke test**

```bash
mix phx.server > /tmp/lenies_sp7.log 2>&1 &
SERVER_PID=$!
sleep 5

curl -sf http://localhost:4000/ -o /tmp/dash.html
echo "--- New panels in dashboard ---"
grep -E "(Seed|Tuning|Snapshot|Minimal Replicator|radiation_per_tick)" /tmp/dash.html | head -10

kill $SERVER_PID 2>/dev/null
wait 2>/dev/null
```

Expected: dashboard contains Seed dropdown, Tuning sliders, Snapshot buttons.

- [ ] **Step 7.4: Tag baseline**

```bash
git status
git log --oneline | head -10
git tag v0.7.0-tuning-seeds
git tag -l
git rev-list -n 1 v0.7.0-tuning-seeds
git rev-list -n 1 HEAD
```

Expected: working tree clean, tag matches HEAD.

This is the FINAL MVP tag — sub-projects 1 through 7 complete, the Lenies sandbox is fully functional per spec.

---

## Self-Review checklist

**Spec coverage (§7.1 Controllo + §11 snapshot deferred but included):**
- [x] Seed dropdown with predefined Codeome → Task 1, 3
- [x] Tuning live slider per parametri (7 chiavi) → Task 4
- [x] Snapshot save/restore (versione minima dati-only) → Task 5, 6
- [x] World.spawn_lenie con random placement → Task 2

**Esplicitamente deferito o non implementato:**
- "minimal+forager" Codeome — non esiste; il dropdown ha minimal_replicator, carnivore, random
- "carica da file" upload custom Codeome — UX non implementata, può essere aggiunta come variante dell'input form
- Restore CHE RESPAWNA i Lenie processes — al momento è data-state only (Lenie nei `:lenies` ETS dopo restore sono "ghost", non vivi). Documentato esplicitamente in `Snapshot.@moduledoc`
- Persistence tra restart oltre allo snapshot manuale — spec §11 fuori scope MVP

**Placeholder scan:** nessun "TBD"/"TODO" non documentato. Le limitazioni sono nominate esplicitamente nei moduledoc.

**Type consistency:**
- `Seeds.all/0` ritorna lista di `%{id, name, codeome, default_options}` — consistente con `Seeds.get/1` e con il consumo in DashboardLive
- `World.spawn_lenie/2` ritorna `{:ok, {id, pos}}` o `{:error, :no_free_cell}` — consistente con dashboard handler
- `Snapshot.save_to_disk/1` ritorna `:ok | {:error, reason}` — consistente con UI

**Tech debt anticipated (post-MVP):**
- Snapshot non respawna Lenies — design choice documentata, ma per replay deterministico è insufficiente
- Tuning UI mostra range numerico ma non valida i bordi prima di chiamare put_env (slider HTML clamps lato browser)
- Random seed quasi sempre sterile — utile come baseline contro l'auto-replicazione del minimal_replicator
- No upload form per "carica da file" — feature spec non implementata
- "minimal+forager" seed mai scritto — Codeome variant da aggiungere se serve
