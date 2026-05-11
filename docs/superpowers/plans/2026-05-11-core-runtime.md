# Core Runtime Implementation Plan (Sotto-progetto 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap del progetto Lenies in Elixir/Phoenix con il "mondo" funzionante: tabelle ETS, World GenServer, tick ambientale a 10Hz, radiazione (uniforme + hotspot), Telemetry GenServer con ring buffer, supervisione completa, sterilizzazione. Nessun Lenie process ancora — solo il "biotopo".

**Architecture:** Singolo progetto Phoenix (no umbrella, no DB). Tutto sotto namespace `Lenies.*` per il core e `LeniesWeb.*` per il futuro web. `Lenies.World` è l'unico writer delle tabelle ETS `:cells`, `:lenies`, `:child_slots`; `Lenies.Telemetry` è writer di `:history`. Il tick ambientale è guidato da `Process.send_after/3` su `self()` con intervallo configurabile (0 disabilita per test).

**Tech Stack:** Elixir 1.18+, Phoenix 1.7+ (LiveView scaffold pronto ma inutilizzato qui), ExUnit, ETS, Telemetry (HEX). No DB, no mailer, no dashboard.

**Spec di riferimento:** [docs/superpowers/specs/2026-05-11-lenies-design.md](../specs/2026-05-11-lenies-design.md) — sezioni 3, 6, 8, 9, 10 sono il contratto di questo plan.

**Criterio di completamento end-to-end:** dopo `mix phx.server`, da `iex` si può chiamare `Lenies.World.snapshot_stats/0` e si vede:
- 65_536 celle
- popolazione totale = 0 (nessun Lenie ancora)
- somma `cell.resource` cresce a ogni tick (radiazione attiva), si stabilizza al cap globale
- `Lenies.Telemetry.history(:last_n, 10)` ritorna 10 snapshot recenti
- `Lenies.World.sterilize()` resetta tutto e i tick ricominciano da capo

---

## File structure

| File | Responsabilità |
|---|---|
| `mix.exs` | Dipendenze e config progetto |
| `config/config.exs`, `config/runtime.exs`, `config/dev.exs`, `config/test.exs` | Phoenix base + parametri Lenies in `runtime.exs` |
| `lib/lenies/application.ex` | Albero di supervisione |
| `lib/lenies/config.ex` | Getter tipizzati per i parametri di simulazione |
| `lib/lenies/world.ex` | GenServer World: tick, ownership ETS, API pubblica (`snapshot_stats/0`, `sterilize/0`, `tick_now/0`) |
| `lib/lenies/world/cell.ex` | `%Cell{}` struct |
| `lib/lenies/world/tables.ex` | Creazione/distruzione delle tabelle ETS |
| `lib/lenies/world/radiation.ex` | Funzione pura `distribute/3` per uno step di radiazione |
| `lib/lenies/world/hotspots.ex` | Funzione pura `drift/2` per movimento degli hotspot |
| `lib/lenies/lenie_supervisor.ex` | DynamicSupervisor (vuoto per ora — pronto per sotto-progetto 2) |
| `lib/lenies/telemetry.ex` | GenServer Telemetry: ring buffer in ETS |
| `lib/lenies_web/endpoint.ex` (e affini) | Generato da phx.new — toccato solo per `Endpoint` nella supervision |
| `test/lenies/world_test.exs` | Test del World end-to-end |
| `test/lenies/world/radiation_test.exs` | Test purezza radiazione |
| `test/lenies/world/hotspots_test.exs` | Test purezza drift hotspot |
| `test/lenies/telemetry_test.exs` | Test ring buffer |
| `test/lenies/sterilize_test.exs` | Test sterilizzazione end-to-end |
| `test/test_helper.exs` | Setup ExUnit |

---

## Task 1: Bootstrap del progetto Phoenix

**Files:**
- Create: `mix.exs`, `lib/lenies.ex`, `lib/lenies/application.ex`, `lib/lenies_web/*`, `config/*`, `test/*` (generati da phx.new)
- Modify: nessuno

- [ ] **Step 1.1: Verificare versioni**

Run:
```bash
elixir --version
mix archive | grep phx_new
```
Expected: Elixir 1.18+, `phx_new` 1.7+ installato. Se phx_new mancante:
```bash
mix archive.install hex phx_new --force
```

- [ ] **Step 1.2: Generare il progetto Phoenix nella dir corrente**

Run (dalla root `/home/patrick/projects/playground/Lenies`):
```bash
mix phx.new . --app lenies --module Lenies --no-ecto --no-mailer --no-dashboard --install --force
```

Expected:
- crea `mix.exs`, `lib/`, `config/`, `test/`, `assets/`, `priv/`, `.formatter.exs`, `.gitignore`
- INCEPTION.md e docs/ NON vengono toccati (phx.new non genera quei nomi)
- `mix deps.get` viene eseguito automaticamente dall'install flag

- [ ] **Step 1.3: Verificare che il progetto compili**

Run:
```bash
mix compile
```
Expected: PASS, nessun warning critico.

- [ ] **Step 1.4: Verificare che i test del baseline passino**

Run:
```bash
mix test
```
Expected: PASS (Phoenix genera un test placeholder che deve essere verde).

- [ ] **Step 1.5: Inizializzare git repo e commit iniziale**

Run:
```bash
git init
git add -A
git commit -m "chore: bootstrap Phoenix project for Lenies"
```

Expected: commit creato; `git status` mostra working tree pulito.

---

## Task 2: Modulo Config con getter tipizzati

**Files:**
- Create: `lib/lenies/config.ex`
- Modify: `config/runtime.exs`
- Test: `test/lenies/config_test.exs`

- [ ] **Step 2.1: Scrivere il test per il modulo Config**

Create `test/lenies/config_test.exs`:
```elixir
defmodule Lenies.ConfigTest do
  use ExUnit.Case, async: true

  alias Lenies.Config

  test "grid_size/0 returns configured size" do
    assert Config.grid_size() == {256, 256}
  end

  test "tick_interval_ms/0 returns configured value" do
    assert Config.tick_interval_ms() == 100
  end

  test "radiation_per_tick/0 returns configured value" do
    assert Config.radiation_per_tick() == 100
  end

  test "population_cap/0 returns configured value" do
    assert Config.population_cap() == 50_000
  end

  test "cell_resource_cap/0 returns configured value" do
    assert Config.cell_resource_cap() == 100
  end

  test "hotspot_count/0 returns configured value" do
    assert Config.hotspot_count() == 8
  end

  test "radiation_uniform_ratio/0 returns float 0..1" do
    r = Config.radiation_uniform_ratio()
    assert is_float(r) and r >= 0.0 and r <= 1.0
  end

  test "carcass_decay/0 returns configured value" do
    assert Config.carcass_decay() == 0.05
  end
end
```

- [ ] **Step 2.2: Eseguire il test (deve fallire)**

Run:
```bash
mix test test/lenies/config_test.exs
```
Expected: FAIL con "module Lenies.Config is not loaded".

- [ ] **Step 2.3: Implementare il modulo Config**

Create `lib/lenies/config.ex`:
```elixir
defmodule Lenies.Config do
  @moduledoc """
  Getter tipizzati per i parametri di simulazione del progetto Lenies.

  I valori vengono letti via `Application.get_env/3` dalla chiave `:lenies`.
  In `config/runtime.exs` sono definiti i default; possono essere mutati a
  runtime via `Application.put_env/3` (per i tuning slider della GUI futura).
  """

  @app :lenies

  def grid_size, do: get(:grid_size, {256, 256})
  def population_cap, do: get(:population_cap, 50_000)
  def population_warning_threshold, do: get(:population_warning_threshold, 0.8)
  def tick_interval_ms, do: get(:tick_interval_ms, 100)
  def radiation_per_tick, do: get(:radiation_per_tick, 100)
  def radiation_uniform_ratio, do: get(:radiation_uniform_ratio, 0.7)
  def hotspot_count, do: get(:hotspot_count, 8)
  def cell_resource_cap, do: get(:cell_resource_cap, 100)
  def carcass_decay, do: get(:carcass_decay, 0.05)

  defp get(key, default), do: Application.get_env(@app, key, default)
end
```

- [ ] **Step 2.4: Aggiungere i parametri a runtime.exs**

Modify `config/runtime.exs` — aggiungere PRIMA di `if config_env() == :prod do` (oppure al top se preferito):
```elixir
config :lenies,
  grid_size: {256, 256},
  population_cap: 50_000,
  population_warning_threshold: 0.8,
  tick_interval_ms: 100,
  radiation_per_tick: 100,
  radiation_uniform_ratio: 0.7,
  hotspot_count: 8,
  cell_resource_cap: 100,
  carcass_decay: 0.05
```

- [ ] **Step 2.5: Eseguire il test (deve passare)**

Run:
```bash
mix test test/lenies/config_test.exs
```
Expected: PASS, 8 test passati.

- [ ] **Step 2.6: Commit**

```bash
git add lib/lenies/config.ex test/lenies/config_test.exs config/runtime.exs
git commit -m "feat: add Lenies.Config with typed getters for simulation parameters"
```

---

## Task 3: Struct Cell

**Files:**
- Create: `lib/lenies/world/cell.ex`
- Test: `test/lenies/world/cell_test.exs`

- [ ] **Step 3.1: Scrivere il test della Cell**

Create `test/lenies/world/cell_test.exs`:
```elixir
defmodule Lenies.World.CellTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Cell

  test "new/0 returns an empty cell" do
    assert %Cell{lenie_id: nil, resource: 0, carcass: 0} = Cell.new()
  end

  test "add_resource/2 caps at cell_resource_cap" do
    cell = Cell.new()
    cell = Cell.add_resource(cell, 80)
    assert cell.resource == 80
    cell = Cell.add_resource(cell, 50)
    assert cell.resource == 100
  end

  test "add_resource/2 ignores negative" do
    cell = %Cell{resource: 10}
    assert Cell.add_resource(cell, -5).resource == 10
  end

  test "decay_carcass/2 applies decay rate" do
    cell = %Cell{carcass: 100}
    cell = Cell.decay_carcass(cell, 0.05)
    assert cell.carcass == 95
  end

  test "decay_carcass/2 floors at 0" do
    cell = %Cell{carcass: 1}
    cell = Cell.decay_carcass(cell, 0.99)
    assert cell.carcass == 0
  end
end
```

- [ ] **Step 3.2: Eseguire (deve fallire)**

Run:
```bash
mix test test/lenies/world/cell_test.exs
```
Expected: FAIL — modulo non esiste.

- [ ] **Step 3.3: Implementare Cell**

Create `lib/lenies/world/cell.ex`:
```elixir
defmodule Lenies.World.Cell do
  @moduledoc """
  Struct di una cella della griglia mondo.

  - `lenie_id`: id del Lenie residente, o `nil` se vuota.
  - `resource`: biomassa accumulata dalla radiazione (clamp a `cell_resource_cap`).
  - `carcass`: energia da carcasse (decay-tasso `carcass_decay`/tick).
  """

  alias Lenies.Config

  @type t :: %__MODULE__{
          lenie_id: nil | binary(),
          resource: non_neg_integer(),
          carcass: non_neg_integer()
        }

  defstruct lenie_id: nil, resource: 0, carcass: 0

  def new, do: %__MODULE__{}

  def add_resource(%__MODULE__{} = cell, amount) when amount > 0 do
    cap = Config.cell_resource_cap()
    %{cell | resource: min(cap, cell.resource + amount)}
  end

  def add_resource(%__MODULE__{} = cell, _), do: cell

  def decay_carcass(%__MODULE__{} = cell, rate) when rate >= 0 and rate <= 1 do
    %{cell | carcass: max(0, round(cell.carcass * (1 - rate)))}
  end
end
```

- [ ] **Step 3.4: Eseguire (deve passare)**

Run:
```bash
mix test test/lenies/world/cell_test.exs
```
Expected: PASS, 5 test.

- [ ] **Step 3.5: Commit**

```bash
git add lib/lenies/world/cell.ex test/lenies/world/cell_test.exs
git commit -m "feat: add Cell struct with resource and carcass mechanics"
```

---

## Task 4: Modulo Tables (creazione ETS)

**Files:**
- Create: `lib/lenies/world/tables.ex`
- Test: `test/lenies/world/tables_test.exs`

- [ ] **Step 4.1: Test del modulo Tables**

Create `test/lenies/world/tables_test.exs`:
```elixir
defmodule Lenies.World.TablesTest do
  use ExUnit.Case, async: false

  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      for t <- [:cells, :lenies, :child_slots, :history] do
        if :ets.whereis(t) != :undefined, do: :ets.delete(t)
      end
    end)
    :ok
  end

  test "create_all/0 creates the four named tables as public sets" do
    Tables.create_all()
    for t <- [:cells, :lenies, :child_slots, :history] do
      info = :ets.info(t)
      assert info != :undefined, "table #{t} not created"
      assert Keyword.get(info, :type) == :set
      assert Keyword.get(info, :protection) == :public
    end
  end

  test "delete_all/0 removes all named tables idempotently" do
    Tables.create_all()
    Tables.delete_all()
    for t <- [:cells, :lenies, :child_slots, :history] do
      assert :ets.whereis(t) == :undefined
    end

    # idempotente: non esplode su delete di tabelle inesistenti
    assert :ok = Tables.delete_all()
  end

  test "clear_all/0 empties tables without deleting them" do
    Tables.create_all()
    :ets.insert(:cells, {{0, 0}, :anything})
    assert :ets.info(:cells, :size) == 1
    Tables.clear_all()
    assert :ets.info(:cells, :size) == 0
    assert :ets.whereis(:cells) != :undefined
  end
end
```

- [ ] **Step 4.2: Eseguire (deve fallire)**

Run:
```bash
mix test test/lenies/world/tables_test.exs
```
Expected: FAIL.

- [ ] **Step 4.3: Implementare Tables**

Create `lib/lenies/world/tables.ex`:
```elixir
defmodule Lenies.World.Tables do
  @moduledoc """
  Crea e gestisce le tabelle ETS del progetto.

  Convenzione di ownership: il chiamante (`Lenies.World` in produzione) deve
  invocare `create_all/0` dal suo `init/1` per essere proprietario delle tabelle.
  Tutte le tabelle sono `:set`, `:named_table`, `:public`.

  Tabelle:
  - `:cells`        — `{x,y} → %Lenies.World.Cell{}` (source of truth occupazione)
  - `:lenies`       — `id    → snapshot` (scritto principalmente dai Lenies, eccezioni dal World)
  - `:child_slots`  — `slot  → record di gestazione`
  - `:history`      — ring buffer di metriche aggregate (scritto da Telemetry)
  """

  @tables [:cells, :lenies, :child_slots, :history]

  def tables, do: @tables

  def create_all do
    for t <- @tables do
      :ets.new(t, [:set, :named_table, :public, read_concurrency: true, write_concurrency: true])
    end
    :ok
  end

  def delete_all do
    for t <- @tables do
      if :ets.whereis(t) != :undefined, do: :ets.delete(t)
    end
    :ok
  end

  def clear_all do
    for t <- @tables do
      if :ets.whereis(t) != :undefined, do: :ets.delete_all_objects(t)
    end
    :ok
  end
end
```

- [ ] **Step 4.4: Eseguire (deve passare)**

Run:
```bash
mix test test/lenies/world/tables_test.exs
```
Expected: PASS, 3 test.

- [ ] **Step 4.5: Commit**

```bash
git add lib/lenies/world/tables.ex test/lenies/world/tables_test.exs
git commit -m "feat: add Tables module for ETS lifecycle management"
```

---

## Task 5: Modulo Radiation (funzione pura)

**Files:**
- Create: `lib/lenies/world/radiation.ex`
- Test: `test/lenies/world/radiation_test.exs`

- [ ] **Step 5.1: Test della radiazione**

Create `test/lenies/world/radiation_test.exs`:
```elixir
defmodule Lenies.World.RadiationTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Radiation

  @grid {256, 256}

  test "uniform_deposit/3 sums approximately to amount across all cells" do
    deposit = Radiation.uniform_deposit(@grid, 65_536)
    total = Map.values(deposit) |> Enum.sum()
    assert total == 65_536
    # ogni cella riceve almeno 1 (con amount = cells totali)
    assert Enum.all?(Map.values(deposit), &(&1 >= 1))
  end

  test "uniform_deposit/3 with small amount picks random cells" do
    deposit = Radiation.uniform_deposit(@grid, 100)
    total = Map.values(deposit) |> Enum.sum()
    assert total == 100
    # ~100 celle scelte (con duplicati possibili → ≤ 100)
    assert map_size(deposit) <= 100
  end

  test "hotspot_deposit/3 concentrates around hotspot centers" do
    hotspots = [{128, 128}, {0, 0}]
    deposit = Radiation.hotspot_deposit(@grid, 1000, hotspots, radius: 5)
    total = Map.values(deposit) |> Enum.sum()
    assert total == 1000
    # tutte le posizioni depositate sono entro `radius` da un hotspot (toroide)
    for {{x, y}, _} <- deposit do
      assert Enum.any?(hotspots, fn {hx, hy} ->
        toroidal_dist({x, y}, {hx, hy}, @grid) <= 5
      end)
    end
  end

  test "combined/3 distributes amount per uniform_ratio" do
    hotspots = [{128, 128}]
    deposit = Radiation.combined(@grid, 100, hotspots, uniform_ratio: 0.7, hotspot_radius: 5)
    total = Map.values(deposit) |> Enum.sum()
    assert total == 100
  end

  # toroidal Manhattan distance helper
  defp toroidal_dist({x1, y1}, {x2, y2}, {w, h}) do
    dx = min(abs(x1 - x2), w - abs(x1 - x2))
    dy = min(abs(y1 - y2), h - abs(y1 - y2))
    dx + dy
  end
end
```

- [ ] **Step 5.2: Eseguire (deve fallire)**

Run:
```bash
mix test test/lenies/world/radiation_test.exs
```
Expected: FAIL.

- [ ] **Step 5.3: Implementare Radiation**

Create `lib/lenies/world/radiation.ex`:
```elixir
defmodule Lenies.World.Radiation do
  @moduledoc """
  Distribuzione della radiazione "solare" sulla griglia toroidale.

  Tutte le funzioni sono pure e restituiscono una mappa `%{{x, y} => amount}`
  che il chiamante applicherà alle celle ETS. Total amount preserved.
  """

  @type grid :: {pos_integer(), pos_integer()}
  @type coord :: {non_neg_integer(), non_neg_integer()}
  @type deposit :: %{coord() => pos_integer()}

  @spec uniform_deposit(grid(), non_neg_integer()) :: deposit()
  def uniform_deposit({w, h}, amount) when amount >= 0 do
    total_cells = w * h

    cond do
      amount == 0 ->
        %{}

      amount >= total_cells ->
        base = div(amount, total_cells)
        remainder = rem(amount, total_cells)

        m =
          for x <- 0..(w - 1), y <- 0..(h - 1), into: %{} do
            {{x, y}, base}
          end

        scatter_amount(m, {w, h}, remainder)

      true ->
        # distribuzione casuale di `amount` "pacchetti unitari"
        scatter_amount(%{}, {w, h}, amount)
    end
  end

  @spec hotspot_deposit(grid(), non_neg_integer(), [coord()], keyword()) :: deposit()
  def hotspot_deposit(_grid, 0, _hotspots, _opts), do: %{}
  def hotspot_deposit(_grid, _amount, [], _opts), do: %{}

  def hotspot_deposit({w, h}, amount, hotspots, opts) do
    radius = Keyword.get(opts, :radius, 5)
    per_hotspot = div(amount, length(hotspots))
    remainder = rem(amount, length(hotspots))

    hotspots
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{hx, hy}, idx}, acc ->
      extra = if idx < remainder, do: 1, else: 0
      n = per_hotspot + extra
      candidates = neighborhood({hx, hy}, radius, {w, h})
      scatter_among(acc, candidates, n)
    end)
  end

  @spec combined(grid(), non_neg_integer(), [coord()], keyword()) :: deposit()
  def combined(grid, amount, hotspots, opts) do
    ratio = Keyword.get(opts, :uniform_ratio, 0.7)
    hotspot_radius = Keyword.get(opts, :hotspot_radius, 5)
    uniform_amount = round(amount * ratio)
    hotspot_amount = amount - uniform_amount

    u = uniform_deposit(grid, uniform_amount)
    h = hotspot_deposit(grid, hotspot_amount, hotspots, radius: hotspot_radius)

    Map.merge(u, h, fn _k, a, b -> a + b end)
  end

  # ----- internals -----

  defp scatter_amount(m, {w, h}, 0), do: m

  defp scatter_amount(m, {w, h}, n) when n > 0 do
    cell = {:rand.uniform(w) - 1, :rand.uniform(h) - 1}
    new_m = Map.update(m, cell, 1, &(&1 + 1))
    scatter_amount(new_m, {w, h}, n - 1)
  end

  defp scatter_among(m, _candidates, 0), do: m

  defp scatter_among(m, candidates, n) when n > 0 do
    cell = Enum.random(candidates)
    new_m = Map.update(m, cell, 1, &(&1 + 1))
    scatter_among(new_m, candidates, n - 1)
  end

  defp neighborhood({hx, hy}, radius, {w, h}) do
    for dx <- -radius..radius, dy <- -radius..radius do
      {Integer.mod(hx + dx, w), Integer.mod(hy + dy, h)}
    end
  end
end
```

- [ ] **Step 5.4: Eseguire (deve passare)**

Run:
```bash
mix test test/lenies/world/radiation_test.exs
```
Expected: PASS, 4 test.

- [ ] **Step 5.5: Commit**

```bash
git add lib/lenies/world/radiation.ex test/lenies/world/radiation_test.exs
git commit -m "feat: add Radiation module with uniform and hotspot deposit"
```

---

## Task 6: Modulo Hotspots (drift)

**Files:**
- Create: `lib/lenies/world/hotspots.ex`
- Test: `test/lenies/world/hotspots_test.exs`

- [ ] **Step 6.1: Test del drift**

Create `test/lenies/world/hotspots_test.exs`:
```elixir
defmodule Lenies.World.HotspotsTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Hotspots

  @grid {256, 256}

  test "initial/2 returns n hotspots on grid" do
    hs = Hotspots.initial(@grid, 8)
    assert length(hs) == 8

    for {x, y} <- hs do
      assert x in 0..255
      assert y in 0..255
    end
  end

  test "drift/2 keeps hotspots within grid (toroidal wrap)" do
    hs = [{0, 0}, {255, 255}]
    hs2 = Hotspots.drift(hs, @grid)
    assert length(hs2) == 2

    for {x, y} <- hs2 do
      assert x in 0..255
      assert y in 0..255
    end
  end

  test "drift/2 moves each hotspot by at most ±1 in each axis" do
    hs = [{100, 100}]
    [{x, y}] = Hotspots.drift(hs, @grid)
    dx = min(abs(x - 100), 256 - abs(x - 100))
    dy = min(abs(y - 100), 256 - abs(y - 100))
    assert dx <= 1
    assert dy <= 1
  end
end
```

- [ ] **Step 6.2: Eseguire (deve fallire)**

Run:
```bash
mix test test/lenies/world/hotspots_test.exs
```
Expected: FAIL.

- [ ] **Step 6.3: Implementare Hotspots**

Create `lib/lenies/world/hotspots.ex`:
```elixir
defmodule Lenies.World.Hotspots do
  @moduledoc """
  Gestione dei centri "hotspot" di radiazione: posizioni che ricevono il 30%
  della radiazione del tick. Si muovono lentamente sulla griglia toroidale.
  """

  @type grid :: {pos_integer(), pos_integer()}
  @type coord :: {non_neg_integer(), non_neg_integer()}

  @spec initial(grid(), non_neg_integer()) :: [coord()]
  def initial({w, h}, n) when n >= 0 do
    for _ <- 1..n//1 do
      {:rand.uniform(w) - 1, :rand.uniform(h) - 1}
    end
  end

  @spec drift([coord()], grid()) :: [coord()]
  def drift(hotspots, {w, h}) do
    Enum.map(hotspots, fn {x, y} ->
      dx = :rand.uniform(3) - 2  # -1 | 0 | 1
      dy = :rand.uniform(3) - 2
      {Integer.mod(x + dx, w), Integer.mod(y + dy, h)}
    end)
  end
end
```

- [ ] **Step 6.4: Eseguire (deve passare)**

Run:
```bash
mix test test/lenies/world/hotspots_test.exs
```
Expected: PASS, 3 test.

- [ ] **Step 6.5: Commit**

```bash
git add lib/lenies/world/hotspots.ex test/lenies/world/hotspots_test.exs
git commit -m "feat: add Hotspots module for drift on toroidal grid"
```

---

## Task 7: World GenServer — skeleton + init + grid

**Files:**
- Create: `lib/lenies/world.ex`
- Test: `test/lenies/world_test.exs`

- [ ] **Step 7.1: Test World init**

Create `test/lenies/world_test.exs`:
```elixir
defmodule Lenies.WorldTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  test "starts and initializes ETS tables with 65_536 empty cells" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)
    assert :ets.info(:cells, :size) == 65_536
    [{{0, 0}, cell}] = :ets.lookup(:cells, {0, 0})
    assert cell.resource == 0
    assert cell.lenie_id == nil
    assert cell.carcass == 0
  end

  test "snapshot_stats/0 returns basic counts on empty world" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)
    stats = World.snapshot_stats()
    assert stats.cells == 65_536
    assert stats.population == 0
    assert stats.total_resource == 0
    assert stats.total_carcass == 0
  end
end
```

- [ ] **Step 7.2: Eseguire (deve fallire)**

Run:
```bash
mix test test/lenies/world_test.exs
```
Expected: FAIL — modulo World non esiste.

- [ ] **Step 7.3: Implementare World skeleton**

Create `lib/lenies/world.ex`:
```elixir
defmodule Lenies.World do
  @moduledoc """
  Il "mondo" della sandbox Lenies. GenServer singleton che possiede le tabelle
  ETS, batte il tick ambientale, applica radiazione e decay carcasse, e fornisce
  API pubblica per snapshot e sterilizzazione.

  Vedi `docs/superpowers/specs/2026-05-11-lenies-design.md` §3, §6, §9.
  """

  use GenServer

  alias Lenies.Config
  alias Lenies.World.{Cell, Hotspots, Radiation, Tables}

  @name __MODULE__

  # ----- Public API -----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Statistiche rapide della sandbox per console/test."
  def snapshot_stats, do: GenServer.call(@name, :snapshot_stats)

  @doc "Forza un singolo tick sincrono (per test deterministici)."
  def tick_now, do: GenServer.call(@name, :tick_now)

  @doc "Reset completo: kill di tutti i Lenies, clear ETS, riavvio del tick."
  def sterilize, do: GenServer.call(@name, :sterilize)

  # ----- Server -----

  @impl true
  def init(opts) do
    Tables.create_all()
    grid = Config.grid_size()
    init_cells(grid)

    tick_interval = Keyword.get(opts, :tick_interval_ms, Config.tick_interval_ms())
    hotspots = Hotspots.initial(grid, Config.hotspot_count())

    state = %{
      grid: grid,
      hotspots: hotspots,
      tick_interval_ms: tick_interval,
      tick_ref: nil,
      tick_count: 0
    }

    state = maybe_schedule_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot_stats, _from, state) do
    stats = %{
      cells: :ets.info(:cells, :size),
      population: :ets.info(:lenies, :size),
      total_resource: sum_cell_field(:resource),
      total_carcass: sum_cell_field(:carcass),
      tick_count: state.tick_count
    }

    {:reply, stats, state}
  end

  def handle_call(:tick_now, _from, state) do
    state = do_tick(state)
    {:reply, :ok, state}
  end

  def handle_call(:sterilize, _from, state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    Tables.clear_all()
    init_cells(state.grid)
    hotspots = Hotspots.initial(state.grid, Config.hotspot_count())
    new_state = %{state | hotspots: hotspots, tick_count: 0, tick_ref: nil}
    new_state = maybe_schedule_tick(new_state)

    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "world:tick",
      {:sterilized, System.system_time(:millisecond)}
    )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    state = maybe_schedule_tick(%{state | tick_ref: nil})
    {:noreply, state}
  end

  # ----- internals -----

  defp init_cells({w, h}) do
    for x <- 0..(w - 1), y <- 0..(h - 1) do
      :ets.insert(:cells, {{x, y}, Cell.new()})
    end

    :ok
  end

  defp do_tick(state) do
    apply_radiation(state)
    apply_carcass_decay()

    hotspots = Hotspots.drift(state.hotspots, state.grid)

    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "world:tick",
      {:tick, state.tick_count + 1}
    )

    %{state | hotspots: hotspots, tick_count: state.tick_count + 1}
  end

  defp apply_radiation(state) do
    deposit =
      Radiation.combined(
        state.grid,
        Config.radiation_per_tick(),
        state.hotspots,
        uniform_ratio: Config.radiation_uniform_ratio()
      )

    Enum.each(deposit, fn {{x, y}, amount} ->
      case :ets.lookup(:cells, {x, y}) do
        [{key, cell}] ->
          :ets.insert(:cells, {key, Cell.add_resource(cell, amount)})

        [] ->
          :ok
      end
    end)
  end

  defp apply_carcass_decay do
    rate = Config.carcass_decay()
    if rate > 0 do
      :ets.foldl(
        fn {key, cell}, _acc ->
          if cell.carcass > 0 do
            :ets.insert(:cells, {key, Cell.decay_carcass(cell, rate)})
          end
          nil
        end,
        nil,
        :cells
      )
    end
  end

  defp sum_cell_field(field) do
    :ets.foldl(
      fn {_key, cell}, acc -> acc + Map.get(cell, field, 0) end,
      0,
      :cells
    )
  end

  defp maybe_schedule_tick(%{tick_interval_ms: 0} = state), do: state
  defp maybe_schedule_tick(%{tick_interval_ms: nil} = state), do: state

  defp maybe_schedule_tick(state) do
    ref = Process.send_after(self(), :tick, state.tick_interval_ms)
    %{state | tick_ref: ref}
  end
end
```

- [ ] **Step 7.4: Eseguire (deve passare per `init` e `snapshot_stats`)**

Run:
```bash
mix test test/lenies/world_test.exs
```
Expected: PASS, 2 test.

**Nota**: il test richiede `Phoenix.PubSub` come `Lenies.PubSub` in supervisione, che phx.new ha già messo nell'`Application`. Se il test fallisce su Phoenix.PubSub, verificare che `lib/lenies/application.ex` contenga già `{Phoenix.PubSub, name: Lenies.PubSub}` (generato da phx.new).

- [ ] **Step 7.5: Commit**

```bash
git add lib/lenies/world.ex test/lenies/world_test.exs
git commit -m "feat: add World GenServer with grid init and snapshot_stats"
```

---

## Task 8: World — radiazione e tick

**Files:**
- Modify: `test/lenies/world_test.exs`

- [ ] **Step 8.1: Aggiungere test radiazione**

Append to `test/lenies/world_test.exs` (dentro il modulo):
```elixir
  test "tick_now/0 applies radiation to cells" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)
    stats_before = World.snapshot_stats()
    assert stats_before.total_resource == 0

    World.tick_now()
    stats_after = World.snapshot_stats()
    assert stats_after.total_resource == 100  # radiation_per_tick default
    assert stats_after.tick_count == 1
  end

  test "tick_now/0 caps total resource at grid_size × cell_resource_cap" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)
    max_total = 65_536 * 100

    # 1000 tick → 100_000 unità versate (ben sotto il cap globale)
    for _ <- 1..1000, do: World.tick_now()

    stats = World.snapshot_stats()
    assert stats.total_resource <= max_total
    assert stats.tick_count == 1000
  end

  test "auto-tick fires at the configured interval" do
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
    {:ok, _pid} = World.start_link(tick_interval_ms: 50)

    assert_receive {:tick, 1}, 500
    assert_receive {:tick, 2}, 500
  end
```

- [ ] **Step 8.2: Eseguire (devono passare)**

Run:
```bash
mix test test/lenies/world_test.exs
```
Expected: PASS, 5 test totali. Se "auto-tick" fallisce per timeout, verificare che lo scheduling sia attivo (`maybe_schedule_tick` nel codice del Task 7).

- [ ] **Step 8.3: Commit**

```bash
git add test/lenies/world_test.exs
git commit -m "test: cover radiation tick and auto-tick scheduling in World"
```

---

## Task 9: World — carcasse decay

**Files:**
- Modify: `test/lenies/world_test.exs`

- [ ] **Step 9.1: Test carcass decay**

Append to `test/lenies/world_test.exs`:
```elixir
  test "tick_now/0 decays carcasses by configured rate" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    # iniettiamo una carcassa manualmente in una cella
    [{key, cell}] = :ets.lookup(:cells, {10, 10})
    :ets.insert(:cells, {key, %{cell | carcass: 100}})

    World.tick_now()

    [{_, after_cell}] = :ets.lookup(:cells, {10, 10})
    # 5% decay → 100 → 95
    assert after_cell.carcass == 95
  end

  test "tick_now/0 floors carcass at 0 over many ticks" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | carcass: 10}})

    for _ <- 1..200, do: World.tick_now()

    [{_, after_cell}] = :ets.lookup(:cells, {5, 5})
    assert after_cell.carcass == 0
  end
```

- [ ] **Step 9.2: Eseguire (devono passare)**

Run:
```bash
mix test test/lenies/world_test.exs
```
Expected: PASS, 7 test totali.

- [ ] **Step 9.3: Commit**

```bash
git add test/lenies/world_test.exs
git commit -m "test: cover carcass decay in World tick"
```

---

## Task 10: Telemetry GenServer

**Files:**
- Create: `lib/lenies/telemetry.ex`
- Test: `test/lenies/telemetry_test.exs`

- [ ] **Step 10.1: Test Telemetry**

Create `test/lenies/telemetry_test.exs`:
```elixir
defmodule Lenies.TelemetryTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  test "records a history entry on each world tick" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    {:ok, _tel} = Lenies.Telemetry.start_link([])

    World.tick_now()
    World.tick_now()
    World.tick_now()

    # tempo di propagazione del PubSub
    Process.sleep(50)

    entries = Lenies.Telemetry.history(:last_n, 10)
    assert length(entries) == 3

    for e <- entries do
      assert is_integer(e.tick)
      assert is_integer(e.population)
      assert is_number(e.total_resource)
      assert is_integer(e.timestamp_ms)
    end
  end

  test "ring buffer keeps at most max_entries" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    {:ok, _tel} = Lenies.Telemetry.start_link(max_entries: 5)

    for _ <- 1..20, do: World.tick_now()
    Process.sleep(100)

    entries = Lenies.Telemetry.history(:all)
    assert length(entries) == 5

    # gli ultimi 5 tick: 16, 17, 18, 19, 20
    ticks = Enum.map(entries, & &1.tick) |> Enum.sort()
    assert ticks == [16, 17, 18, 19, 20]
  end
end
```

- [ ] **Step 10.2: Eseguire (deve fallire)**

Run:
```bash
mix test test/lenies/telemetry_test.exs
```
Expected: FAIL — `Lenies.Telemetry` non esiste.

- [ ] **Step 10.3: Implementare Telemetry**

Create `lib/lenies/telemetry.ex`:
```elixir
defmodule Lenies.Telemetry do
  @moduledoc """
  Raccoglie eventi di tick dal World e mantiene un ring buffer in ETS (`:history`).

  Sottoscrive `"world:tick"` via Phoenix.PubSub; ad ogni `{:tick, n}` calcola
  uno snapshot aggregato e lo memorizza. Sponsorizza la GUI futura (sotto-progetto 5).
  """

  use GenServer

  alias Lenies.World

  @name __MODULE__
  @default_max_entries 10_000

  # ----- Public API -----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def history(:all) do
    :ets.tab2list(:history)
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.sort_by(& &1.tick)
  end

  def history(:last_n, n) when is_integer(n) and n > 0 do
    history(:all) |> Enum.take(-n)
  end

  # ----- Server -----

  @impl true
  def init(opts) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
    {:ok, %{max_entries: max_entries, counter: 0}}
  end

  @impl true
  def handle_info({:tick, tick_n}, state) do
    stats = World.snapshot_stats()

    entry = %{
      tick: tick_n,
      population: stats.population,
      total_resource: stats.total_resource,
      total_carcass: stats.total_carcass,
      cells: stats.cells,
      timestamp_ms: System.system_time(:millisecond)
    }

    :ets.insert(:history, {state.counter, entry})
    state = %{state | counter: state.counter + 1}
    state = enforce_ring_buffer(state)
    {:noreply, state}
  end

  def handle_info({:sterilized, _ts}, state) do
    :ets.delete_all_objects(:history)
    {:noreply, %{state | counter: 0}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp enforce_ring_buffer(state) do
    current_size = :ets.info(:history, :size)

    if current_size > state.max_entries do
      # rimuovi le entry più vecchie (counter più basso)
      to_remove = current_size - state.max_entries

      :ets.tab2list(:history)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.take(to_remove)
      |> Enum.each(fn {k, _} -> :ets.delete(:history, k) end)
    end

    state
  end
end
```

- [ ] **Step 10.4: Eseguire (deve passare)**

Run:
```bash
mix test test/lenies/telemetry_test.exs
```
Expected: PASS, 2 test.

- [ ] **Step 10.5: Commit**

```bash
git add lib/lenies/telemetry.ex test/lenies/telemetry_test.exs
git commit -m "feat: add Telemetry GenServer with ring buffer on history ETS"
```

---

## Task 11: DynamicSupervisor placeholder per i Lenies

**Files:**
- Create: `lib/lenies/lenie_supervisor.ex`
- Test: `test/lenies/lenie_supervisor_test.exs`

- [ ] **Step 11.1: Test LenieSupervisor**

Create `test/lenies/lenie_supervisor_test.exs`:
```elixir
defmodule Lenies.LenieSupervisorTest do
  use ExUnit.Case, async: false

  alias Lenies.LenieSupervisor

  setup do
    on_exit(fn ->
      case Process.whereis(LenieSupervisor) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end
    end)
    :ok
  end

  test "starts as DynamicSupervisor with restart: :temporary policy" do
    {:ok, pid} = LenieSupervisor.start_link([])
    assert Process.alive?(pid)
    assert Process.whereis(LenieSupervisor) == pid

    %{strategy: :one_for_one} = :sys.get_state(pid) |> elem(0) |> Map.from_struct()
    # Verifica più semplice: nessun figlio iniziale
    assert DynamicSupervisor.count_children(LenieSupervisor) == %{
             active: 0,
             specs: 0,
             supervisors: 0,
             workers: 0
           }
  end
end
```

- [ ] **Step 11.2: Eseguire (deve fallire)**

Run:
```bash
mix test test/lenies/lenie_supervisor_test.exs
```
Expected: FAIL.

- [ ] **Step 11.3: Implementare LenieSupervisor**

Create `lib/lenies/lenie_supervisor.ex`:
```elixir
defmodule Lenies.LenieSupervisor do
  @moduledoc """
  DynamicSupervisor che ospita tutti i processi Lenie.

  Policy `:temporary`: un Lenie che muore (per esaurimento energia o errore)
  non viene riavviato — è una morte definitiva. La replicazione (sotto-progetto 3)
  userà `DynamicSupervisor.start_child/2` per spawnare nuovi Lenies.

  Vuoto in questo sotto-progetto; pronto per essere popolato dal sotto-progetto 2.
  """

  use DynamicSupervisor

  @name __MODULE__

  def start_link(_init_arg) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: @name)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
```

- [ ] **Step 11.4: Sostituire il test con una versione semplificata**

Replace contents of `test/lenies/lenie_supervisor_test.exs`:
```elixir
defmodule Lenies.LenieSupervisorTest do
  use ExUnit.Case, async: false

  alias Lenies.LenieSupervisor

  setup do
    on_exit(fn ->
      case Process.whereis(LenieSupervisor) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: Supervisor.stop(pid)
      end
    end)
    :ok
  end

  test "starts as DynamicSupervisor with zero children" do
    {:ok, pid} = LenieSupervisor.start_link([])
    assert Process.alive?(pid)
    assert Process.whereis(LenieSupervisor) == pid
    assert DynamicSupervisor.count_children(LenieSupervisor) == %{
             active: 0,
             specs: 0,
             supervisors: 0,
             workers: 0
           }
  end
end
```

- [ ] **Step 11.5: Eseguire (deve passare)**

Run:
```bash
mix test test/lenies/lenie_supervisor_test.exs
```
Expected: PASS, 1 test.

- [ ] **Step 11.6: Commit**

```bash
git add lib/lenies/lenie_supervisor.ex test/lenies/lenie_supervisor_test.exs
git commit -m "feat: add empty LenieSupervisor (DynamicSupervisor) ready for Lenies"
```

---

## Task 12: Aggiornare l'albero di supervisione dell'Application

**Files:**
- Modify: `lib/lenies/application.ex`

- [ ] **Step 12.1: Leggere lo stato attuale**

Run:
```bash
cat lib/lenies/application.ex
```
Annotare: il file generato da phx.new contiene già `Lenies.PubSub` e `LeniesWeb.Endpoint` nei `children`. Vanno aggiunti World, LenieSupervisor, Telemetry.

- [ ] **Step 12.2: Modificare l'Application**

Modify `lib/lenies/application.ex` — la lista `children` deve diventare:
```elixir
defmodule Lenies.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LeniesWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:lenies, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Lenies.PubSub},
      Lenies.LenieSupervisor,
      Lenies.World,
      Lenies.Telemetry,
      LeniesWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Lenies.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    LeniesWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

**Importante**:
- Mantenere `LeniesWeb.Telemetry` (è il telemetry HTTP di Phoenix, distinto dal nostro `Lenies.Telemetry`)
- `Lenies.LenieSupervisor` viene prima di `Lenies.World` per essere disponibile quando il World vorrà spawnare Lenies in futuro
- `Lenies.Telemetry` viene dopo `Lenies.World` per potersi sottoscrivere al PubSub e ricevere subito gli eventi

- [ ] **Step 12.3: Verificare che l'app si avvii**

Run:
```bash
mix compile
mix run --no-start -e "Application.ensure_all_started(:lenies); :timer.sleep(200); IO.inspect(Lenies.World.snapshot_stats())"
```

Expected: stampa una mappa con `cells: 65536`, `population: 0`, `total_resource: ~200..400` (dopo 2-4 tick a 100ms).

- [ ] **Step 12.4: Verificare che tutti i test passino**

Run:
```bash
mix test
```

Expected: tutti i test passano. Se test legacy di phx.new falliscono, verificare che `LeniesWeb.PageController` test esiste e funziona.

- [ ] **Step 12.5: Commit**

```bash
git add lib/lenies/application.ex
git commit -m "feat: wire World, LenieSupervisor, Telemetry into supervision tree"
```

---

## Task 13: Sterilize end-to-end

**Files:**
- Create: `test/lenies/sterilize_test.exs`

- [ ] **Step 13.1: Test sterilize**

Create `test/lenies/sterilize_test.exs`:
```elixir
defmodule Lenies.SterilizeTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    # Lo standalone start non passa per l'Application — pulizia esplicita
    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  test "sterilize/0 clears all ETS data, resets tick_count, broadcasts event" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)

    for _ <- 1..10, do: World.tick_now()
    before_stats = World.snapshot_stats()
    assert before_stats.tick_count == 10
    assert before_stats.total_resource > 0

    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
    :ok = World.sterilize()

    assert_receive {:sterilized, _ts}, 500

    after_stats = World.snapshot_stats()
    assert after_stats.tick_count == 0
    assert after_stats.total_resource == 0
    assert after_stats.cells == 65_536
  end

  test "sterilize/0 is idempotent" do
    {:ok, _pid} = World.start_link(tick_interval_ms: 0)
    assert :ok = World.sterilize()
    assert :ok = World.sterilize()
    assert World.snapshot_stats().tick_count == 0
  end
end
```

- [ ] **Step 13.2: Eseguire (devono passare)**

Run:
```bash
mix test test/lenies/sterilize_test.exs
```
Expected: PASS, 2 test.

- [ ] **Step 13.3: Commit**

```bash
git add test/lenies/sterilize_test.exs
git commit -m "test: cover World.sterilize end-to-end with broadcast"
```

---

## Task 14: Verifica end-to-end manuale + commit del baseline

**Files:**
- nessuno (verifica solo)

- [ ] **Step 14.1: Avviare il server e verificare in console**

Run:
```bash
iex -S mix phx.server
```

Nella shell `iex`:
```elixir
Lenies.World.snapshot_stats()
# %{cells: 65536, population: 0, total_carcass: 0, total_resource: ~N, tick_count: ~M}
# N e M crescono col passare del tempo

Process.sleep(2000)
Lenies.World.snapshot_stats()
# tick_count ≈ 20, total_resource crescuto

Lenies.Telemetry.history(:last_n, 5)
# 5 entry, una per tick recente

Lenies.World.sterilize()
# :ok, broadcast :sterilized
Lenies.World.snapshot_stats()
# tick_count: 0, total_resource: 0
```

Verificare manualmente: tutti i comportamenti sopra. Annotare eventuali sorprese.

Premere `Ctrl+C` due volte per uscire.

- [ ] **Step 14.2: Test suite completa**

Run:
```bash
mix test
```
Expected: tutti i test passano (probabilmente ~20+ test totali).

- [ ] **Step 14.3: Verifica formattazione**

Run:
```bash
mix format --check-formatted
```
Expected: PASS. Se fallisce: `mix format` e poi `git add -u && git commit -m "chore: format"`.

- [ ] **Step 14.4: Verifica dialyzer (opzionale ma raccomandato)**

Aggiungere a `mix.exs` dentro `deps`:
```elixir
{:dialyxir, "~> 1.4", only: [:dev], runtime: false},
```

Run:
```bash
mix deps.get
mix dialyzer
```
Se troppe complicazioni dialyzer, skip e commentare nel commit.

- [ ] **Step 14.5: Commit finale baseline**

Run:
```bash
git status   # deve essere pulito
git log --oneline
```

Expected: ≥13 commit con storia chiara. Working tree pulito.

```bash
git tag v0.1.0-core-runtime
```

---

## Self-Review checklist

**Spec coverage:**
- [x] §3.1 supervisione: Application + World + Registry (assente — Registry per Lenies viene in sotto-progetto 2, OK) + LenieSupervisor (vuoto) + Telemetry + Endpoint → Task 12
- [x] §3.2 ETS: `:cells`, `:lenies`, `:child_slots`, `:history` → Task 4
- [x] §3.3 PubSub: `"world:tick"` broadcast → Task 7
- [x] §6.1 griglia 256×256 toroidale + Cell struct → Task 3, Task 7
- [x] §6.2 radiazione uniforme + hotspot mobili + cap cella → Task 5, Task 6, Task 7-8
- [x] §6.3 carcasse + decay → Task 3, Task 9
- [x] §8 Telemetry ring buffer → Task 10
- [x] §9 sterilize → Task 7 (impl) + Task 13 (test)
- [x] §10 config parameters → Task 2

**Non coperto qui (rinviato a sotto-progetti successivi)**:
- `Lenies.Registry` per lookup id↔pid — sotto-progetto 2 (con i Lenies)
- Interprete, Lenie process, opcode — sotto-progetto 2
- Replicazione, errori di copia, Mutator — sotto-progetto 3
- Predazione — sotto-progetto 4
- LiveView dashboard — sotto-progetto 5
- Inspector/Specie views — sotto-progetto 6
- Tuning live + Seeds → sotto-progetto 7

**Placeholder scan**: nessun "TBD"/"TODO"/"implement later"/"similar to" trovato.

**Type consistency**:
- `%Cell{lenie_id, resource, carcass}` consistente in Task 3, 7-9
- `World.snapshot_stats()` ritorna mappa con `:cells, :population, :total_resource, :total_carcass, :tick_count` consistente in Task 7-9, 13
- `Telemetry.history/1` e `/2` con clausole `:all` e `:last_n, n` consistente

**Ambiguità note risolte**: nessuna ambiguità residua per questo sotto-progetto.
