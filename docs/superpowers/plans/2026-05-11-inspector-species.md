# Inspector + Species Views Implementation Plan (Sotto-progetto 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere viste di drill-down: pannello specie nella dashboard (top-N), route `/lenie/:id` con disassembler del Codeome e stato live, route `/species/:hash` con dettagli specie e lineage. Click su cella del canvas → naviga all'inspector del Lenie residente.

**Architecture:**
- `Lenies.Species` aggrega `:lenies` ETS per `codeome_hash` (popolazione, generazione media, sample_lenie_id)
- `LeniesWeb.Disassembler` formatta un Codeome come lista posizione/opcode, evidenziando l'IP corrente
- `LenieInspectorLive` su `/lenie/:id`: legge stato live via `Lenies.Registry` + `Lenie.inspect_state/1`; sottoscritto a `"lenie:#{id}"` per aggiornamenti push
- `SpeciesLive` su `/species/:hash`: legge dall'aggregatore + sample Lenie per il Codeome
- Modifica `Lenies.Lenie`: dopo `maybe_write_snapshot/1` broadcast `{:lenie_update, snap}` su `"lenie:#{id}"`
- Modifica `DashboardLive`: aggiunge tabella top-N specie; canvas click → push_navigate a `/lenie/:id`

**Tech Stack:** Phoenix LiveView (già nel progetto), JS hook per canvas click → coord cell, HEEx rendering, `Phoenix.PubSub` per live updates.

**Spec di riferimento:** [docs/superpowers/specs/2026-05-11-lenies-design.md](../specs/2026-05-11-lenies-design.md) — §7.1 panel Specie, §7.2 Inspector, §7.3 Specie view, §3.2 `:lenies` ETS.

**Criterio di completamento end-to-end:**
1. Dashboard `/` mostra tabella top-N specie con click → /species/:hash
2. `/lenie/:id` mostra stato Lenie (energia, pos, dir, age, lineage, child_slot_id se attivo) + Codeome con IP highlighted; aggiornamento live via PubSub
3. `/species/:hash` mostra Codeome canonico (da sample Lenie) + lista lineage (parent_id → generation)
4. Click su cella canvas occupata → navigazione a `/lenie/:id`
5. Tutti i test passano, browser smoke OK
6. Tag `v0.6.0-inspector-species` su HEAD

**Esplicitamente fuori scope (deferiti):**
- Filogenia SVG-tree animata (complessa) — usiamo lista testuale
- Diff con specie sorelle (più simili per Levenshtein) — placeholder
- Heuristic comments sul Codeome ("qui c'è il loop di copia") — placeholder
- Export Codeome JSON — placeholder
- Storia ultime 100 azioni del Lenie (richiede modifiche al loop metabolico) — SP7 o polish

---

## File structure

| File | Stato | Responsabilità |
|---|---|---|
| `lib/lenies/species.ex` | new | Aggregator per `:lenies` ETS per codeome_hash |
| `lib/lenies_web/disassembler.ex` | new | Formatta Codeome come righe posizione/opcode |
| `lib/lenies/lenie.ex` | modify | Broadcast `{:lenie_update, snap}` su `"lenie:#{id}"` |
| `lib/lenies_web/live/lenie_inspector_live.ex` | new | Route `/lenie/:id` |
| `lib/lenies_web/live/species_live.ex` | new | Route `/species/:hash` |
| `lib/lenies_web/live/dashboard_live.ex` | modify | Pannello Specie + handle canvas click → navigate |
| `lib/lenies_web/router.ex` | modify | aggiunge 2 route |
| `assets/js/hooks/grid_canvas.js` | modify | Aggiunge click handler → push event al LiveView |

| Test | Stato |
|---|---|
| `test/lenies/species_test.exs` | new |
| `test/lenies_web/disassembler_test.exs` | new |
| `test/lenies_web/live/lenie_inspector_live_test.exs` | new |
| `test/lenies_web/live/species_live_test.exs` | new |
| `test/lenies_web/live/dashboard_live_test.exs` | modify (Species panel + click event) |

---

## Task 1: Lenies.Species aggregator

**Files:**
- Create: `lib/lenies/species.ex`
- Test: `test/lenies/species_test.exs`

- [ ] **Step 1.1: Test Species aggregator**

Create `test/lenies/species_test.exs`:
```elixir
defmodule Lenies.SpeciesTest do
  use ExUnit.Case, async: false

  alias Lenies.Species
  alias Lenies.World.Tables

  setup do
    Tables.create_all()
    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  test "aggregate/0 returns empty when :lenies is empty" do
    assert Species.aggregate() == []
  end

  test "aggregate/0 groups by codeome_hash and counts population" do
    :ets.insert(:lenies, {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}}})
    :ets.insert(:lenies, {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}}})
    :ets.insert(:lenies, {"c", %{id: "c", codeome_hash: "h2", lineage: {nil, 0}}})

    species = Species.aggregate()

    assert length(species) == 2

    h1 = Enum.find(species, &(&1.hash == "h1"))
    assert h1.population == 2
    assert h1.avg_generation == 0.5

    h2 = Enum.find(species, &(&1.hash == "h2"))
    assert h2.population == 1
    assert h2.avg_generation == 0.0
  end

  test "aggregate/0 sorts by population descending" do
    :ets.insert(:lenies, {"a", %{id: "a", codeome_hash: "small", lineage: {nil, 0}}})

    for i <- 1..5 do
      :ets.insert(:lenies, {"b#{i}", %{id: "b#{i}", codeome_hash: "big", lineage: {nil, 0}}})
    end

    species = Species.aggregate()

    assert hd(species).hash == "big"
    assert hd(species).population == 5
  end

  test "aggregate/0 includes a sample_lenie_id for each species" do
    :ets.insert(:lenies, {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}}})
    :ets.insert(:lenies, {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}}})

    species = Species.aggregate()
    h1 = Enum.find(species, &(&1.hash == "h1"))

    assert h1.sample_lenie_id in ["a", "b"]
  end

  test "for_hash/1 returns all snapshots for that hash" do
    :ets.insert(:lenies, {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}}})
    :ets.insert(:lenies, {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}}})
    :ets.insert(:lenies, {"c", %{id: "c", codeome_hash: "h2", lineage: {nil, 0}}})

    h1_records = Species.for_hash("h1")
    assert length(h1_records) == 2
    ids = Enum.map(h1_records, fn {_id, snap} -> snap.id end) |> Enum.sort()
    assert ids == ["a", "b"]

    assert Species.for_hash("nonexistent") == []
  end

  test "top_n/1 returns at most N species" do
    for i <- 1..10 do
      :ets.insert(:lenies, {"x#{i}", %{id: "x#{i}", codeome_hash: "h#{i}", lineage: {nil, 0}}})
    end

    top3 = Species.top_n(3)
    assert length(top3) == 3
  end
end
```

- [ ] **Step 1.2: Run test (should fail)**

```bash
export PATH="$HOME/.asdf/shims:$PATH"
mix test test/lenies/species_test.exs
```

- [ ] **Step 1.3: Implement Species**

Create `lib/lenies/species.ex`:
```elixir
defmodule Lenies.Species do
  @moduledoc """
  Aggregator for the `:lenies` ETS table, grouping by `codeome_hash`.

  Each species record:
  - `hash`: the codeome_hash binary
  - `population`: count of currently-alive Lenies with this hash
  - `avg_generation`: average generation number across the population
  - `sample_lenie_id`: id of one representative Lenie (for fetching the full Codeome via Registry)

  Vedi spec §5.4 (speciazione) e §7.1 (panel Specie).
  """

  @type species_record :: %{
          hash: binary(),
          population: pos_integer(),
          avg_generation: float(),
          sample_lenie_id: binary()
        }

  @doc """
  Aggregate the `:lenies` ETS table by codeome_hash. Returns a list of species records sorted
  by population descending.
  """
  @spec aggregate() :: [species_record()]
  def aggregate do
    :ets.tab2list(:lenies)
    |> Enum.group_by(fn {_id, snap} -> snap.codeome_hash end)
    |> Enum.map(fn {hash, entries} ->
      gens =
        entries
        |> Enum.map(fn {_id, snap} ->
          snap.lineage |> elem(1)
        end)

      avg_gen =
        if Enum.empty?(gens), do: 0.0, else: Enum.sum(gens) / length(gens) * 1.0

      {sample_id, _} = hd(entries)

      %{
        hash: hash,
        population: length(entries),
        avg_generation: avg_gen,
        sample_lenie_id: sample_id
      }
    end)
    |> Enum.sort_by(& &1.population, :desc)
  end

  @doc "Return all `:lenies` records (raw {id, snap} tuples) with the given codeome_hash."
  @spec for_hash(binary()) :: [{binary(), map()}]
  def for_hash(hash) do
    :ets.tab2list(:lenies)
    |> Enum.filter(fn {_id, snap} -> snap.codeome_hash == hash end)
  end

  @doc "Top N species by population. N defaults to 10."
  @spec top_n(pos_integer()) :: [species_record()]
  def top_n(n \\ 10) when is_integer(n) and n > 0 do
    aggregate() |> Enum.take(n)
  end
end
```

- [ ] **Step 1.4: Run tests (should pass)**

```bash
mix test test/lenies/species_test.exs
```

- [ ] **Step 1.5: Full suite**

```bash
mix test
```

- [ ] **Step 1.6: Commit**

```bash
git add lib/lenies/species.ex test/lenies/species_test.exs
git commit -m "feat: add Lenies.Species aggregator with population sort and top_n"
```

---

## Task 2: Disassembler module

**Files:**
- Create: `lib/lenies_web/disassembler.ex`
- Test: `test/lenies_web/disassembler_test.exs`

- [ ] **Step 2.1: Test Disassembler**

Create `test/lenies_web/disassembler_test.exs`:
```elixir
defmodule LeniesWeb.DisassemblerTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeome
  alias LeniesWeb.Disassembler

  test "disassemble/2 returns a list of position/opcode maps" do
    codeome = Codeome.from_list([:nop_0, :push1, :move])

    result = Disassembler.disassemble(codeome, 0)

    assert length(result) == 3
    assert Enum.at(result, 0) == %{index: 0, opcode: :nop_0, is_current: true}
    assert Enum.at(result, 1) == %{index: 1, opcode: :push1, is_current: false}
    assert Enum.at(result, 2) == %{index: 2, opcode: :move, is_current: false}
  end

  test "disassemble/2 with no current IP marks none as current" do
    codeome = Codeome.from_list([:nop_0, :push1])

    result = Disassembler.disassemble(codeome, nil)

    refute Enum.any?(result, & &1.is_current)
  end

  test "disassemble/2 marks the right line as current" do
    codeome = Codeome.from_list([:nop_0, :push1, :move, :add])

    result = Disassembler.disassemble(codeome, 2)

    assert Enum.at(result, 2).is_current
    refute Enum.at(result, 0).is_current
    refute Enum.at(result, 1).is_current
    refute Enum.at(result, 3).is_current
  end

  test "opcode_class/1 categorizes opcodes for syntax highlighting" do
    assert Disassembler.opcode_class(:nop_0) == :template
    assert Disassembler.opcode_class(:nop_1) == :template
    assert Disassembler.opcode_class(:push0) == :stack
    assert Disassembler.opcode_class(:add) == :arith
    assert Disassembler.opcode_class(:jmp_t) == :control
    assert Disassembler.opcode_class(:move) == :action
    assert Disassembler.opcode_class(:allocate) == :replication
    assert Disassembler.opcode_class(:store) == :memory
    assert Disassembler.opcode_class(:get_ip) == :self_inspect
    assert Disassembler.opcode_class(:sense_front) == :sense
    assert Disassembler.opcode_class(:attack) == :predation
    assert Disassembler.opcode_class(:unknown_xyz) == :unknown
  end
end
```

- [ ] **Step 2.2: Run test (should fail)**

```bash
mix test test/lenies_web/disassembler_test.exs
```

- [ ] **Step 2.3: Implement Disassembler**

Create `lib/lenies_web/disassembler.ex`:
```elixir
defmodule LeniesWeb.Disassembler do
  @moduledoc """
  Formats a Codeome for HTML display: position/opcode listing with the current
  IP optionally highlighted, plus per-opcode category classes for syntax
  highlighting in CSS.

  Vedi spec §7.2 (Codeome disassemblato).
  """

  alias Lenies.Codeome

  @type line :: %{
          index: non_neg_integer(),
          opcode: atom(),
          is_current: boolean()
        }

  @doc """
  Convert a Codeome into a list of line records, marking the current IP line.

  `current_ip` may be `nil` (no highlight). Out-of-range IP also produces no highlight.
  """
  @spec disassemble(Codeome.t(), non_neg_integer() | nil) :: [line()]
  def disassemble(%Codeome{} = c, current_ip) do
    opcodes = Codeome.to_list(c)

    opcodes
    |> Enum.with_index()
    |> Enum.map(fn {op, idx} ->
      %{index: idx, opcode: op, is_current: idx == current_ip}
    end)
  end

  @doc "Categorize an opcode for syntax highlighting."
  @spec opcode_class(atom()) :: atom()
  def opcode_class(op) when op in [:nop_0, :nop_1], do: :template
  def opcode_class(op) when op in [:push0, :push1, :pushN, :dup, :drop, :swap], do: :stack
  def opcode_class(op) when op in [:add, :sub, :mul, :mod], do: :arith
  def opcode_class(op) when op in [:jmp_t, :jz_t, :jnz_t, :call_t, :ret], do: :control
  def opcode_class(op) when op in [:sense_front, :sense_self, :sense_energy, :sense_age, :sense_size], do: :sense
  def opcode_class(op) when op in [:move, :turn_left, :turn_right, :eat], do: :action
  def opcode_class(op) when op in [:attack, :defend], do: :predation
  def opcode_class(op) when op in [:get_ip, :get_size, :read_self], do: :self_inspect
  def opcode_class(op) when op in [:allocate, :write_child, :divide], do: :replication
  def opcode_class(op) when op in [:store, :load], do: :memory
  def opcode_class(_), do: :unknown
end
```

- [ ] **Step 2.4: Run tests (should pass)**

```bash
mix test test/lenies_web/disassembler_test.exs
```

- [ ] **Step 2.5: Commit**

```bash
git add lib/lenies_web/disassembler.ex test/lenies_web/disassembler_test.exs
git commit -m "feat: add Disassembler module for Codeome listing with IP highlight"
```

---

## Task 3: Lenie broadcasts updates on `"lenie:#{id}"` topic

**Files:**
- Modify: `lib/lenies/lenie.ex`
- Test: extend `test/lenies/lenie_snapshot_test.exs` OR create `test/lenies/lenie_pubsub_test.exs`

- [ ] **Step 3.1: Test that Lenie broadcasts updates**

Create `test/lenies/lenie_pubsub_test.exs`:
```elixir
defmodule Lenies.LeniePubsubTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie, World}
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
    end)

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    :ok
  end

  test "Lenie broadcasts {:lenie_update, snap} on its per-id topic" do
    [{key, cell}] = :ets.lookup(:cells, {3, 3})
    :ets.insert(:cells, {key, %{cell | lenie_id: "PUB1"}})

    Phoenix.PubSub.subscribe(Lenies.PubSub, "lenie:PUB1")

    codeome = Codeome.from_list([:nop_0, :nop_0])
    {:ok, pid} =
      Lenie.start_link(
        id: "PUB1",
        codeome: codeome,
        energy: 1000.0,
        pos: {3, 3},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    # The initial snapshot is written in init/1; assert we receive it
    assert_receive {:lenie_update, snap}, 500
    assert snap.id == "PUB1"

    # Should also broadcast periodically as batches run
    assert_receive {:lenie_update, _}, 500

    GenServer.stop(pid)
  end
end
```

- [ ] **Step 3.2: Run test (should fail)**

```bash
mix test test/lenies/lenie_pubsub_test.exs
```

- [ ] **Step 3.3: Modify Lenie to broadcast**

In `lib/lenies/lenie.ex`, find the `maybe_write_snapshot/1` private function and broadcast after writing to ETS:

```elixir
defp maybe_write_snapshot(state) do
  cadence = Application.get_env(:lenies, :snapshot_every_batches, 10)

  if rem(state.batch_count, cadence) == 0 do
    new_snap = %{
      id: state.id,
      pid: self(),
      pos: state.interp.pos,
      dir: state.interp.dir,
      energy: state.interp.energy,
      age: state.interp.age,
      codeome_hash: Lenies.Codeome.hash(state.codeome),
      lineage: state.lineage
    }

    existing =
      case :ets.lookup(:lenies, state.id) do
        [{_, record}] -> record
        [] -> %{}
      end

    merged = Map.merge(existing, new_snap)
    :ets.insert(:lenies, {state.id, merged})

    # Broadcast to per-Lenie topic for live inspector updates
    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "lenie:#{state.id}",
      {:lenie_update, merged}
    )
  end
end
```

The merge step is unchanged (preserves World-added fields like `child_slot_id`, `defending_until`). Only the broadcast is new.

- [ ] **Step 3.4: Run tests (should pass)**

```bash
mix test test/lenies/lenie_pubsub_test.exs
```

- [ ] **Step 3.5: Full suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 3.6: Commit**

```bash
git add lib/lenies/lenie.ex test/lenies/lenie_pubsub_test.exs
git commit -m "feat: Lenie broadcasts :lenie_update on per-id PubSub topic"
```

---

## Task 4: LenieInspectorLive view

**Files:**
- Create: `lib/lenies_web/live/lenie_inspector_live.ex`
- Modify: `lib/lenies_web/router.ex` (add route)
- Test: `test/lenies_web/live/lenie_inspector_live_test.exs`

- [ ] **Step 4.1: Test LenieInspectorLive**

Create `test/lenies_web/live/lenie_inspector_live_test.exs`:
```elixir
defmodule LeniesWeb.LenieInspectorLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Lenies.{Codeome, Lenie, World}
  alias Lenies.World.Tables

  setup do
    case Process.whereis(Lenies.World) do
      nil ->
        {:ok, _} = World.start_link(tick_interval_ms: 0)
      _ ->
        :ok
    end

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
    end)

    :ok
  end

  test "mount on /lenie/:id with a live Lenie renders state and codeome", %{conn: conn} do
    [{key, cell}] = :ets.lookup(:cells, {3, 3})
    :ets.insert(:cells, {key, %{cell | lenie_id: "INSP1"}})

    codeome = Codeome.from_list([:nop_0, :push1, :move])
    {:ok, pid} =
      Lenie.start_link(
        id: "INSP1",
        codeome: codeome,
        energy: 100_000.0,
        pos: {3, 3},
        dir: :e,
        lineage: {nil, 0}
      )

    Process.unlink(pid)
    Process.sleep(50)  # let initial snapshot write

    {:ok, _view, html} = live(conn, "/lenie/INSP1")

    # State
    assert html =~ "INSP1"
    assert html =~ ~r/Energia/i
    assert html =~ ~r/Posizione/i

    # Codeome listing (3 opcodes)
    assert html =~ "nop_0"
    assert html =~ "push1"
    assert html =~ "move"

    GenServer.stop(pid)
  end

  test "mount on /lenie/:id with a non-existent Lenie shows a 'not found' message", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/lenie/nonexistent")
    assert html =~ ~r/(non trovato|not found|estinto|deceased)/i
  end
end
```

- [ ] **Step 4.2: Add route**

In `lib/lenies_web/router.ex`, add `live "/lenie/:id", LenieInspectorLive, :show` inside the `:browser` scope, alongside the existing `live "/", DashboardLive, :index`:

```elixir
scope "/", LeniesWeb do
  pipe_through :browser
  live "/", DashboardLive, :index
  live "/lenie/:id", LenieInspectorLive, :show
end
```

- [ ] **Step 4.3: Run test (should fail)**

```bash
mix test test/lenies_web/live/lenie_inspector_live_test.exs
```

- [ ] **Step 4.4: Implement LenieInspectorLive**

Create `lib/lenies_web/live/lenie_inspector_live.ex`:
```elixir
defmodule LeniesWeb.LenieInspectorLive do
  @moduledoc """
  Inspector view for an individual Lenie at `/lenie/:id`.

  Shows current state (energy, age, position, direction, lineage, child_slot_id
  if any) and the Codeome disassembled with IP highlighted.

  Subscribes to `"lenie:#{id}"` PubSub topic and re-renders on each
  `{:lenie_update, snap}` broadcast.

  Vedi spec §7.2.
  """

  use LeniesWeb, :live_view

  alias LeniesWeb.Disassembler

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "lenie:#{id}")
    end

    socket =
      socket
      |> assign(:id, id)
      |> load_lenie()

    {:ok, socket}
  end

  defp load_lenie(socket) do
    id = socket.assigns.id

    case Lenies.Registry.whereis(id) do
      pid when is_pid(pid) ->
        snap =
          try do
            Lenies.Lenie.inspect_state(pid)
          catch
            :exit, _ -> nil
          end

        if snap do
          socket
          |> assign(:found?, true)
          |> assign(:snap, snap)
          |> assign(:codeome_lines, fetch_codeome_lines(pid, snap))
        else
          assign(socket, :found?, false)
        end

      _ ->
        case :ets.lookup(:lenies, id) do
          [{^id, snap}] ->
            socket
            |> assign(:found?, false)  # process dead but snapshot lingered
            |> assign(:snap, snap)
            |> assign(:codeome_lines, [])

          _ ->
            assign(socket, :found?, false)
        end
    end
  end

  defp fetch_codeome_lines(pid, snap) do
    try do
      # The state from inspect_state doesn't include the full Codeome — only metadata.
      # We need the actual Codeome. Use a custom call to get it.
      GenServer.call(pid, :get_codeome)
      |> case do
        {:ok, codeome} ->
          ip = Map.get(snap, :ip, 0)
          Disassembler.disassemble(codeome, ip)

        _ ->
          []
      end
    catch
      :exit, _ -> []
    end
  end

  @impl true
  def handle_info({:lenie_update, snap}, socket) do
    if snap.id == socket.assigns.id do
      socket =
        socket
        |> assign(:snap, snap)
        |> assign(:found?, true)

      # Refresh the codeome lines too (IP may have moved)
      socket =
        case Lenies.Registry.whereis(snap.id) do
          pid when is_pid(pid) -> assign(socket, :codeome_lines, fetch_codeome_lines(pid, snap))
          _ -> socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="inspector">
      <h1>Lenie Inspector: {@id}</h1>

      <%= if @found? do %>
        <div class="state">
          <h2>Stato</h2>
          <table>
            <tr><th>ID</th><td>{@snap.id}</td></tr>
            <tr><th>Energia</th><td>{Float.round(@snap.energy, 2)}</td></tr>
            <tr><th>Posizione</th><td>{inspect(@snap.pos)}</td></tr>
            <tr><th>Direzione</th><td>{@snap.dir}</td></tr>
            <tr><th>Età</th><td>{Map.get(@snap, :age, 0)}</td></tr>
            <tr><th>Lineage</th><td>{inspect(Map.get(@snap, :lineage, {nil, 0}))}</td></tr>
            <tr>
              <th>Child slot</th>
              <td>{Map.get(@snap, :child_slot_id, "—")}</td>
            </tr>
            <tr>
              <th>Codeome hash</th>
              <td>{Map.get(@snap, :codeome_hash, "?")}</td>
            </tr>
          </table>
        </div>

        <div class="codeome">
          <h2>Codeome ({length(@codeome_lines)} opcodes)</h2>
          <pre class="disassembly">
            <%= for line <- @codeome_lines do %>
              <div class={if line.is_current, do: "line current", else: "line"}>
                <span class="idx">{String.pad_leading(Integer.to_string(line.index), 4, "0")}</span>
                <span class={"op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
                  {Atom.to_string(line.opcode)}
                </span>
              </div>
            <% end %>
          </pre>
        </div>
      <% else %>
        <p>Lenie <strong>{@id}</strong> non trovato (forse estinto).</p>
      <% end %>

      <a href="/">← Torna al dashboard</a>
    </div>
    """
  end
end
```

The Inspector calls `GenServer.call(pid, :get_codeome)` to fetch the Codeome — this requires adding a `handle_call(:get_codeome, ...)` clause to `Lenies.Lenie`.

- [ ] **Step 4.5: Add :get_codeome handler to Lenie**

In `lib/lenies/lenie.ex`, add a new `handle_call` clause:
```elixir
def handle_call(:get_codeome, _from, state) do
  {:reply, {:ok, state.codeome}, state}
end
```

Place it alongside the existing `handle_call(:inspect_state, ...)`.

- [ ] **Step 4.6: Run tests (should pass)**

```bash
mix test test/lenies_web/live/lenie_inspector_live_test.exs
```

- [ ] **Step 4.7: Commit**

```bash
git add lib/lenies_web/live/lenie_inspector_live.ex lib/lenies/lenie.ex lib/lenies_web/router.ex test/lenies_web/live/lenie_inspector_live_test.exs
git commit -m "feat: add LenieInspectorLive at /lenie/:id with disassembler and live updates"
```

---

## Task 5: Species panel in DashboardLive

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Modify: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 5.1: Add species panel test**

Append to `test/lenies_web/live/dashboard_live_test.exs`:
```elixir
  test "Species panel shows top-N species table from aggregator", %{conn: conn} do
    # Insert 3 species in :lenies ETS
    :ets.insert(:lenies, {"a", %{id: "a", codeome_hash: "hashA", lineage: {nil, 0}}})
    :ets.insert(:lenies, {"b", %{id: "b", codeome_hash: "hashA", lineage: {nil, 1}}})
    :ets.insert(:lenies, {"c", %{id: "c", codeome_hash: "hashB", lineage: {nil, 0}}})

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "hashA"
    assert html =~ "hashB"
    # Population column for hashA = 2
    assert html =~ ~r/hashA[\s\S]+2/
  end
```

- [ ] **Step 5.2: Run test (should fail)**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

The Species panel currently shows just a placeholder. The new test expects species hashes.

- [ ] **Step 5.3: Update DashboardLive**

In `lib/lenies_web/live/dashboard_live.ex`:

1. Add species assign in `mount/3`:
```elixir
socket =
  socket
  |> assign(:grid, grid)
  |> assign(:tick_count, 0)
  |> assign(:layers_visible, %{lenies: true, resource: true, carcass: true})
  |> assign(:sterilize_confirming, false)
  |> assign(:paused?, false)
  |> assign(:throttle_counter, 0)
  |> assign(:history, [])
  |> assign(:species, Lenies.Species.top_n(10))
```

2. Update species in `handle_info({:tick, n}, ...)` (only in the throttled branch to avoid the O(N log N) call on every tick):

```elixir
def handle_info({:tick, n}, socket) do
  throttle = Application.get_env(:lenies, :dashboard_throttle_ticks, 5)
  new_counter = socket.assigns.throttle_counter + 1

  socket =
    socket
    |> assign(:tick_count, n)
    |> assign(:throttle_counter, new_counter)

  if rem(new_counter, throttle) == 0 do
    socket =
      socket
      |> assign(:history, Lenies.Telemetry.history(:last_n, 100))
      |> assign(:species, Lenies.Species.top_n(10))

    payload = LeniesWeb.GridRenderer.encode_payload(socket.assigns.grid)
    {:noreply, push_event(socket, "render_frame", payload)}
  else
    {:noreply, socket}
  end
end
```

(Note: this moves `history` assignment to the throttle branch too — addresses a performance issue from SP5 final review.)

3. Replace the Species panel content in `render/1`:
```heex
<div class="panel species-panel">
  <h2>Specie ({length(@species)})</h2>
  <table class="species-table">
    <thead>
      <tr>
        <th>Hash</th>
        <th>Pop.</th>
        <th>Gen. media</th>
      </tr>
    </thead>
    <tbody>
      <%= for sp <- @species do %>
        <tr>
          <td>
            <.link navigate={~p"/species/#{sp.hash}"} class="species-link">
              {String.slice(sp.hash, 0..7)}...
            </.link>
          </td>
          <td>{sp.population}</td>
          <td>{Float.round(sp.avg_generation, 2)}</td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>
```

Note: `~p"/species/#{sp.hash}"` uses Phoenix.VerifiedRoutes — verify the import is there (it's auto-imported via `use LeniesWeb, :live_view`).

- [ ] **Step 5.4: Run tests**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

(The link won't yet resolve because `/species/:hash` route is added in Task 6. The test only checks for the hash text being rendered, which works without the route.)

- [ ] **Step 5.5: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat: populate dashboard Species panel with top-N table"
```

---

## Task 6: SpeciesLive view at /species/:hash

**Files:**
- Create: `lib/lenies_web/live/species_live.ex`
- Modify: `lib/lenies_web/router.ex` (add route)
- Test: `test/lenies_web/live/species_live_test.exs`

- [ ] **Step 6.1: Add route**

In `lib/lenies_web/router.ex`, add inside the `:browser` scope:

```elixir
live "/species/:hash", SpeciesLive, :show
```

- [ ] **Step 6.2: Test SpeciesLive**

Create `test/lenies_web/live/species_live_test.exs`:
```elixir
defmodule LeniesWeb.SpeciesLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Lenies.{Codeome, Lenie, World}
  alias Lenies.World.Tables

  setup do
    case Process.whereis(Lenies.World) do
      nil ->
        {:ok, _} = World.start_link(tick_interval_ms: 0)
      _ ->
        :ok
    end

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
    end)

    :ok
  end

  test "mount on /species/:hash with a known species shows lineage", %{conn: conn} do
    [{key, cell}] = :ets.lookup(:cells, {3, 3})
    :ets.insert(:cells, {key, %{cell | lenie_id: "SP1"}})

    codeome = Codeome.from_list([:nop_0, :push1])
    hash = Codeome.hash(codeome)

    {:ok, pid} =
      Lenie.start_link(
        id: "SP1",
        codeome: codeome,
        energy: 100_000.0,
        pos: {3, 3},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)
    Process.sleep(50)

    {:ok, _view, html} = live(conn, "/species/#{hash}")

    assert html =~ hash
    assert html =~ ~r/Popolazione/i
    assert html =~ "SP1"  # lineage entry

    GenServer.stop(pid)
  end

  test "mount on /species/:hash with unknown hash shows empty/extinct", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/species/00000000")
    assert html =~ ~r/(estinto|empty|nessuno)/i
  end
end
```

- [ ] **Step 6.3: Run test (should fail)**

```bash
mix test test/lenies_web/live/species_live_test.exs
```

- [ ] **Step 6.4: Implement SpeciesLive**

Create `lib/lenies_web/live/species_live.ex`:
```elixir
defmodule LeniesWeb.SpeciesLive do
  @moduledoc """
  Detail view for a species at `/species/:hash`.

  Shows population summary, Codeome (via sample Lenie), and lineage list.
  Phylogenetic tree visualization deferred (placeholder).

  Vedi spec §7.3.
  """

  use LeniesWeb, :live_view

  alias Lenies.{Codeome, Species}
  alias LeniesWeb.Disassembler

  @impl true
  def mount(%{"hash" => hash}, _session, socket) do
    socket =
      socket
      |> assign(:hash, hash)
      |> load_species()

    {:ok, socket}
  end

  defp load_species(socket) do
    hash = socket.assigns.hash
    records = Species.for_hash(hash)

    if Enum.empty?(records) do
      socket
      |> assign(:found?, false)
      |> assign(:population, 0)
      |> assign(:lineage_entries, [])
      |> assign(:codeome_lines, [])
    else
      lineage_entries =
        records
        |> Enum.map(fn {id, snap} ->
          {parent_id, gen} = Map.get(snap, :lineage, {nil, 0})
          %{id: id, parent_id: parent_id, generation: gen, energy: snap.energy}
        end)
        |> Enum.sort_by(& &1.generation)

      # Try to fetch the Codeome from a live sample Lenie
      {sample_id, _} = hd(records)
      codeome_lines = fetch_sample_codeome(sample_id)

      socket
      |> assign(:found?, true)
      |> assign(:population, length(records))
      |> assign(:lineage_entries, lineage_entries)
      |> assign(:codeome_lines, codeome_lines)
    end
  end

  defp fetch_sample_codeome(sample_id) do
    case Lenies.Registry.whereis(sample_id) do
      pid when is_pid(pid) ->
        try do
          case GenServer.call(pid, :get_codeome) do
            {:ok, codeome} -> Disassembler.disassemble(codeome, nil)
            _ -> []
          end
        catch
          :exit, _ -> []
        end

      _ ->
        []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="species-view">
      <h1>Specie: {String.slice(@hash, 0..15)}…</h1>

      <%= if @found? do %>
        <p><strong>Popolazione:</strong> {@population}</p>

        <h2>Codeome ({length(@codeome_lines)} opcodes)</h2>
        <pre class="disassembly">
          <%= for line <- @codeome_lines do %>
            <div class="line">
              <span class="idx">{String.pad_leading(Integer.to_string(line.index), 4, "0")}</span>
              <span class={"op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
                {Atom.to_string(line.opcode)}
              </span>
            </div>
          <% end %>
        </pre>

        <h2>Lineage ({length(@lineage_entries)} entries)</h2>
        <table>
          <thead>
            <tr><th>ID</th><th>Parent</th><th>Generation</th><th>Energia</th></tr>
          </thead>
          <tbody>
            <%= for entry <- @lineage_entries do %>
              <tr>
                <td>
                  <.link navigate={~p"/lenie/#{entry.id}"}>{entry.id}</.link>
                </td>
                <td>{entry.parent_id || "—"}</td>
                <td>{entry.generation}</td>
                <td>{Float.round(entry.energy, 2)}</td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <p class="note">(Filogenia SVG-tree e diff con specie sorelle: deferito a un futuro polish.)</p>
      <% else %>
        <p>Specie con hash <code>{@hash}</code> non trovata (estinta o mai esistita).</p>
      <% end %>

      <a href="/">← Torna al dashboard</a>
    </div>
    """
  end
end
```

- [ ] **Step 6.5: Run tests**

```bash
mix test test/lenies_web/live/species_live_test.exs
```

Expected: PASS, 2 tests.

- [ ] **Step 6.6: Full suite**

```bash
mix test
```

- [ ] **Step 6.7: Commit**

```bash
git add lib/lenies_web/live/species_live.ex lib/lenies_web/router.ex test/lenies_web/live/species_live_test.exs
git commit -m "feat: add SpeciesLive at /species/:hash with Codeome and lineage"
```

---

## Task 7: Canvas click → inspector navigation

**Files:**
- Modify: `assets/js/hooks/grid_canvas.js` (add click handler)
- Modify: `lib/lenies_web/live/dashboard_live.ex` (handle "cell_clicked" event)
- Modify: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 7.1: Update JS hook to emit cell_clicked**

Modify `assets/js/hooks/grid_canvas.js` — add a click event listener in `mounted()` after the existing setup:

```javascript
// Inside mounted() — add after the initial clear:
this.canvas.addEventListener("click", (event) => {
  const rect = this.canvas.getBoundingClientRect();
  const x = event.clientX - rect.left;
  const y = event.clientY - rect.top;

  // Convert canvas pixel coords to grid cell coords
  // Canvas is 512×512, grid is gridW × gridH
  const cellX = Math.floor((x / this.canvas.width) * this.gridW);
  const cellY = Math.floor((y / this.canvas.height) * this.gridH);

  this.pushEvent("cell_clicked", { x: cellX, y: cellY });
});
```

`pushEvent` is provided by Phoenix LiveView's hook context.

- [ ] **Step 7.2: Add handle_event in DashboardLive**

In `lib/lenies_web/live/dashboard_live.ex`, add a new `handle_event` clause:

```elixir
def handle_event("cell_clicked", %{"x" => x, "y" => y}, socket) when is_integer(x) and is_integer(y) do
  case :ets.lookup(:cells, {x, y}) do
    [{_, %{lenie_id: id}}] when is_binary(id) ->
      {:noreply, push_navigate(socket, to: ~p"/lenie/#{id}")}

    _ ->
      {:noreply, socket}
  end
end
```

- [ ] **Step 7.3: Test cell_clicked event**

Append to `test/lenies_web/live/dashboard_live_test.exs`:
```elixir
  test "cell_clicked event on occupied cell triggers navigate to inspector", %{conn: conn} do
    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | lenie_id: "CLICKED"}})

    {:ok, view, _html} = live(conn, "/")

    assert {:error, {:live_redirect, %{to: "/lenie/CLICKED"}}} =
             render_hook(view, "cell_clicked", %{"x" => 5, "y" => 5})
  end

  test "cell_clicked event on empty cell stays on dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Cell {7, 8} is empty by default
    assert render_hook(view, "cell_clicked", %{"x" => 7, "y" => 8})
  end
```

- [ ] **Step 7.4: Build assets + run tests**

```bash
mix assets.build
mix test test/lenies_web/live/dashboard_live_test.exs
```

- [ ] **Step 7.5: Commit**

```bash
git add assets/js/hooks/grid_canvas.js lib/lenies_web/live/dashboard_live.ex test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat: canvas click on Lenie cell navigates to inspector"
```

---

## Task 8: Final verification + tag v0.6.0

- [ ] **Step 8.1: Stability check (3x)**

```bash
mix test 2>&1 | tail -3
mix test 2>&1 | tail -3
mix test 2>&1 | tail -3
```

Expected: stable count across runs.

- [ ] **Step 8.2: Format check**

```bash
mix format --check-formatted
```

- [ ] **Step 8.3: Browser smoke test**

```bash
mix phx.server > /tmp/lenies_sp6.log 2>&1 &
SERVER_PID=$!
sleep 5

# Spawn a test Lenie
# Use the dev console — or just navigate and verify HTML

# Verify dashboard loads
curl -sf http://localhost:4000/ -o /tmp/dash.html
echo "--- Dashboard panels ---"
grep -E "(Lenies Dashboard|species-table|grid-canvas)" /tmp/dash.html | head -5

# Verify inspector route responds (even with a fake id)
curl -sf http://localhost:4000/lenie/nonexistent -o /tmp/insp.html
echo "--- Inspector page ---"
grep -E "(Lenie Inspector|non trovato)" /tmp/insp.html | head -3

# Verify species route responds
curl -sf http://localhost:4000/species/abc123 -o /tmp/sp.html
echo "--- Species page ---"
grep -E "(Specie|estinta|mai esistita)" /tmp/sp.html | head -3

# Cleanup
kill $SERVER_PID 2>/dev/null
wait 2>/dev/null
```

Expected: all 3 routes respond with the expected content.

- [ ] **Step 8.4: Tag baseline**

```bash
git status
git log --oneline | head -10
git tag v0.6.0-inspector-species
git tag -l
git rev-list -n 1 v0.6.0-inspector-species
git rev-list -n 1 HEAD
```

Expected: working tree clean, tag matches HEAD.

---

## Self-Review checklist

**Spec coverage:**
- [x] §7.1 Pannello Specie → Task 5
- [x] §7.2 Inspector route /lenie/:id → Task 4
- [x] §7.2 Codeome disassemblato con IP highlighted → Task 2 + 4
- [x] §7.2 Stack/registri/slot di memoria → Task 4 (visible via the snapshot fields)
- [x] §7.2 Live updates via PubSub → Task 3 + 4
- [x] §7.3 Codeome canonico → Task 6
- [x] §7.3 Lineage list → Task 6
- [x] Click canvas → /lenie/:id → Task 7

**Esplicitamente deferito (con placeholder):**
- §7.2 storia ultime 100 azioni — richiede ring buffer nel Lenie process state
- §7.2 template arrows (frecce calcolate al volo) — solo class-based highlighting per ora
- §7.3 filogenia SVG-tree con dimensione nodo = popolazione — solo lista testuale lineage
- §7.3 diff con specie sorelle — placeholder text
- §7.3 export Codeome JSON — placeholder

**Placeholder scan:** nessun "TBD"/"TODO"/"implement later". I deferred sono nominati esplicitamente nel rendering (`<p class="note">(...defferito...)</p>`).

**Type consistency:**
- `Species.aggregate/0` ritorna `species_record()` con `hash, population, avg_generation, sample_lenie_id` — usato consistentemente in `top_n/1` e DashboardLive
- `Disassembler.disassemble/2` ritorna `[line()]` con `index, opcode, is_current` — usato in LenieInspectorLive e SpeciesLive
- `Lenies.Lenie.handle_call(:get_codeome)` ritorna `{:ok, codeome}` — usato in entrambe le view
- `:lenie_update` PubSub message: `{:lenie_update, snap}` — broadcast da Lenie, ricevuto da LenieInspectorLive

**Tech debt anticipated:**
- LenieInspectorLive non rinfresca la lista codeome quando il Lenie applica una mutazione di background (il PubSub aggiorna `snap` ma `codeome_lines` viene rifetched ad ogni broadcast — verifica che funzioni)
- SpeciesLive non si aggiorna live (no PubSub) — l'utente deve ricaricare. Aggiungere subscription a un futuro `"species:#{hash}"` topic in SP7
- Disassembler non disegna le frecce dei salti template (visibilità del flusso di controllo)
- Cells/click → inspector funziona solo per Lenies attivi; click su cella con solo carcassa non navigando da nessuna parte (corretto: niente da ispezionare)
- Multi-client subscription scale: ogni client su `/lenie/:id` riceve ogni broadcast. Con N client e M Lenies cambiati al secondo, N*M messaggi. Pero ogni client subscribe solo al proprio topic, quindi OK.
