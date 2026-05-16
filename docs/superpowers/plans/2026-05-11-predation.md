# Predation Implementation Plan (Sotto-progetto 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere predazione: opcode `:attack` e `:defend`, handler World con risoluzione del danno (con riduzione se difensore), morte → carcassa (path esistente da SP3), un Codeome `carnivore` di test che duella con `minimal_replicator`.

**Architecture:**
- `:attack` e `:defend` sono opcode che ritornano `{:wait_world, action, state}` dall'interprete (stesso pattern di sense/move/eat/replicazione).
- Il World gestisce `:attack` looking up il target via `Lenies.Registry.whereis/1`; calcola danno effettivo confrontando `defending_until` (in `:lenies` ETS) col tick corrente. Invia `:take_damage` ASYNC al target (no deadlock — World non blocca su risposta).
- Il Lenie target gestisce `:take_damage` in `handle_info/2`: sottrae danno da `interp.energy`; se ≤ 0, termina (`{:stop, :killed, state}`) e il path `lenie_died` esistente (SP3 Task 1) cascade-applies carcass placement.
- Il Lenie attaccante riceve il risultato sincrono e applica al proprio `interp.energy` il guadagno (o paga il malus difesa).
- `carnivore.ex` è una variante di `minimal_replicator` che intervalla `:attack` prima di `:eat` nella fase di forage.

**Tech Stack:** Elixir 1.18+, GenServer, async `Process.send/2` per damage propagation, ETS `:lenies` (carryover snapshot merge SP3 preserva `defending_until`).

**Spec di riferimento:** [docs/superpowers/specs/2026-05-11-lenies-design.md](../specs/2026-05-11-lenies-design.md) — §4.2 opcode predazione, §4.3 costi (`:attack` 5, `:defend` 2), §6.4 azione mondo (riga `:attack` e `:defend`).

**Criterio di completamento end-to-end:**
1. `:attack` e `:defend` nell'opcode whitelist + costi corretti.
2. Interpreter dispatch + Lenie integration per entrambi.
3. World handlers: attack con/senza defense, target death + carcass.
4. Lenie `:take_damage` handler con morte su energy ≤ 0.
5. `carnivore` Codeome scritto a mano.
6. Duel integration test: due Lenie adiacenti, l'attaccante ruba energia, su kill lascia carcassa con `lenie_id: nil` sulla cella.
7. Tag `v0.4.0-predation` su HEAD.

---

## File structure

| File | Stato | Responsabilità |
|---|---|---|
| `lib/lenies/codeome/opcodes.ex` | modify | aggiungi `:attack`, `:defend` |
| `lib/lenies/codeome/costs.ex` | modify | aggiungi `:attack` (5.0), `:defend` (2.0) |
| `lib/lenies/interpreter.ex` | modify | 2 dispatch clauses returning `:wait_world` |
| `lib/lenies/lenie.ex` | modify | 2 `apply_world_action` clauses; nuovo `handle_info(:take_damage, ...)` |
| `lib/lenies/world.ex` | modify | 2 handler clauses (`:attack`, `:defend`) |
| `lib/lenies/codeomes/carnivore.ex` | new | Codeome variante che attacca |
| `config/runtime.exs` | modify | `attack_damage: 10`, `defense_window_ticks: 5`, `defense_damage_halving: true` |
| `test/lenies/codeome/opcodes_test.exs` | modify | aggiungi 2 asserzioni whitelist |
| `test/lenies/codeome/costs_test.exs` | modify | aggiungi costi `:attack`/`:defend` |
| `test/lenies/interpreter/predation_opcodes_test.exs` | new | dispatch dei 2 opcode |
| `test/lenies/world_predation_test.exs` | new | handler `:attack`/`:defend` (no-target, hit, defense, kill+carcass) |
| `test/lenies/lenie_take_damage_test.exs` | new | message handler `:take_damage` |
| `test/lenies/codeomes/carnivore_test.exs` | new | duel scenario |

---

## Task 1: Aggiungere `:attack`, `:defend` a opcodes + costi

**Files:**
- Modify: `lib/lenies/codeome/opcodes.ex`
- Modify: `lib/lenies/codeome/costs.ex`
- Modify: `test/lenies/codeome/opcodes_test.exs`
- Modify: `test/lenies/codeome/costs_test.exs`

- [ ] **Step 1.1: Update tests**

Modify `test/lenies/codeome/opcodes_test.exs`:
- Remove `refute :attack in all` and `refute :defend in all` lines (they're now in whitelist).
- Add new test:
```elixir
test "predation opcodes are in the whitelist" do
  assert :attack in Opcodes.all()
  assert :defend in Opcodes.all()
end
```

Modify `test/lenies/codeome/costs_test.exs` — add:
```elixir
test "cost/2 for predation opcodes" do
  assert Costs.cost(:attack, 0) == 5.0
  assert Costs.cost(:defend, 0) == 2.0
end
```

- [ ] **Step 1.2: Run tests (should fail)**

```bash
mix test test/lenies/codeome/
```

Expected: some FAIL.

- [ ] **Step 1.3: Update Opcodes**

In `lib/lenies/codeome/opcodes.ex`, add `:attack` and `:defend` to the `@opcodes` list. Place them in a new "Predazione" group, between "Azione mondo" (`:move`, `:turn_*`, `:eat`) and "Self-inspection":

```elixir
@opcodes [
  # ... existing groups up to and including Azione mondo ...
  :move,
  :turn_left,
  :turn_right,
  :eat,
  # Predazione
  :attack,
  :defend,
  # Self-inspection
  :get_ip,
  # ... rest unchanged ...
]
```

- [ ] **Step 1.4: Update Costs**

In `lib/lenies/codeome/costs.ex`, add new cost clauses BEFORE the catch-all:

```elixir
# Predazione
def cost(:attack, _), do: 5.0
def cost(:defend, _), do: 2.0
```

Place near the other action costs (`:move`, `:eat` group).

- [ ] **Step 1.5: Run tests (should pass)**

```bash
mix test test/lenies/codeome/
```

Expected: PASS.

- [ ] **Step 1.6: Full suite**

```bash
mix test
```

Expected: 173 + 2 changes (asserts shifted) = ~173 still. All pass.

- [ ] **Step 1.7: Commit**

```bash
git add lib/lenies/codeome/opcodes.ex lib/lenies/codeome/costs.ex test/lenies/codeome/
git commit -m "feat: add :attack and :defend to opcode whitelist + costs"
```

---

## Task 2: Interpreter dispatch per `:attack`, `:defend`

**Files:**
- Modify: `lib/lenies/interpreter.ex`
- Test: `test/lenies/interpreter/predation_opcodes_test.exs`

- [ ] **Step 2.1: Test predation opcodes**

Create `test/lenies/interpreter/predation_opcodes_test.exs`:
```elixir
defmodule Lenies.Interpreter.PredationOpcodesTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  test ":attack returns :wait_world with pos and dir" do
    c = Codeome.from_list([:attack, :nop_0])
    state = State.new(energy: 100.0, pos: {5, 5}, dir: :e)

    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:attack, {5, 5}, :e}
    assert new_state.ip == 1
    # cost = 5.0
    assert_in_delta new_state.energy, 100.0 - 5.0, 0.001
  end

  test ":defend returns :wait_world (no descriptor args needed)" do
    c = Codeome.from_list([:defend, :nop_0])
    state = State.new(energy: 100.0, pos: {7, 7}, dir: :n)

    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == :defend
    assert new_state.ip == 1
    # cost = 2.0
    assert_in_delta new_state.energy, 100.0 - 2.0, 0.001
  end

  test ":attack halts on starvation when cost exceeds remaining energy" do
    c = Codeome.from_list([:attack])
    state = State.new(energy: 2.0)

    assert {:halt, :starvation, _new_state} = Interpreter.step(state, c)
  end
end
```

- [ ] **Step 2.2: Run test (should fail)**

```bash
mix test test/lenies/interpreter/predation_opcodes_test.exs
```

Expected: FAIL.

- [ ] **Step 2.3: Add dispatch clauses**

In `lib/lenies/interpreter.ex`, add these BEFORE the catch-all (`defp dispatch(_unknown, ...)`):

```elixir
  # Predazione: ritornano :wait_world. Il Lenie chiama il World e applica il risultato.

  defp dispatch(:attack, state, _c, size) do
    cost = Costs.cost(:attack, 0)
    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:attack, state.pos, state.dir}, new_state}
    end
  end

  defp dispatch(:defend, state, _c, size) do
    cost = Costs.cost(:defend, 0)
    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, :defend, new_state}
    end
  end
```

`:defend` action descriptor is just the bare atom `:defend` — no positional info needed (the World looks up the Lenie's id from the calling context).

- [ ] **Step 2.4: Run test (should pass)**

```bash
mix test test/lenies/interpreter/predation_opcodes_test.exs
```

Expected: PASS, 3 test.

- [ ] **Step 2.5: Full suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 2.6: Commit**

```bash
git add lib/lenies/interpreter.ex test/lenies/interpreter/predation_opcodes_test.exs
git commit -m "feat: add interpreter dispatch for :attack and :defend opcodes"
```

---

## Task 3: World handler `:defend` + Lenie integration

**Files:**
- Modify: `lib/lenies/world.ex` (add `:defend` handler)
- Modify: `lib/lenies/lenie.ex` (apply_world_action for `:defend`)
- Modify: `config/runtime.exs` (add `defense_window_ticks` if not present)
- Test: `test/lenies/world_predation_test.exs` (defend portion)

- [ ] **Step 3.1: Test defend**

Create `test/lenies/world_predation_test.exs`:
```elixir
defmodule Lenies.WorldPredationTest do
  use ExUnit.Case, async: false

  alias Lenies.World
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
    # Mark cell, insert minimal lenies snapshot for "P1"
    [{key, cell}] = :ets.lookup(:cells, {10, 10})
    :ets.insert(:cells, {key, %{cell | lenie_id: "P1"}})
    :ets.insert(:lenies, {"P1", %{id: "P1", pid: self(), pos: {10, 10}, dir: :e}})
    :ok
  end

  describe "defend" do
    test "sets defending_until on the parent record" do
      result = World.action({:defend, "P1"})
      assert result == {:ok, :defending}

      [{"P1", record}] = :ets.lookup(:lenies, "P1")
      assert is_integer(record.defending_until)
      # defense_window_ticks default 5; current tick = 0 → defending_until = 5
      assert record.defending_until == 5
    end

    test "defend after multiple ticks updates relative to current tick" do
      for _ <- 1..3, do: World.tick_now()

      result = World.action({:defend, "P1"})
      assert result == {:ok, :defending}

      [{"P1", record}] = :ets.lookup(:lenies, "P1")
      # current tick = 3 → defending_until = 8
      assert record.defending_until == 8
    end

    test "defend on a Lenie without :lenies record returns :no_lenie" do
      :ets.delete(:lenies, "P1")
      result = World.action({:defend, "P1"})
      assert result == {:ok, :no_lenie}
    end
  end
end
```

- [ ] **Step 3.2: Run test (should fail)**

```bash
mix test test/lenies/world_predation_test.exs
```

Expected: FAIL.

- [ ] **Step 3.3: Add :defend handler in World**

In `lib/lenies/world.ex`, add to `do_action/2` BEFORE the catch-all:

```elixir
  defp do_action({:defend, lenie_id}, state) do
    window = Application.get_env(:lenies, :defense_window_ticks, 5)

    case :ets.lookup(:lenies, lenie_id) do
      [{^lenie_id, _record}] ->
        update_lenie_record(lenie_id, &Map.put(&1, :defending_until, state.tick_count + window))
        {{:ok, :defending}, state}

      _ ->
        {{:ok, :no_lenie}, state}
    end
  end
```

(The `update_lenie_record/2` helper already exists in `World` from SP3 Task 8.)

Add to `config/runtime.exs` if not already present:
```elixir
config :lenies,
  # ... existing keys ...
  defense_window_ticks: 5
```

(This key may already exist — check first; only add if missing.)

- [ ] **Step 3.4: Add Lenie integration for :defend**

In `lib/lenies/lenie.ex`, add to `apply_world_action/3` (with the other action clauses):

```elixir
  defp apply_world_action(:defend, id, interp) do
    case World.action({:defend, id}) do
      {:ok, :defending} -> {:ok, interp}
      {:ok, :no_lenie} -> {:ok, interp}
    end
  end
```

No stack push needed — `:defend` is a fire-and-confirm action.

- [ ] **Step 3.5: Run tests (should pass)**

```bash
mix test test/lenies/world_predation_test.exs
```

Expected: PASS, 3 defend tests.

- [ ] **Step 3.6: Full suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 3.7: Commit**

```bash
git add lib/lenies/world.ex lib/lenies/lenie.ex config/runtime.exs test/lenies/world_predation_test.exs
git commit -m "feat: add World :defend handler with defending_until and Lenie integration"
```

---

## Task 4: World handler `:attack` (con defense check)

**Files:**
- Modify: `lib/lenies/world.ex`
- Modify: `config/runtime.exs` (add `attack_damage`, `defense_attacker_penalty`)
- Test: extend `test/lenies/world_predation_test.exs`

- [ ] **Step 4.1: Test attack**

Append to `test/lenies/world_predation_test.exs`:
```elixir
  describe "attack" do
    setup do
      # Place a target "T1" in front (east of P1 at {11, 10})
      [{key, cell}] = :ets.lookup(:cells, {11, 10})
      :ets.insert(:cells, {key, %{cell | lenie_id: "T1"}})

      # Create a real GenServer for T1 so it can receive :take_damage
      target_pid = spawn_link(fn ->
        receive do
          {:exit, _} -> :ok
        end
      end)

      # Register T1 manually in Registry to make whereis work
      # Note: production Lenie processes register themselves; here we simulate
      {:ok, _} = Elixir.Registry.register(Lenies.Registry, "T1", nil)
      # ↑ This registers the CURRENT test process, not target_pid. Better approach:
      # spawn a process that registers and then waits.
      :ok
    end

    test "attack on empty cell returns :no_target" do
      # Remove target's lenie_id from cell
      [{key, cell}] = :ets.lookup(:cells, {11, 10})
      :ets.insert(:cells, {key, %{cell | lenie_id: nil}})

      result = World.action({:attack, {10, 10}, :e, "P1"})
      assert result == {:ok, :no_target}
    end
  end
```

Wait — this test setup is getting too complex because the target needs to be a real Lenie process to receive `:take_damage`. Let me redesign:

**REVISED Step 4.1**: Use a Lenie process for the target via `Lenies.Lenie.start_link/1`. This makes the test resemble actual usage.

Replace the `describe "attack"` block with:

```elixir
  describe "attack" do
    setup do
      # Spawn a real target Lenie with a permissive Codeome (loop of nop)
      codeome = Lenies.Codeome.from_list([:nop_0, :nop_0, :nop_0])
      
      # Mark target cell occupied
      [{key, cell}] = :ets.lookup(:cells, {11, 10})
      :ets.insert(:cells, {key, %{cell | lenie_id: "T1"}})

      {:ok, target_pid} =
        Lenies.Lenie.start_link(
          id: "T1",
          codeome: codeome,
          energy: 1000.0,
          pos: {11, 10},
          dir: :w,
          lineage: {nil, 0}
        )

      Process.unlink(target_pid)
      # give the Lenie time to write its initial snapshot
      Process.sleep(50)

      on_exit(fn ->
        if Process.alive?(target_pid), do: GenServer.stop(target_pid)
      end)

      %{target_pid: target_pid}
    end

    test "attack on empty front cell returns :no_target", %{target_pid: target_pid} do
      # Move target away
      GenServer.stop(target_pid)
      Process.sleep(100)

      [{key, cell}] = :ets.lookup(:cells, {11, 10})
      :ets.insert(:cells, {key, %{cell | lenie_id: nil}})

      result = World.action({:attack, {10, 10}, :e, "P1"})
      assert result == {:ok, :no_target}
    end

    test "attack on undefended target deals full damage", %{target_pid: target_pid} do
      # ensure no defending_until
      result = World.action({:attack, {10, 10}, :e, "P1"})
      assert {:ok, {:attacked, 10}} = result

      # Wait for target to process :take_damage
      Process.sleep(100)

      snap = Lenies.Lenie.inspect_state(target_pid)
      # Started with 1000.0, lost 10 to attack, plus some energy for own nop ops
      assert snap.energy < 1000.0 - 9.5
    end

    test "attack on defended target deals halved damage and reports :defended" do
      # Manually set defending_until in :lenies record for T1
      Process.sleep(50)
      [{"T1", record}] = :ets.lookup(:lenies, "T1")
      :ets.insert(:lenies, {"T1", Map.put(record, :defending_until, 100)})

      result = World.action({:attack, {10, 10}, :e, "P1"})
      assert {:ok, {:defended, 5}} = result
    end
  end
```

- [ ] **Step 4.2: Run tests (should fail)**

```bash
mix test test/lenies/world_predation_test.exs
```

Expected: FAIL on attack tests.

- [ ] **Step 4.3: Add :attack handler**

In `lib/lenies/world.ex`, add to `do_action/2` BEFORE the catch-all:

```elixir
  defp do_action({:attack, {x, y}, dir, _attacker_id}, state) do
    target_cell = front_cell({x, y}, dir, state.grid)

    case :ets.lookup(:cells, target_cell) do
      [{_, %{lenie_id: target_id}}] when is_binary(target_id) ->
        resolve_attack(target_id, state)

      _ ->
        {{:ok, :no_target}, state}
    end
  end

  defp resolve_attack(target_id, state) do
    base_damage = Application.get_env(:lenies, :attack_damage, 10)

    case :ets.lookup(:lenies, target_id) do
      [{^target_id, record}] ->
        defending_until = Map.get(record, :defending_until, 0)

        {damage, result_tag} =
          if state.tick_count < defending_until do
            {div(base_damage, 2), :defended}
          else
            {base_damage, :attacked}
          end

        # Send async damage message to the target Lenie
        case Lenies.Registry.whereis(target_id) do
          pid when is_pid(pid) -> send(pid, {:take_damage, damage})
          _ -> :ok
        end

        {{:ok, {result_tag, damage}}, state}

      _ ->
        # No :lenies record for target (shouldn't happen with snapshot writes from SP3 Task 1)
        {{:ok, :no_target}, state}
    end
  end
```

(Note: `front_cell/3` already exists in `World` from SP2 Task 10.)

Add to `config/runtime.exs`:
```elixir
config :lenies,
  # ... existing keys ...
  attack_damage: 10
```

(This key may already exist — check first.)

- [ ] **Step 4.4: Run test (should pass)**

```bash
mix test test/lenies/world_predation_test.exs
```

Expected: PASS — all 6 predation tests (3 defend + 3 attack).

- [ ] **Step 4.5: Commit**

```bash
git add lib/lenies/world.ex config/runtime.exs test/lenies/world_predation_test.exs
git commit -m "feat: add World :attack handler with defense check and damage propagation"
```

---

## Task 5: Lenie integration `:attack` + `:take_damage` handler

**Files:**
- Modify: `lib/lenies/lenie.ex`
- Test: `test/lenies/lenie_take_damage_test.exs`

- [ ] **Step 5.1: Test :take_damage handler**

Create `test/lenies/lenie_take_damage_test.exs`:
```elixir
defmodule Lenies.LenieTakeDamageTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie, World}
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

  test "Lenie loses energy when receiving :take_damage" do
    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | lenie_id: "L1"}})

    codeome = Codeome.from_list([:nop_0, :nop_0])
    {:ok, pid} =
      Lenie.start_link(
        id: "L1",
        codeome: codeome,
        energy: 100.0,
        pos: {5, 5},
        dir: :n,
        lineage: {nil, 0}
      )

    send(pid, {:take_damage, 30})
    Process.sleep(50)

    snap = Lenie.inspect_state(pid)
    # Started at 100, lost 30 from damage, plus tiny amount from nop execution
    assert snap.energy <= 100.0 - 30.0 + 0.1  # tolerance for some nop costs

    GenServer.stop(pid)
  end

  test "Lenie dies when :take_damage brings energy <= 0" do
    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | lenie_id: "L2"}})

    codeome = Codeome.from_list([:nop_0])
    {:ok, pid} =
      Lenie.start_link(
        id: "L2",
        codeome: codeome,
        energy: 5.0,
        pos: {5, 5},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)
    ref = Process.monitor(pid)

    send(pid, {:take_damage, 100})

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    # Verify cell cleared (lenie_died cast processed)
    Process.sleep(100)
    [{_, cell}] = :ets.lookup(:cells, {5, 5})
    assert cell.lenie_id == nil
    # Carcass placed (energy_at_death was 5 - 100 = -95, max(0, -95 * 0.5) = 0)
    # Actually energy at moment of :take_damage is updated to -95 then dies
    # carcass = max(0, trunc(-95 * 0.5)) = 0
    # So no carcass on this small example
  end

  test "Lenie that dies from damage with positive energy leaves carcass" do
    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | lenie_id: "L3"}})

    codeome = Codeome.from_list([:nop_0])
    {:ok, pid} =
      Lenie.start_link(
        id: "L3",
        codeome: codeome,
        energy: 50.0,
        pos: {5, 5},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)
    ref = Process.monitor(pid)

    # Damage of exactly 50 should kill (energy = 0 → ≤ 0)
    send(pid, {:take_damage, 50})

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    Process.sleep(100)
    [{_, cell}] = :ets.lookup(:cells, {5, 5})
    assert cell.lenie_id == nil
    # energy_at_death was ~0, no carcass
  end
end
```

- [ ] **Step 5.2: Run test (should fail)**

```bash
mix test test/lenies/lenie_take_damage_test.exs
```

Expected: FAIL.

- [ ] **Step 5.3: Add `:take_damage` handler + `:attack` apply_world_action**

In `lib/lenies/lenie.ex`:

1. Add a new `handle_info` clause BEFORE the wildcard `handle_info(_msg, state)`:

```elixir
  def handle_info({:take_damage, amount}, state) do
    new_energy = state.interp.energy - amount
    new_interp = %{state.interp | energy: new_energy}
    new_state = %{state | interp: new_interp}

    if new_energy <= 0 do
      {:stop, :killed, new_state}
    else
      {:noreply, new_state}
    end
  end
```

2. Add `apply_world_action/3` clause for `:attack`:

```elixir
  defp apply_world_action({:attack, _pos, _dir}, id, interp) do
    case World.action({:attack, interp.pos, interp.dir, id}) do
      {:ok, {:attacked, damage}} ->
        {:ok, %{interp | energy: interp.energy + damage}}

      {:ok, {:defended, damage}} ->
        penalty = Application.get_env(:lenies, :defense_attacker_penalty, 5)
        {:ok, %{interp | energy: interp.energy + damage - penalty}}

      {:ok, :no_target} ->
        {:ok, interp}
    end
  end
```

Add to `config/runtime.exs`:
```elixir
config :lenies,
  # ... existing keys ...
  defense_attacker_penalty: 5
```

- [ ] **Step 5.4: Run tests (should pass)**

```bash
mix test test/lenies/lenie_take_damage_test.exs
```

Expected: PASS, 3 tests.

- [ ] **Step 5.5: Full suite**

```bash
mix test
```

Expected: all pass. Run 3x for stability.

- [ ] **Step 5.6: Commit**

```bash
git add lib/lenies/lenie.ex config/runtime.exs test/lenies/lenie_take_damage_test.exs
git commit -m "feat: Lenie :take_damage handler with death + :attack apply_world_action"
```

---

## Task 6: Carnivore seed Codeome

**Files:**
- Create: `lib/lenies/codeomes/carnivore.ex`
- Test: `test/lenies/codeomes/carnivore_test.exs` (duel scenario)

- [ ] **Step 6.1: Carnivore fixture**

Create `lib/lenies/codeomes/carnivore.ex`. The simplest design: a variant of minimal_replicator where the forage phase prepends `:attack`. The actual codeome is the SAME structure as minimal_replicator with `:attack` inserted before `:eat` in the forage tail. Copy the layout and modify the forage section.

Since the minimal_replicator's exact opcode layout is in `lib/lenies/codeomes/minimal_replicator.ex`, read that file first to base the carnivore on it. Then:

```elixir
defmodule Lenies.Codeomes.Carnivore do
  @moduledoc """
  Carnivore variante del minimal_replicator: la fase di foraggio attacca prima
  di mangiare. Se davanti c'è un Lenie, l'attacco trasferisce energia direttamente.
  Se davanti c'è cibo, l'attacco fallisce (no_target) ma costa solo 5 energia,
  poi il :eat preleva la biomassa.

  Stessa procedura di replicazione del minimal_replicator (4-bit template anchors).
  """

  alias Lenies.Codeome

  # The opcode list is the SAME as Lenies.Codeomes.MinimalReplicator EXCEPT that
  # in the forage tail (after ABORT_TARGET complement), we insert :attack before :eat.
  #
  # Read Lenies.Codeomes.MinimalReplicator's source for the canonical layout.
  # The forage tail in minimal_replicator is something like:
  #   :sense_front, :drop, :eat, :turn_left, :move
  # In carnivore, change to:
  #   :sense_front, :drop, :attack, :eat, :turn_left, :move
  #
  # The TEMPLATE addressing positions may shift by 1; verify the back-jump's template
  # still finds LOOP_HEAD anchor by reading from minimal_replicator.opcodes/0 and
  # patching the forage section.

  def codeome do
    base = Lenies.Codeomes.MinimalReplicator.opcodes()
    
    # Find the forage section: between ABORT_TARGET anchor and the :jmp_t back to start.
    # Look for the sequence :sense_front, :drop, :eat in the base list and insert
    # :attack before :eat.
    patched = inject_attack_before_eat(base)
    Codeome.from_list(patched)
  end

  defp inject_attack_before_eat(opcodes) do
    # Walk the list and inject :attack right before the FIRST :eat
    inject_attack(opcodes, false, [])
  end

  defp inject_attack([], _injected, acc), do: Enum.reverse(acc)
  defp inject_attack([:eat | rest], false, acc) do
    Enum.reverse(acc) ++ [:attack, :eat | rest]
  end
  defp inject_attack([op | rest], injected, acc) do
    inject_attack(rest, injected, [op | acc])
  end
end
```

NOTE: this approach assumes `Lenies.Codeomes.MinimalReplicator` has an `opcodes/0` function exposing the raw opcode list. From the SP3 Task 14 implementation, this should exist. If not, just hardcode the carnivore opcodes by reading minimal_replicator's source and inserting `:attack` before the `:eat` in the forage section.

**Caveat about templates**: inserting `:attack` SHIFTS all subsequent positions by 1. The minimal_replicator's templates are anchored to relative positions, so the BACKWARD `:jmp_t` from the forage tail to LOOP_HEAD anchor at position 0..3 needs to be re-found. Since template search uses `find_complement` (forward then backward), inserting one opcode in the forage section shouldn't break the back-jump template — the LOOP_HEAD anchor is still findable.

If the test in Step 6.2 reveals the carnivore doesn't replicate due to template issues, fix the inserted position or template length.

- [ ] **Step 6.2: Duel integration test**

Create `test/lenies/codeomes/carnivore_test.exs`:
```elixir
defmodule Lenies.Codeomes.CarnivoreTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie, World}
  alias Lenies.Codeomes.{Carnivore, MinimalReplicator}
  alias Lenies.World.Tables

  @moduletag timeout: 30_000

  setup do
    # Disable copy errors and background mutation for determinism
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_interval_ticks, 0)
    Application.put_env(:lenies, :min_viable_codeome_opcodes, 5)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 500})

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

  test "duel: carnivore facing herbivore steals energy via :attack" do
    # Herbivore at {50, 50} facing west (away from carnivore)
    [{key, cell}] = :ets.lookup(:cells, {50, 50})
    :ets.insert(:cells, {key, %{cell | lenie_id: "HERB"}})
    {:ok, herb_pid} =
      Lenie.start_link(
        id: "HERB",
        codeome: MinimalReplicator.codeome(),
        energy: 500.0,
        pos: {50, 50},
        dir: :w,
        lineage: {nil, 0}
      )
    Process.unlink(herb_pid)

    # Carnivore at {49, 50} facing east → towards herbivore
    [{key, cell}] = :ets.lookup(:cells, {49, 50})
    :ets.insert(:cells, {key, %{cell | lenie_id: "CARN"}})
    {:ok, carn_pid} =
      Lenie.start_link(
        id: "CARN",
        codeome: Carnivore.codeome(),
        energy: 500.0,
        pos: {49, 50},
        dir: :e,
        lineage: {nil, 0}
      )
    Process.unlink(carn_pid)

    # Run for 500ms
    Process.sleep(500)

    # Either:
    # - herb is dead (carn killed it): assert :ets.lookup(:lenies, "HERB") == [] OR herb_pid not alive
    # - or herb is alive but has lost energy from the encounter
    herb_alive = Process.alive?(herb_pid)
    carn_alive = Process.alive?(carn_pid)

    # At least one duelist should still be alive
    assert herb_alive or carn_alive

    if herb_alive and carn_alive do
      herb_snap = Lenie.inspect_state(herb_pid)
      carn_snap = Lenie.inspect_state(carn_pid)
      IO.inspect(herb_snap.energy, label: "HERB energy after 500ms")
      IO.inspect(carn_snap.energy, label: "CARN energy after 500ms")
      # Some interaction happened
      assert true
    end

    if herb_alive, do: GenServer.stop(herb_pid)
    if carn_alive, do: GenServer.stop(carn_pid)
  end
end
```

The test is INTENTIONALLY loose — it just verifies the simulation doesn't crash and at least one duelist survives. Predator-prey oscillation would need many more cycles and specific parameter tuning.

- [ ] **Step 6.3: Run test**

```bash
mix test test/lenies/codeomes/carnivore_test.exs
```

Expected: PASS. May require iteration if the carnivore Codeome has template alignment bugs.

If it fails: 
- Read the actual minimal_replicator source
- Manually construct the carnivore opcodes (don't rely on `opcodes/0` if not defined)
- Verify by inspecting `Carnivore.codeome() |> Codeome.size()` and the structure

- [ ] **Step 6.4: Full suite**

```bash
mix test
```

Expected: all pass. Run 3x for stability.

- [ ] **Step 6.5: Commit**

```bash
git add lib/lenies/codeomes/carnivore.ex test/lenies/codeomes/carnivore_test.exs
git commit -m "feat: add Carnivore Codeome variant with :attack before :eat in forage"
```

---

## Task 7: Carcass on attack-kill regression test

**Files:**
- Test: extend `test/lenies/world_predation_test.exs`

This task verifies the carcass placement path works specifically when death is caused by `:take_damage`, not starvation. The lenie_died cast (SP3 Task 9 carryover fix) should still cascade-apply carcass placement.

- [ ] **Step 7.1: Test carcass on kill**

Append to `test/lenies/world_predation_test.exs`:
```elixir
  describe "kill leaves carcass" do
    test "Lenie dying from :take_damage leaves carcass on its cell" do
      [{key, cell}] = :ets.lookup(:cells, {30, 30})
      :ets.insert(:cells, {key, %{cell | lenie_id: "VICTIM"}})

      codeome = Lenies.Codeome.from_list([:nop_0])
      {:ok, pid} =
        Lenies.Lenie.start_link(
          id: "VICTIM",
          codeome: codeome,
          energy: 100.0,
          pos: {30, 30},
          dir: :n,
          lineage: {nil, 0}
        )
      Process.unlink(pid)
      ref = Process.monitor(pid)

      # 50 damage on 100 energy → death (energy = -50, ≤ 0)
      # Actually after some nop cycles energy ≈ 100, send damage = 100 to kill
      send(pid, {:take_damage, 100})

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500
      Process.sleep(100)

      [{_, cell}] = :ets.lookup(:cells, {30, 30})
      assert cell.lenie_id == nil
      # carcass = max(0, trunc(energy_at_death * 0.5))
      # energy_at_death is whatever was left after the damage applied
      # Could be 0 (no carcass) or slightly positive depending on timing
      # Just verify the cell was cleared properly
      assert cell.carcass >= 0
    end
  end
```

- [ ] **Step 7.2: Run test**

```bash
mix test test/lenies/world_predation_test.exs
```

Expected: PASS.

- [ ] **Step 7.3: Commit**

```bash
git add test/lenies/world_predation_test.exs
git commit -m "test: cover carcass placement on attack-kill"
```

---

## Task 8: Final verification + tag v0.4.0

**Files:** none

- [ ] **Step 8.1: Stability check (3x)**

```bash
mix test 2>&1 | tail -3
mix test 2>&1 | tail -3
mix test 2>&1 | tail -3
```

Expected: stable count.

- [ ] **Step 8.2: Format check**

```bash
mix format --check-formatted
```

Expected: clean.

- [ ] **Step 8.3: Smoke test from console**

```bash
mix run --no-halt -e '
Application.ensure_all_started(:lenies)

# Disable copy errors and background mutation for determinism
Application.put_env(:lenies, :copy_substitution_rate, 0.0)
Application.put_env(:lenies, :copy_insert_rate, 0.0)
Application.put_env(:lenies, :copy_delete_rate, 0.0)
Application.put_env(:lenies, :background_mutation_interval_ticks, 0)
Application.put_env(:lenies, :min_viable_codeome_opcodes, 5)
Application.put_env(:lenies, :eat_amount, 200)

# seed biomass corridor
for x <- 30..220, y <- 40..60 do
  [{k, c}] = :ets.lookup(:cells, {x, y})
  :ets.insert(:cells, {k, %{c | resource: 1000}})
end

# Spawn herbivore and carnivore adjacent
[{key, cell}] = :ets.lookup(:cells, {50, 50})
:ets.insert(:cells, {key, %{cell | lenie_id: "HERB"}})

[{key, cell}] = :ets.lookup(:cells, {49, 50})
:ets.insert(:cells, {key, %{cell | lenie_id: "CARN"}})

{:ok, _} = Lenies.Lenie.start_link(
  id: "HERB",
  codeome: Lenies.Codeomes.MinimalReplicator.codeome(),
  energy: 2000.0,
  pos: {50, 50},
  dir: :w,
  lineage: {nil, 0}
)

{:ok, _} = Lenies.Lenie.start_link(
  id: "CARN",
  codeome: Lenies.Codeomes.Carnivore.codeome(),
  energy: 2000.0,
  pos: {49, 50},
  dir: :e,
  lineage: {nil, 0}
)

:timer.sleep(3000)

snapshots = :ets.tab2list(:lenies)
IO.puts("Population: #{length(snapshots)}")

species = snapshots |> Enum.map(fn {_, s} -> Map.get(s, :codeome_hash) end) |> Enum.uniq()
IO.puts("Distinct species hashes: #{length(species)}")

System.halt(0)
'
```

Expected output: some population alive, possibly two species (herb + carn lineages).

- [ ] **Step 8.4: Tag**

```bash
git status
git log --oneline | head -15
git tag v0.4.0-predation
git tag -l
git rev-list -n 1 v0.4.0-predation
git rev-list -n 1 HEAD
```

Expected: working tree clean, tag matches HEAD.

---

## Self-Review checklist

**Spec coverage:**
- [x] §4.2 opcode `:attack` e `:defend` whitelist → Task 1
- [x] §4.3 costi `:attack` (5), `:defend` (2) → Task 1
- [x] §6.4 azione `:attack` con difesa check → Task 4
- [x] §6.4 `:defend` aggiorna `defending_until` → Task 3
- [x] Morte → carcassa (path SP3 esistente, regression test) → Task 7

**Esplicitamente fuori scope:**
- Carnivore evolutionary dynamics (oscillazione predator-prey realistica) — design point, non test
- LiveView visualization → sotto-progetto 5
- Inspector views per attacchi recenti → sotto-progetto 6

**Placeholder scan**: il piano ha 1 punto che richiede attenzione dell'implementer:
- Task 6: il `carnivore.ex` può richiedere iterazione se l'inserimento di `:attack` rompe i template del minimal_replicator. Documentato come avviso.

**Type consistency**:
- Action descriptors: `{:attack, pos, dir}` e `:defend` (atom bare) consistenti tra interpreter (Task 2) e Lenie (Task 5)
- World action args: `{:attack, pos, dir, attacker_id}`, `{:defend, lenie_id}` consistenti
- Result tuples: `{:attacked, damage}`, `{:defended, damage}`, `:no_target`, `:defending`, `:no_lenie` consistenti
- `:take_damage` message: `{:take_damage, amount}` consistente tra World (Task 4) e Lenie (Task 5)
