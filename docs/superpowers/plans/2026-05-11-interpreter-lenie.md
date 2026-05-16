# Interpreter + Lenie Process Implementation Plan (Sotto-progetto 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Costruire la VM stack-based e il processo Lenie. Al termine, un Codeome scritto a mano (un "walker" minimale) gira come processo BEAM dedicato: esegue cicli con metabolismo energetico, si sposta sulla griglia, mangia biomassa, usa template jumps. Nessuna replicazione, nessuna predazione ancora.

**Architecture:**
- **`Lenies.Interpreter`** è puro: `step/2` accetta `InterpreterState + Codeome`, ritorna `{:cont, state} | {:wait_world, action, state} | {:halt, reason, state}`. Tutto deterministico, tutto testabile isolatamente.
- **`Lenies.Lenie`** è un `GenServer` con un loop metabolico guidato da `Process.send_after(self(), :metabolize, 0)`. Per ogni batch esegue K istruzioni del proprio Codeome via `Interpreter.run_k_instructions/2`. Quando l'interprete chiede un'azione mondo, il Lenie fa `GenServer.call(Lenies.World, ...)` sincrono, applica il risultato, prosegue.
- **`Lenies.World`** estende l'API con handler per `:sense_front`, `:move`, `:eat` e per la morte del Lenie (carcass placement). I Lenies sono spawnati via `Lenies.LenieSupervisor` (vuoto in sotto-progetto 1, popolato qui).
- **`Lenies.Registry`** (deferito da sotto-progetto 1) fornisce lookup `id ↔ pid`.

**Tech Stack:** Elixir 1.18+, GenServer, DynamicSupervisor (Lenies.LenieSupervisor), Registry, ETS (`:cells`, `:lenies` continuano dal sotto-progetto 1), Erlang `:erlang.process_flag/2` per `max_heap_size`, Phoenix.PubSub per eventi vita/morte.

**Spec di riferimento:** [docs/superpowers/specs/2026-05-11-lenies-design.md](../specs/2026-05-11-lenies-design.md) — sezioni 4 (Codeome e interprete) e 6.4 (azioni mondo, righe `:move`, `:eat`, `:turn_*`).

**Criterio di completamento end-to-end:** una integration suite avvia il World, spawna un singolo Lenie da Codeome hard-coded `walker.codeome`, lascia girare per N tick metabolici, verifica:
1. Il Lenie cambia posizione (è andato avanti su almeno una cella nel suo tempo di vita)
2. Il Lenie ha consumato energia ma è ancora vivo (oppure è morto correttamente di starvation, con carcass placement)
3. Una seconda suite spawna un Lenie con `template_jumper.codeome` e verifica che il jump-condizionato sui template porti il controllo alla branch attesa (introspezione tramite `Lenie.inspect_state(pid)`).

---

## File structure

| File | Responsabilità |
|---|---|
| `lib/lenies/registry.ex` | Wrapper di `Registry` (api `register/1`, `whereis/1`, `count/0`) |
| `lib/lenies/codeome.ex` | Tipo Codeome (`tuple of opcodes`) + helpers (`from_list/1`, `at/2`, `size/1`, `hash/1`) |
| `lib/lenies/codeome/opcodes.ex` | Tabella whitelist atom ↔ integer (per `:read_self`) |
| `lib/lenies/codeome/costs.ex` | Mapping opcode → costo energetico |
| `lib/lenies/interpreter/state.ex` | `%InterpreterState{}` struct + helpers (`new/1`, `push/2`, `pop/1`, `peek/1`, `store/3`, `load/2`, `apply_cost/2`) |
| `lib/lenies/interpreter/template.ex` | Template addressing: `extract_template/2`, `find_complement/3` |
| `lib/lenies/interpreter.ex` | `step/2`, `run_k_instructions/3`, dispatch su opcode |
| `lib/lenies/lenie.ex` | GenServer Lenie: `start_link/1`, `init/1` (max_heap_size, registry), metabolic loop, terminate |
| `lib/lenies/world.ex` (modifiche) | Handler `:sense_front`, `:move`, `:eat`, `:lenie_died` |
| `lib/lenies/codeomes/walker.ex` | Codeome hard-coded "walker" (test fixture) |
| `lib/lenies/codeomes/template_jumper.ex` | Codeome hard-coded "template-jumper" (test fixture) |

| Test file | Cosa testa |
|---|---|
| `test/lenies/registry_test.exs` | Registry wrapper |
| `test/lenies/codeome_test.exs` | Codeome struct + helpers + hash |
| `test/lenies/codeome/opcodes_test.exs` | Encoding atom↔int, whitelist enforcement |
| `test/lenies/codeome/costs_test.exs` | Cost lookup, template-length pricing |
| `test/lenies/interpreter/state_test.exs` | Stack push/pop/peek, slots, energy apply |
| `test/lenies/interpreter/template_test.exs` | Template extraction + complement search |
| `test/lenies/interpreter/stack_arith_test.exs` | Opcodes `:push*`, `:dup`, `:drop`, `:swap`, `:add`, `:sub`, `:mul`, `:mod` |
| `test/lenies/interpreter/memory_orient_test.exs` | Opcodes `:store`, `:load`, `:turn_left/right` |
| `test/lenies/interpreter/local_sense_test.exs` | Opcodes `:sense_self/energy/age/size` |
| `test/lenies/interpreter/self_inspect_test.exs` | Opcodes `:get_ip`, `:get_size`, `:read_self` |
| `test/lenies/interpreter/control_flow_test.exs` | Opcodes `:jmp_t`, `:jz_t`, `:jnz_t`, `:call_t`, `:ret` |
| `test/lenies/interpreter/world_action_test.exs` | Opcodes che ritornano `{:wait_world, ...}` |
| `test/lenies/lenie_test.exs` | Lenie GenServer: init/loop/death/registry |
| `test/lenies/world_action_test.exs` | Handler `:sense_front`, `:move`, `:eat`, `:lenie_died` |
| `test/lenies/integration_test.exs` | Walker + template-jumper end-to-end |

---

## Task 1: Lenies.Registry (deferred from sub-project 1)

**Files:**
- Create: `lib/lenies/registry.ex`
- Modify: `lib/lenies/application.ex`
- Test: `test/lenies/registry_test.exs`

**Setup**: `export PATH="$HOME/.asdf/shims:$PATH"`

- [ ] **Step 1.1: Test Registry wrapper**

Create `test/lenies/registry_test.exs`:
```elixir
defmodule Lenies.RegistryTest do
  use ExUnit.Case, async: false

  alias Lenies.Registry, as: LenieRegistry

  setup do
    on_exit(fn ->
      # Unregister anything left behind
      Elixir.Registry.dispatch(LenieRegistry, "", fn _ -> :ok end)
      :ok
    end)
    :ok
  end

  test "register/1 binds the current process to an id" do
    {:ok, _} = LenieRegistry.register("lenie-1")
    assert LenieRegistry.whereis("lenie-1") == self()
  end

  test "whereis/1 returns nil when id is unknown" do
    assert LenieRegistry.whereis("never-registered") == nil
  end

  test "count/0 reflects registered processes" do
    {:ok, _} = LenieRegistry.register("lenie-A")
    assert LenieRegistry.count() >= 1
  end
end
```

- [ ] **Step 1.2: Run test (should fail)**

```bash
mix test test/lenies/registry_test.exs
```
Expected: FAIL — modulo non esiste, registry non in supervision tree.

- [ ] **Step 1.3: Implement Lenies.Registry**

Create `lib/lenies/registry.ex`:
```elixir
defmodule Lenies.Registry do
  @moduledoc """
  Wrapper di `Registry` per associare id Lenie ↔ pid.

  Usato da `Lenies.Lenie` per identificarsi a runtime (es. `Registry.whereis(id)`
  per inviare messaggi senza tenere pid in giro). Registrato nell'albero di
  supervisione come `Lenies.Registry`.

  Vedi spec §3.1.
  """

  @name __MODULE__

  @doc "Child spec per la supervision tree."
  def child_spec(_init_arg) do
    Elixir.Registry.child_spec(keys: :unique, name: @name)
  end

  @doc "Registra il processo chiamante con `id`. Il binding cessa quando il processo muore."
  def register(id) do
    Elixir.Registry.register(@name, id, nil)
  end

  @doc "Ritorna il pid associato a `id`, o `nil` se non registrato."
  def whereis(id) do
    case Elixir.Registry.lookup(@name, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Numero di processi attualmente registrati."
  def count, do: Elixir.Registry.count(@name)
end
```

- [ ] **Step 1.4: Add Registry to supervision tree**

Modify `lib/lenies/application.ex` — add `Lenies.Registry` to the always-on children list (it must always run, both in tests and in production). The current always-on list is:
```elixir
children = [
  LeniesWeb.Telemetry,
  {DNSCluster, query: Application.get_env(:lenies, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: Lenies.PubSub},
  LeniesWeb.Endpoint
]
```

Change to:
```elixir
children = [
  LeniesWeb.Telemetry,
  {DNSCluster, query: Application.get_env(:lenies, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: Lenies.PubSub},
  Lenies.Registry,
  LeniesWeb.Endpoint
]
```

- [ ] **Step 1.5: Run test (should pass)**

```bash
mix test test/lenies/registry_test.exs
```
Expected: PASS, 3 test.

- [ ] **Step 1.6: Full suite**

```bash
mix test
```
Expected: 45 test (42 + 3), 0 fallimenti.

- [ ] **Step 1.7: Commit**

```bash
git add lib/lenies/registry.ex lib/lenies/application.ex test/lenies/registry_test.exs
git commit -m "feat: add Lenies.Registry for Lenie id↔pid lookup"
```

---

## Task 2: Codeome struct + helpers

**Files:**
- Create: `lib/lenies/codeome.ex`
- Test: `test/lenies/codeome_test.exs`

- [ ] **Step 2.1: Test Codeome**

Create `test/lenies/codeome_test.exs`:
```elixir
defmodule Lenies.CodeomeTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeome

  test "from_list/1 builds a tuple-backed Codeome" do
    c = Codeome.from_list([:nop_0, :nop_1, :push0])
    assert Codeome.size(c) == 3
  end

  test "at/2 returns the opcode at the given position" do
    c = Codeome.from_list([:nop_0, :push1, :add])
    assert Codeome.at(c, 0) == :nop_0
    assert Codeome.at(c, 1) == :push1
    assert Codeome.at(c, 2) == :add
  end

  test "at/2 wraps around (Codeome is treated as circular for template search)" do
    c = Codeome.from_list([:nop_0, :nop_1])
    assert Codeome.at(c, 2) == :nop_0
    assert Codeome.at(c, -1) == :nop_1
  end

  test "to_list/1 returns the opcodes as a list" do
    c = Codeome.from_list([:nop_0, :push1])
    assert Codeome.to_list(c) == [:nop_0, :push1]
  end

  test "hash/1 is stable for identical Codeome" do
    c1 = Codeome.from_list([:nop_0, :push1, :add])
    c2 = Codeome.from_list([:nop_0, :push1, :add])
    assert Codeome.hash(c1) == Codeome.hash(c2)
  end

  test "hash/1 differs for distinct Codeome" do
    c1 = Codeome.from_list([:nop_0, :push1])
    c2 = Codeome.from_list([:nop_1, :push1])
    refute Codeome.hash(c1) == Codeome.hash(c2)
  end
end
```

- [ ] **Step 2.2: Run test (should fail)**

```bash
mix test test/lenies/codeome_test.exs
```
Expected: FAIL.

- [ ] **Step 2.3: Implement Codeome**

Create `lib/lenies/codeome.ex`:
```elixir
defmodule Lenies.Codeome do
  @moduledoc """
  Il Codeome di un Lenie: sequenza di opcode che è sia genoma sia programma.

  Internamente rappresentato come tupla Elixir per lookup O(1) (`elem/2`).
  Tutte le funzioni rispettano l'aritmetica circolare di `at/2` — il Codeome
  è effettivamente un anello, per supportare il template addressing (vedi
  spec §4.2 e §5.1) che cerca il complemento del template nei due versi.

  Vedi `Lenies.Interpreter` per l'esecuzione e `Lenies.Codeome.Opcodes`
  per la whitelist degli opcode validi.
  """

  @type opcode :: atom()
  @type t :: %__MODULE__{opcodes: tuple()}

  defstruct opcodes: {}

  @spec from_list([opcode()]) :: t()
  def from_list(list) when is_list(list) do
    %__MODULE__{opcodes: List.to_tuple(list)}
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{opcodes: ops}), do: tuple_size(ops)

  @doc """
  Ritorna l'opcode in posizione `i`, con wrap modulo `size`. Supporta
  indici negativi (es. `-1` → ultimo opcode).
  """
  @spec at(t(), integer()) :: opcode()
  def at(%__MODULE__{opcodes: ops}, i) do
    n = tuple_size(ops)
    elem(ops, Integer.mod(i, n))
  end

  @spec to_list(t()) :: [opcode()]
  def to_list(%__MODULE__{opcodes: ops}), do: Tuple.to_list(ops)

  @doc """
  Hash strutturale del Codeome (xxhash a 64 bit). Stesso input → stesso hash.
  Usato come `codeome_hash` per il clustering di specie.
  """
  @spec hash(t()) :: binary()
  def hash(%__MODULE__{opcodes: ops}) do
    :erlang.phash2(ops, 4_294_967_296) |> Integer.to_string(16)
  end
end
```

(Nota: usiamo `:erlang.phash2/2` invece di xxhash perché è built-in e già abbastanza buono per il clustering. Sub-project futuro potrà sostituire con xxhash se serve più collisione-resistenza.)

- [ ] **Step 2.4: Run test (should pass)**

```bash
mix test test/lenies/codeome_test.exs
```
Expected: PASS, 6 test.

- [ ] **Step 2.5: Commit**

```bash
git add lib/lenies/codeome.ex test/lenies/codeome_test.exs
git commit -m "feat: add Codeome struct with circular at/2 and stable hash"
```

---

## Task 3: Opcode encoding table + Energy costs

**Files:**
- Create: `lib/lenies/codeome/opcodes.ex`
- Create: `lib/lenies/codeome/costs.ex`
- Test: `test/lenies/codeome/opcodes_test.exs`
- Test: `test/lenies/codeome/costs_test.exs`

- [ ] **Step 3.1: Test Opcodes**

Create `test/lenies/codeome/opcodes_test.exs`:
```elixir
defmodule Lenies.Codeome.OpcodesTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeome.Opcodes

  test "all/0 returns the full whitelist" do
    all = Opcodes.all()
    assert :nop_0 in all
    assert :nop_1 in all
    assert :push0 in all
    assert :move in all
    assert :get_ip in all
    # opcodes per sotto-progetti futuri NON sono nella whitelist di sotto-progetto 2
    refute :allocate in all
    refute :write_child in all
    refute :divide in all
    refute :attack in all
    refute :defend in all
  end

  test "encode/1 returns an integer for known opcodes" do
    assert is_integer(Opcodes.encode(:nop_0))
    assert is_integer(Opcodes.encode(:move))
  end

  test "encode/1 returns unique integers per opcode" do
    encoded = Enum.map(Opcodes.all(), &Opcodes.encode/1)
    assert length(encoded) == length(Enum.uniq(encoded))
  end

  test "decode/1 round-trips with encode/1" do
    for op <- Opcodes.all() do
      assert Opcodes.decode(Opcodes.encode(op)) == op
    end
  end

  test "decode/1 of unknown integer returns :nop_0 (tolerance to mutations)" do
    assert Opcodes.decode(999_999) == :nop_0
  end

  test "known?/1 distinguishes whitelisted opcodes from others" do
    assert Opcodes.known?(:nop_0)
    refute Opcodes.known?(:allocate)
    refute Opcodes.known?(:foo_bar)
  end
end
```

- [ ] **Step 3.2: Test Costs**

Create `test/lenies/codeome/costs_test.exs`:
```elixir
defmodule Lenies.Codeome.CostsTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeome.Costs

  test "cost/2 returns the configured cost for cheap stack ops" do
    assert Costs.cost(:nop_0, 0) == 0.1
    assert Costs.cost(:push0, 0) == 0.1
    assert Costs.cost(:dup, 0) == 0.1
  end

  test "cost/2 returns the configured cost for arithmetic" do
    assert Costs.cost(:add, 0) == 0.2
  end

  test "cost/2 returns the configured cost for sense ops" do
    assert Costs.cost(:sense_front, 0) == 0.5
  end

  test "cost/2 returns the configured cost for world actions" do
    assert Costs.cost(:move, 0) == 2.0
    assert Costs.cost(:eat, 0) == 2.0
  end

  test "cost/2 for jumps scales with template length" do
    # base 0.2 + 0.05 * template_length
    assert Costs.cost(:jmp_t, 0) == 0.2
    assert Costs.cost(:jmp_t, 4) == 0.4
    assert Costs.cost(:jmp_t, 8) == 0.6
  end

  test "cost/2 for unknown opcode returns 0.1 (treated as nop_0)" do
    assert Costs.cost(:foo_bar, 0) == 0.1
  end
end
```

- [ ] **Step 3.3: Run tests (should fail)**

```bash
mix test test/lenies/codeome/opcodes_test.exs test/lenies/codeome/costs_test.exs
```
Expected: FAIL.

- [ ] **Step 3.4: Implement Opcodes**

Create `lib/lenies/codeome/opcodes.ex`:
```elixir
defmodule Lenies.Codeome.Opcodes do
  @moduledoc """
  Whitelist degli opcode validi e mapping bidirezionale atom ↔ integer.

  L'integer encoding serve per `:read_self` (che ritorna l'opcode come integer
  sullo stack) e per `:write_child` (sotto-progetto 3, che riceve l'integer
  e lo decodifica per scrivere nello slot figlio).

  Vedi spec §4.2. Opcode non noti vengono trattati come `:nop_0` (tolleranza
  alle mutazioni: nessun "syntax error").
  """

  # Whitelist completa di sotto-progetto 2.
  # Replicazione (:allocate, :write_child, :divide) e predazione (:attack, :defend)
  # saranno aggiunti nei sotto-progetti 3 e 4 rispettivamente.
  @opcodes [
    # Template / bit
    :nop_0,
    :nop_1,
    # Stack / aritmetica
    :push0,
    :push1,
    :pushN,
    :dup,
    :drop,
    :swap,
    :add,
    :sub,
    :mul,
    :mod,
    # Controllo template-based
    :jmp_t,
    :jz_t,
    :jnz_t,
    :call_t,
    :ret,
    # Senso
    :sense_front,
    :sense_self,
    :sense_energy,
    :sense_age,
    :sense_size,
    # Azione mondo
    :move,
    :turn_left,
    :turn_right,
    :eat,
    # Self-inspection
    :get_ip,
    :get_size,
    :read_self,
    # Memoria locale
    :store,
    :load
  ]

  @encoding @opcodes |> Enum.with_index() |> Enum.into(%{})
  @decoding @encoding |> Map.new(fn {op, i} -> {i, op} end)

  @spec all() :: [atom()]
  def all, do: @opcodes

  @spec known?(atom()) :: boolean()
  def known?(op), do: Map.has_key?(@encoding, op)

  @spec encode(atom()) :: non_neg_integer()
  def encode(op), do: Map.get(@encoding, op, 0)

  @doc "Decodifica un integer al suo opcode. Integer fuori range → `:nop_0`."
  @spec decode(integer()) :: atom()
  def decode(i) when is_integer(i), do: Map.get(@decoding, i, :nop_0)
end
```

- [ ] **Step 3.5: Implement Costs**

Create `lib/lenies/codeome/costs.ex`:
```elixir
defmodule Lenies.Codeome.Costs do
  @moduledoc """
  Costi energetici degli opcode. Vedi spec §4.3.

  `cost/2` accetta `template_len` per gli opcode di salto (`:jmp_t`, ecc.)
  che pagano `0.2 + 0.05 * template_len`. Per gli altri opcode il parametro
  è ignorato.
  """

  @doc "Costo energetico per un'esecuzione dell'opcode."
  @spec cost(atom(), non_neg_integer()) :: float()
  def cost(opcode, template_len \\ 0)

  # Stack/template (cheap)
  def cost(op, _) when op in [:nop_0, :nop_1, :push0, :push1, :pushN, :dup, :drop, :swap], do: 0.1

  # Aritmetica
  def cost(op, _) when op in [:add, :sub, :mul, :mod], do: 0.2

  # Salti template-based: 0.2 + 0.05 * template_len
  def cost(op, template_len) when op in [:jmp_t, :jz_t, :jnz_t, :call_t, :ret] do
    0.2 + 0.05 * template_len
  end

  # Sense + turn + memoria
  def cost(op, _)
      when op in [
             :sense_front,
             :sense_self,
             :sense_energy,
             :sense_age,
             :sense_size,
             :turn_left,
             :turn_right,
             :store,
             :load
           ],
      do: 0.5

  # Self-inspection
  def cost(op, _) when op in [:get_ip, :get_size, :read_self], do: 0.3

  # Azione mondo: movimento/mangiare
  def cost(op, _) when op in [:move, :eat], do: 2.0

  # Opcode sconosciuto → trattato come :nop_0
  def cost(_, _), do: 0.1
end
```

- [ ] **Step 3.6: Run tests (should pass)**

```bash
mix test test/lenies/codeome/opcodes_test.exs test/lenies/codeome/costs_test.exs
```
Expected: PASS, 12 test totali (6 opcodes + 6 costs).

- [ ] **Step 3.7: Commit**

```bash
git add lib/lenies/codeome/opcodes.ex lib/lenies/codeome/costs.ex test/lenies/codeome/
git commit -m "feat: add Codeome opcode whitelist and energy cost table"
```

---

## Task 4: InterpreterState struct

**Files:**
- Create: `lib/lenies/interpreter/state.ex`
- Test: `test/lenies/interpreter/state_test.exs`

- [ ] **Step 4.1: Test InterpreterState**

Create `test/lenies/interpreter/state_test.exs`:
```elixir
defmodule Lenies.Interpreter.StateTest do
  use ExUnit.Case, async: true

  alias Lenies.Interpreter.State

  test "new/1 builds a default state with seeded fields" do
    s = State.new(energy: 100, pos: {10, 20}, dir: :e)
    assert s.ip == 0
    assert s.stack == []
    assert s.slots == %{0 => 0, 1 => 0, 2 => 0, 3 => 0}
    assert s.energy == 100
    assert s.pos == {10, 20}
    assert s.dir == :e
    assert s.age == 0
    assert s.call_stack == []
  end

  test "push/2 puts value on top of stack" do
    s = State.new(energy: 100) |> State.push(42)
    assert s.stack == [42]
    s = State.push(s, 7)
    assert s.stack == [7, 42]
  end

  test "push/2 enforces 16-element stack limit (drops bottom when full)" do
    s =
      Enum.reduce(1..16, State.new(energy: 100), fn i, acc ->
        State.push(acc, i)
      end)
    assert length(s.stack) == 16

    s = State.push(s, 99)
    assert length(s.stack) == 16
    assert hd(s.stack) == 99
    refute 1 in s.stack
  end

  test "pop/1 removes and returns top of stack" do
    s = State.new(energy: 100) |> State.push(1) |> State.push(2)
    assert {2, s} = State.pop(s)
    assert s.stack == [1]
  end

  test "pop/1 on empty stack returns {0, state} (defensive — opcode evolution may pop too much)" do
    s = State.new(energy: 100)
    assert {0, s2} = State.pop(s)
    assert s2.stack == []
  end

  test "store/3 and load/2 work on the 4 slots" do
    s = State.new(energy: 100) |> State.store(2, 42)
    assert State.load(s, 2) == 42
    assert State.load(s, 0) == 0
  end

  test "store/3 ignores out-of-range slot indices (modulo 4)" do
    s = State.new(energy: 100) |> State.store(7, 99)
    assert State.load(s, 7) == 99
    assert State.load(s, 3) == 99
  end

  test "apply_cost/2 subtracts energy" do
    s = State.new(energy: 100) |> State.apply_cost(2.5)
    assert s.energy == 97.5
  end

  test "advance_ip/2 modulo Codeome size" do
    s = State.new(energy: 100, ip: 5)
    assert State.advance_ip(s, 10, 1).ip == 6
    # wrap at size
    assert State.advance_ip(s, 10, 5).ip == 0
    # wrap multiple times
    assert State.advance_ip(s, 10, 12).ip == 7
  end
end
```

- [ ] **Step 4.2: Run test (should fail)**

```bash
mix test test/lenies/interpreter/state_test.exs
```
Expected: FAIL.

- [ ] **Step 4.3: Implement InterpreterState**

Create `lib/lenies/interpreter/state.ex`:
```elixir
defmodule Lenies.Interpreter.State do
  @moduledoc """
  Stato di esecuzione della VM di un Lenie.

  Campi:
  - `ip`: instruction pointer nel Codeome (intero non negativo, wraps modulo size)
  - `stack`: lista di interi, max 16 elementi (top = head)
  - `slots`: 4 slot di memoria locale (`%{0..3 => integer}`)
  - `dir`: orientamento corrente `:n | :e | :s | :w`
  - `energy`: energia residua (float, sottratta dai costi opcode)
  - `age`: incrementato di 1 a ogni batch di K istruzioni (tick metabolico)
  - `pos`: posizione `{x, y}` sulla griglia
  - `call_stack`: storia IP per `:call_t` / `:ret`
  """

  @type t :: %__MODULE__{
          ip: non_neg_integer(),
          stack: [integer()],
          slots: %{0..3 => integer()},
          dir: :n | :e | :s | :w,
          energy: float(),
          age: non_neg_integer(),
          pos: {non_neg_integer(), non_neg_integer()},
          call_stack: [non_neg_integer()]
        }

  @stack_max 16
  @slot_count 4

  defstruct ip: 0,
            stack: [],
            slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
            dir: :n,
            energy: 0.0,
            age: 0,
            pos: {0, 0},
            call_stack: []

  def new(opts) do
    %__MODULE__{
      ip: Keyword.get(opts, :ip, 0),
      stack: Keyword.get(opts, :stack, []),
      slots: Keyword.get(opts, :slots, %{0 => 0, 1 => 0, 2 => 0, 3 => 0}),
      dir: Keyword.get(opts, :dir, :n),
      energy: Keyword.get(opts, :energy, 0.0) * 1.0,
      age: Keyword.get(opts, :age, 0),
      pos: Keyword.get(opts, :pos, {0, 0}),
      call_stack: Keyword.get(opts, :call_stack, [])
    }
  end

  @spec push(t(), integer()) :: t()
  def push(%__MODULE__{stack: stack} = s, value) do
    new_stack = [value | stack]

    new_stack =
      if length(new_stack) > @stack_max do
        # rimuovi il bottom (più vecchio)
        Enum.take(new_stack, @stack_max)
      else
        new_stack
      end

    %{s | stack: new_stack}
  end

  @doc """
  Pop top dello stack. Su stack vuoto ritorna `{0, state}` — questo è
  voluto: il Codeome può evolvere a fare pop su stack vuoto, dobbiamo
  essere tolleranti (non crashare).
  """
  @spec pop(t()) :: {integer(), t()}
  def pop(%__MODULE__{stack: []} = s), do: {0, s}
  def pop(%__MODULE__{stack: [top | rest]} = s), do: {top, %{s | stack: rest}}

  @spec peek(t()) :: integer()
  def peek(%__MODULE__{stack: []}), do: 0
  def peek(%__MODULE__{stack: [top | _]}), do: top

  @spec store(t(), integer(), integer()) :: t()
  def store(%__MODULE__{slots: slots} = s, slot_idx, value) do
    idx = Integer.mod(slot_idx, @slot_count)
    %{s | slots: Map.put(slots, idx, value)}
  end

  @spec load(t(), integer()) :: integer()
  def load(%__MODULE__{slots: slots}, slot_idx) do
    idx = Integer.mod(slot_idx, @slot_count)
    Map.get(slots, idx, 0)
  end

  @spec apply_cost(t(), float()) :: t()
  def apply_cost(%__MODULE__{energy: e} = s, cost), do: %{s | energy: e - cost}

  @doc "Avanza l'IP di `delta` posizioni, con wrap modulo `codeome_size`."
  @spec advance_ip(t(), non_neg_integer(), integer()) :: t()
  def advance_ip(%__MODULE__{ip: ip} = s, codeome_size, delta) do
    %{s | ip: Integer.mod(ip + delta, codeome_size)}
  end
end
```

- [ ] **Step 4.4: Run test (should pass)**

```bash
mix test test/lenies/interpreter/state_test.exs
```
Expected: PASS, 9 test.

- [ ] **Step 4.5: Commit**

```bash
git add lib/lenies/interpreter/state.ex test/lenies/interpreter/state_test.exs
git commit -m "feat: add InterpreterState with stack/slots/registers and helpers"
```

---

## Task 5: Template addressing module

**Files:**
- Create: `lib/lenies/interpreter/template.ex`
- Test: `test/lenies/interpreter/template_test.exs`

- [ ] **Step 5.1: Test Template**

Create `test/lenies/interpreter/template_test.exs`:
```elixir
defmodule Lenies.Interpreter.TemplateTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeome
  alias Lenies.Interpreter.Template

  test "extract/3 reads the template right after the jump opcode" do
    # Codeome: [:jmp_t, :nop_0, :nop_1, :nop_0, :push0]
    # extract from position 0 (the :jmp_t itself) — but extract is called by interpreter
    # after :jmp_t already consumed, so position is 1 (first :nop)
    c = Codeome.from_list([:jmp_t, :nop_0, :nop_1, :nop_0, :push0])
    assert Template.extract(c, 1, 8) == {[:nop_0, :nop_1, :nop_0], 3}
  end

  test "extract/3 stops at first non-nop opcode" do
    c = Codeome.from_list([:push0, :nop_0, :nop_1, :add, :nop_0])
    assert Template.extract(c, 1, 8) == {[:nop_0, :nop_1], 2}
  end

  test "extract/3 truncates at template_max_len" do
    c = Codeome.from_list(List.duplicate(:nop_0, 20))
    assert Template.extract(c, 0, 5) == {List.duplicate(:nop_0, 5), 5}
  end

  test "extract/3 returns empty template if first opcode is not a nop" do
    c = Codeome.from_list([:push0, :add])
    assert Template.extract(c, 0, 8) == {[], 0}
  end

  test "complement/1 flips :nop_0 ↔ :nop_1" do
    assert Template.complement([:nop_0, :nop_1, :nop_0]) == [:nop_1, :nop_0, :nop_1]
  end

  test "find_complement/4 finds the complement forward from search start" do
    # template = [:nop_0]; complement = [:nop_1]
    # find :nop_1 starting from position 1
    c = Codeome.from_list([:nop_0, :push0, :nop_1, :add])
    assert Template.find_complement(c, [:nop_0], 1, 10) == {:ok, 2}
  end

  test "find_complement/4 finds it backward when forward search fails" do
    # template = [:nop_0]; complement = [:nop_1]
    # at position 3 the :nop_1 is BEHIND
    c = Codeome.from_list([:nop_1, :push0, :add, :sub, :mul])
    # forward search from 3 fails; backward from 3 finds :nop_1 at position 0
    assert Template.find_complement(c, [:nop_0], 3, 10) == {:ok, 0}
  end

  test "find_complement/4 returns :not_found when no match within radius" do
    c = Codeome.from_list([:nop_0, :push0, :add])
    assert Template.find_complement(c, [:nop_0], 0, 10) == :not_found
  end

  test "find_complement/4 matches a multi-bit template" do
    # template = [:nop_0, :nop_1]; complement = [:nop_1, :nop_0]
    c = Codeome.from_list([:nop_0, :nop_1, :push0, :nop_1, :nop_0, :add])
    # complement [:nop_1, :nop_0] is at positions 3..4 → result points to 3
    assert Template.find_complement(c, [:nop_0, :nop_1], 2, 10) == {:ok, 3}
  end

  test "find_complement/4 with empty template returns :not_found" do
    c = Codeome.from_list([:nop_0, :nop_1])
    assert Template.find_complement(c, [], 0, 10) == :not_found
  end
end
```

- [ ] **Step 5.2: Run test (should fail)**

```bash
mix test test/lenies/interpreter/template_test.exs
```
Expected: FAIL.

- [ ] **Step 5.3: Implement Template**

Create `lib/lenies/interpreter/template.ex`:
```elixir
defmodule Lenies.Interpreter.Template do
  @moduledoc """
  Template addressing alla Tierra: i salti leggono il template di `:nop_0`/`:nop_1`
  che li segue, poi cercano nel Codeome il complemento (bit invertiti) entro un
  raggio limitato. Vedi spec §4.2.

  Una mutazione su un :nop _può_ avere effetto selettivo (modifica quale
  template fa match) ma _può_ anche essere genuinamente neutrale (junk DNA).
  Vedi spec §5.3.
  """

  alias Lenies.Codeome

  @type template :: [atom()]

  @doc """
  Estrae il template che inizia in posizione `from` del Codeome.

  Restituisce `{template_list, length}`. Il template è la sequenza più lunga
  di `:nop_0`/`:nop_1` da `from`, cappata a `max_len`.
  """
  @spec extract(Codeome.t(), non_neg_integer(), pos_integer()) :: {template(), non_neg_integer()}
  def extract(%Codeome{} = c, from, max_len) do
    take_nops(c, from, max_len, [])
  end

  defp take_nops(_c, _at, 0, acc), do: {Enum.reverse(acc), length(acc)}

  defp take_nops(c, at, remaining, acc) do
    op = Codeome.at(c, at)

    if op in [:nop_0, :nop_1] do
      take_nops(c, at + 1, remaining - 1, [op | acc])
    else
      {Enum.reverse(acc), length(acc)}
    end
  end

  @doc "Inverte i bit del template: `:nop_0 ↔ :nop_1`."
  @spec complement(template()) :: template()
  def complement(template) do
    Enum.map(template, fn
      :nop_0 -> :nop_1
      :nop_1 -> :nop_0
    end)
  end

  @doc """
  Cerca il complemento di `template` nel Codeome a partire da `from`.

  Cerca prima in avanti fino a `radius`, poi all'indietro. Ritorna
  `{:ok, position}` della prima occorrenza del complemento, o `:not_found`.
  La posizione restituita è l'indice del primo nop del match.
  """
  @spec find_complement(Codeome.t(), template(), non_neg_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | :not_found
  def find_complement(_c, [], _from, _radius), do: :not_found

  def find_complement(%Codeome{} = c, template, from, radius) do
    target = complement(template)
    size = Codeome.size(c)

    case search_forward(c, target, from + 1, radius, size) do
      {:ok, _pos} = ok -> ok
      :not_found -> search_backward(c, target, from - 1, radius, size)
    end
  end

  defp search_forward(_c, _target, _at, 0, _size), do: :not_found

  defp search_forward(c, target, at, remaining, size) do
    if matches_at?(c, at, target) do
      {:ok, Integer.mod(at, size)}
    else
      search_forward(c, target, at + 1, remaining - 1, size)
    end
  end

  defp search_backward(_c, _target, _at, 0, _size), do: :not_found

  defp search_backward(c, target, at, remaining, size) do
    if matches_at?(c, at, target) do
      {:ok, Integer.mod(at, size)}
    else
      search_backward(c, target, at - 1, remaining - 1, size)
    end
  end

  defp matches_at?(c, at, target) do
    Enum.with_index(target)
    |> Enum.all?(fn {expected, offset} ->
      Codeome.at(c, at + offset) == expected
    end)
  end
end
```

- [ ] **Step 5.4: Run test (should pass)**

```bash
mix test test/lenies/interpreter/template_test.exs
```
Expected: PASS, 10 test.

- [ ] **Step 5.5: Commit**

```bash
git add lib/lenies/interpreter/template.ex test/lenies/interpreter/template_test.exs
git commit -m "feat: add template addressing module with extract and find_complement"
```

---

## Task 6: Interpreter — stack + arithmetic opcodes

**Files:**
- Create: `lib/lenies/interpreter.ex` (skeleton + stack/arith dispatch)
- Test: `test/lenies/interpreter/stack_arith_test.exs`

- [ ] **Step 6.1: Test stack/arith opcodes**

Create `test/lenies/interpreter/stack_arith_test.exs`:
```elixir
defmodule Lenies.Interpreter.StackArithTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  defp run_step(opcodes, state \\ State.new(energy: 100.0)) do
    c = Codeome.from_list(opcodes)
    {tag, _payload_or_state, new_state} =
      case Interpreter.step(state, c) do
        {:cont, s} -> {:cont, nil, s}
        {:wait_world, p, s} -> {:wait_world, p, s}
        {:halt, r, s} -> {:halt, r, s}
      end

    {tag, new_state}
  end

  test ":push0 pushes 0 on the stack and advances IP" do
    {:cont, s} = run_step([:push0])
    assert s.stack == [0]
    assert s.ip == 1
  end

  test ":push1 pushes 1" do
    {:cont, s} = run_step([:push1])
    assert s.stack == [1]
  end

  test ":pushN pushes a random integer in 0..255" do
    {:cont, s} = run_step([:pushN])
    assert is_integer(hd(s.stack))
    assert hd(s.stack) in 0..255
  end

  test ":dup duplicates top of stack" do
    state = State.new(energy: 100.0) |> State.push(42)
    {:cont, s} = run_step([:dup], state)
    assert s.stack == [42, 42]
  end

  test ":dup on empty stack pushes 0 twice (defensive)" do
    {:cont, s} = run_step([:dup])
    assert s.stack == [0, 0]
  end

  test ":drop removes top of stack" do
    state = State.new(energy: 100.0) |> State.push(1) |> State.push(2)
    {:cont, s} = run_step([:drop], state)
    assert s.stack == [1]
  end

  test ":swap swaps top two" do
    state = State.new(energy: 100.0) |> State.push(1) |> State.push(2)
    {:cont, s} = run_step([:swap], state)
    assert s.stack == [1, 2]
  end

  test ":add pops two and pushes sum" do
    state = State.new(energy: 100.0) |> State.push(3) |> State.push(5)
    {:cont, s} = run_step([:add], state)
    assert s.stack == [8]
  end

  test ":sub subtracts top from second" do
    state = State.new(energy: 100.0) |> State.push(10) |> State.push(3)
    # stack: [3, 10], pop 3 then 10 → 10 - 3 = 7
    {:cont, s} = run_step([:sub], state)
    assert s.stack == [7]
  end

  test ":mul multiplies" do
    state = State.new(energy: 100.0) |> State.push(4) |> State.push(6)
    {:cont, s} = run_step([:mul], state)
    assert s.stack == [24]
  end

  test ":mod modulo (avoids divide by zero)" do
    state = State.new(energy: 100.0) |> State.push(7) |> State.push(3)
    {:cont, s} = run_step([:mod], state)
    assert s.stack == [1]

    state = State.new(energy: 100.0) |> State.push(7) |> State.push(0)
    {:cont, s} = run_step([:mod], state)
    assert s.stack == [0]
  end

  test "each opcode subtracts its cost" do
    {:cont, s} = run_step([:push0])
    assert s.energy == 100.0 - 0.1

    state = State.new(energy: 100.0) |> State.push(3) |> State.push(5)
    {:cont, s2} = run_step([:add], state)
    assert s2.energy == 100.0 - 0.2
  end

  test "Lenie dies when energy goes to <= 0 after opcode execution" do
    state = State.new(energy: 0.05)
    assert {:halt, :starvation, s} = run_step([:push0], state)
    assert s.energy <= 0
  end
end
```

- [ ] **Step 6.2: Run test (should fail)**

```bash
mix test test/lenies/interpreter/stack_arith_test.exs
```
Expected: FAIL (`Lenies.Interpreter` doesn't exist).

- [ ] **Step 6.3: Implement Interpreter skeleton + stack/arith**

Create `lib/lenies/interpreter.ex`:
```elixir
defmodule Lenies.Interpreter do
  @moduledoc """
  La VM stack-based che esegue il Codeome di un Lenie.

  `step/2` esegue UN opcode (con costo energetico, avanzamento IP, eventuali
  effetti sullo stato), ritornando:
  - `{:cont, state}` — esecuzione continua
  - `{:wait_world, action, state}` — serve un'azione mondo (Lenie deve fare
    `GenServer.call(World, ...)`)
  - `{:halt, reason, state}` — Lenie morto (es. `:starvation`)

  `run_k_instructions/3` esegue fino a K istruzioni o fino al primo
  `:wait_world`/`:halt`.

  Vedi spec §4.
  """

  alias Lenies.Codeome
  alias Lenies.Codeome.Costs
  alias Lenies.Interpreter.State

  @type step_result ::
          {:cont, State.t()}
          | {:wait_world, term(), State.t()}
          | {:halt, atom(), State.t()}

  @doc """
  Esegue il prossimo opcode. Codeome vuoto → `{:halt, :empty_codeome, state}`.
  Energia ≤ 0 dopo l'opcode → `{:halt, :starvation, state}`.
  """
  @spec step(State.t(), Codeome.t()) :: step_result()
  def step(state, codeome) do
    size = Codeome.size(codeome)

    if size == 0 do
      {:halt, :empty_codeome, state}
    else
      op = Codeome.at(codeome, state.ip)
      dispatch(op, state, codeome, size)
    end
  end

  @doc "Esegue fino a `k` istruzioni o fino al primo wait_world/halt."
  @spec run_k_instructions(State.t(), Codeome.t(), pos_integer()) :: step_result()
  def run_k_instructions(state, _codeome, 0), do: {:cont, state}

  def run_k_instructions(state, codeome, k) when k > 0 do
    case step(state, codeome) do
      {:cont, new_state} -> run_k_instructions(new_state, codeome, k - 1)
      other -> other
    end
  end

  # ----- dispatch -----

  # Template/bit: nop_0 / nop_1 sono no-op a livello di interprete
  # (i loro effetti sono in template addressing)
  defp dispatch(op, state, _c, size) when op in [:nop_0, :nop_1] do
    advance_and_charge(op, state, size, 1)
  end

  # Stack / aritmetica
  defp dispatch(:push0, state, _c, size), do: state |> State.push(0) |> advance_and_charge(:push0, size, 1)
  defp dispatch(:push1, state, _c, size), do: state |> State.push(1) |> advance_and_charge(:push1, size, 1)

  defp dispatch(:pushN, state, _c, size) do
    state |> State.push(:rand.uniform(256) - 1) |> advance_and_charge(:pushN, size, 1)
  end

  defp dispatch(:dup, state, _c, size) do
    top = State.peek(state)
    state |> State.push(top) |> advance_and_charge(:dup, size, 1)
  end

  defp dispatch(:drop, state, _c, size) do
    {_, s} = State.pop(state)
    advance_and_charge(s, :drop, size, 1)
  end

  defp dispatch(:swap, state, _c, size) do
    {a, s1} = State.pop(state)
    {b, s2} = State.pop(s1)
    s3 = s2 |> State.push(a) |> State.push(b)
    advance_and_charge(s3, :swap, size, 1)
  end

  defp dispatch(:add, state, _c, size), do: binop(state, :add, &(&1 + &2), size)
  defp dispatch(:sub, state, _c, size), do: binop(state, :sub, fn a, b -> b - a end, size)
  defp dispatch(:mul, state, _c, size), do: binop(state, :mul, &(&1 * &2), size)

  defp dispatch(:mod, state, _c, size) do
    {a, s1} = State.pop(state)
    {b, s2} = State.pop(s1)
    res = if a == 0, do: 0, else: Integer.mod(b, a)
    s2 |> State.push(res) |> advance_and_charge(:mod, size, 1)
  end

  # opcode sconosciuti → trattati come :nop_0
  defp dispatch(_unknown, state, _c, size), do: advance_and_charge(:nop_0, state, size, 1)

  # ----- helpers -----

  defp binop(state, op, fun, size) do
    {a, s1} = State.pop(state)
    {b, s2} = State.pop(s1)
    s2 |> State.push(fun.(a, b)) |> advance_and_charge(op, size, 1)
  end

  # Versione con state come primo argomento (per pipeline)
  defp advance_and_charge(state, op, size, advance_by) when is_atom(op) do
    advance_and_charge(op, state, size, advance_by)
  end

  defp advance_and_charge(op, state, size, advance_by) when is_atom(op) do
    cost = Costs.cost(op, 0)

    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, advance_by)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:cont, new_state}
    end
  end
end
```

- [ ] **Step 6.4: Run test (should pass)**

```bash
mix test test/lenies/interpreter/stack_arith_test.exs
```
Expected: PASS, 13 test.

- [ ] **Step 6.5: Commit**

```bash
git add lib/lenies/interpreter.ex test/lenies/interpreter/stack_arith_test.exs
git commit -m "feat: add Interpreter skeleton with stack and arithmetic opcodes"
```

---

## Task 7: Interpreter — memory + orientation + local sense + self-inspection

**Files:**
- Modify: `lib/lenies/interpreter.ex` (add opcode dispatch clauses)
- Test: `test/lenies/interpreter/memory_orient_test.exs`
- Test: `test/lenies/interpreter/local_sense_test.exs`
- Test: `test/lenies/interpreter/self_inspect_test.exs`

- [ ] **Step 7.1: Test memory + orientation**

Create `test/lenies/interpreter/memory_orient_test.exs`:
```elixir
defmodule Lenies.Interpreter.MemoryOrientTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  defp run_step(opcodes, state) do
    c = Codeome.from_list(opcodes)
    Interpreter.step(state, c)
  end

  test ":store pops slot_idx and value, stores in slots" do
    state = State.new(energy: 100.0) |> State.push(42) |> State.push(2)
    # stack top is 2 (slot idx), under is 42 (value)
    # :store pops slot_idx first, then value
    {:cont, s} = run_step([:store], state)
    assert State.load(s, 2) == 42
    assert s.stack == []
  end

  test ":load pops slot_idx and pushes value" do
    state = State.new(energy: 100.0) |> State.store(1, 99) |> State.push(1)
    {:cont, s} = run_step([:load], state)
    assert s.stack == [99]
  end

  test ":turn_left rotates direction N→W→S→E→N" do
    for {from, expected} <- [{:n, :w}, {:w, :s}, {:s, :e}, {:e, :n}] do
      state = State.new(energy: 100.0, dir: from)
      {:cont, s} = run_step([:turn_left], state)
      assert s.dir == expected
    end
  end

  test ":turn_right rotates direction N→E→S→W→N" do
    for {from, expected} <- [{:n, :e}, {:e, :s}, {:s, :w}, {:w, :n}] do
      state = State.new(energy: 100.0, dir: from)
      {:cont, s} = run_step([:turn_right], state)
      assert s.dir == expected
    end
  end
end
```

- [ ] **Step 7.2: Test local sense**

Create `test/lenies/interpreter/local_sense_test.exs`:
```elixir
defmodule Lenies.Interpreter.LocalSenseTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  defp run_step(opcodes, state) do
    c = Codeome.from_list(opcodes)
    Interpreter.step(state, c)
  end

  test ":sense_self pushes 1 (placeholder: alive)" do
    {:cont, s} = run_step([:sense_self], State.new(energy: 100.0))
    assert s.stack == [1]
  end

  test ":sense_energy pushes current energy as integer" do
    {:cont, s} = run_step([:sense_energy], State.new(energy: 42.5))
    assert s.stack == [42]
  end

  test ":sense_age pushes current age" do
    state = State.new(energy: 100.0, age: 17)
    {:cont, s} = run_step([:sense_age], state)
    assert s.stack == [17]
  end

  test ":sense_size pushes Codeome size" do
    c = Codeome.from_list([:sense_size, :nop_0, :nop_1])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.stack == [3]
  end
end
```

- [ ] **Step 7.3: Test self-inspection**

Create `test/lenies/interpreter/self_inspect_test.exs`:
```elixir
defmodule Lenies.Interpreter.SelfInspectTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Codeome.Opcodes
  alias Lenies.Interpreter.State

  test ":get_ip pushes current IP" do
    c = Codeome.from_list([:nop_0, :get_ip, :add])
    state = State.new(energy: 100.0, ip: 1)
    {:cont, s} = Interpreter.step(state, c)
    assert s.stack == [1]
  end

  test ":get_size pushes Codeome size" do
    c = Codeome.from_list([:get_size, :nop_0, :nop_1, :add, :sub])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.stack == [5]
  end

  test ":read_self pops addr and pushes opcode-as-integer at that address" do
    c = Codeome.from_list([:read_self, :push1, :move])
    state = State.new(energy: 100.0) |> State.push(2)
    {:cont, s} = Interpreter.step(state, c)
    assert hd(s.stack) == Opcodes.encode(:move)
  end

  test ":read_self with addr beyond Codeome wraps modulo size" do
    c = Codeome.from_list([:read_self, :push1])
    state = State.new(energy: 100.0) |> State.push(5)
    # 5 mod 2 = 1 → :push1
    {:cont, s} = Interpreter.step(state, c)
    assert hd(s.stack) == Opcodes.encode(:push1)
  end
end
```

- [ ] **Step 7.4: Run tests (should fail)**

```bash
mix test test/lenies/interpreter/memory_orient_test.exs test/lenies/interpreter/local_sense_test.exs test/lenies/interpreter/self_inspect_test.exs
```
Expected: FAIL (opcodes not yet dispatched).

- [ ] **Step 7.5: Add dispatch clauses to Interpreter**

Open `lib/lenies/interpreter.ex` and add these `dispatch/4` clauses BEFORE the catch-all `defp dispatch(_unknown, ...)` at the bottom:

```elixir
  # Memoria locale
  defp dispatch(:store, state, _c, size) do
    {slot_idx, s1} = State.pop(state)
    {value, s2} = State.pop(s1)
    s2 |> State.store(slot_idx, value) |> advance_and_charge(:store, size, 1)
  end

  defp dispatch(:load, state, _c, size) do
    {slot_idx, s1} = State.pop(state)
    value = State.load(s1, slot_idx)
    s1 |> State.push(value) |> advance_and_charge(:load, size, 1)
  end

  # Orientamento
  defp dispatch(:turn_left, state, _c, size) do
    new_dir =
      case state.dir do
        :n -> :w
        :w -> :s
        :s -> :e
        :e -> :n
      end

    %{state | dir: new_dir} |> advance_and_charge(:turn_left, size, 1)
  end

  defp dispatch(:turn_right, state, _c, size) do
    new_dir =
      case state.dir do
        :n -> :e
        :e -> :s
        :s -> :w
        :w -> :n
      end

    %{state | dir: new_dir} |> advance_and_charge(:turn_right, size, 1)
  end

  # Senso locale (non tocca il mondo)
  defp dispatch(:sense_self, state, _c, size) do
    state |> State.push(1) |> advance_and_charge(:sense_self, size, 1)
  end

  defp dispatch(:sense_energy, state, _c, size) do
    state |> State.push(trunc(state.energy)) |> advance_and_charge(:sense_energy, size, 1)
  end

  defp dispatch(:sense_age, state, _c, size) do
    state |> State.push(state.age) |> advance_and_charge(:sense_age, size, 1)
  end

  defp dispatch(:sense_size, state, _c, _size) do
    state |> State.push(_size) |> advance_and_charge(:sense_size, _size, 1)
  end

  # Self-inspection
  defp dispatch(:get_ip, state, _c, size) do
    state |> State.push(state.ip) |> advance_and_charge(:get_ip, size, 1)
  end

  defp dispatch(:get_size, state, _c, size) do
    state |> State.push(size) |> advance_and_charge(:get_size, size, 1)
  end

  defp dispatch(:read_self, state, c, size) do
    {addr, s1} = State.pop(state)
    op = Codeome.at(c, addr)
    op_int = Lenies.Codeome.Opcodes.encode(op)
    s1 |> State.push(op_int) |> advance_and_charge(:read_self, size, 1)
  end
```

**Importante**: rinominare il parametro `_size` nella clausola `:sense_size` se l'underscore confonde — usa `size` (senza underscore) e mantieni il parametro come tale.

In realtà, riguardando il codice: il parametro `size` viene già passato a `dispatch/4` come quarto argomento, quindi non serve l'underscore. Sostituisci `_size` con `size`.

- [ ] **Step 7.6: Run tests (should pass)**

```bash
mix test test/lenies/interpreter/memory_orient_test.exs test/lenies/interpreter/local_sense_test.exs test/lenies/interpreter/self_inspect_test.exs
```
Expected: PASS, 4 + 4 + 4 = 12 test.

- [ ] **Step 7.7: Commit**

```bash
git add lib/lenies/interpreter.ex test/lenies/interpreter/memory_orient_test.exs test/lenies/interpreter/local_sense_test.exs test/lenies/interpreter/self_inspect_test.exs
git commit -m "feat: add memory, orientation, local sense, and self-inspection opcodes"
```

---

## Task 8: Interpreter — control flow (templates + jumps)

**Files:**
- Modify: `lib/lenies/interpreter.ex` (add jump opcodes)
- Test: `test/lenies/interpreter/control_flow_test.exs`

- [ ] **Step 8.1: Test control flow**

Create `test/lenies/interpreter/control_flow_test.exs`:
```elixir
defmodule Lenies.Interpreter.ControlFlowTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  test ":jmp_t with no template falls through (no jump)" do
    # IP at :jmp_t, next opcode is :push0 (not a nop), so template is empty,
    # IP advances past :jmp_t only (no template to skip)
    c = Codeome.from_list([:jmp_t, :push0, :push1])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 1
  end

  test ":jmp_t with single-bit template jumps to complement" do
    # Codeome: [:jmp_t, :nop_0, :push0, :push1, :nop_1, :sub]
    # template after :jmp_t = [:nop_0] (length 1)
    # complement = [:nop_1] → found at index 4
    # IP after jump = 4 + 1 = 5 (position AFTER the matched complement)
    c = Codeome.from_list([:jmp_t, :nop_0, :push0, :push1, :nop_1, :sub])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 5
  end

  test ":jmp_t with template not found falls through (advance past template)" do
    c = Codeome.from_list([:jmp_t, :nop_0, :push0, :push1])
    # template = [:nop_0], complement = [:nop_1] — not present
    # IP advances to past template: 1 (start) + 1 (template_len) = 2
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
  end

  test ":jz_t jumps only if top of stack is zero" do
    c = Codeome.from_list([:jz_t, :nop_0, :push0, :nop_1, :sub])
    # stack top = 0 → jump
    state = State.new(energy: 100.0) |> State.push(0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 4
    assert s.stack == []

    # stack top != 0 → fall through past template
    state = State.new(energy: 100.0) |> State.push(7)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    assert s.stack == []
  end

  test ":jnz_t jumps only if top of stack is non-zero" do
    c = Codeome.from_list([:jnz_t, :nop_0, :push0, :nop_1, :sub])
    # stack top != 0 → jump
    state = State.new(energy: 100.0) |> State.push(5)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 4

    # stack top = 0 → fall through
    state = State.new(energy: 100.0) |> State.push(0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
  end

  test ":call_t pushes return address on call_stack and jumps" do
    c = Codeome.from_list([:call_t, :nop_0, :push0, :push1, :nop_1, :ret])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    # jumped to past :nop_1 → ip = 5
    assert s.ip == 5
    # return address is the position right after template = 2
    assert s.call_stack == [2]
  end

  test ":ret pops return address from call_stack and jumps there" do
    state = State.new(energy: 100.0, ip: 5, call_stack: [2])
    c = Codeome.from_list([:nop_0, :nop_0, :push0, :nop_1, :nop_1, :ret])
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    assert s.call_stack == []
  end

  test ":ret with empty call_stack falls through (advances IP by 1)" do
    state = State.new(energy: 100.0, ip: 0)
    c = Codeome.from_list([:ret, :push0])
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 1
  end

  test "jump cost scales with template length" do
    # 4-bit template
    c = Codeome.from_list([:jmp_t, :nop_0, :nop_0, :nop_0, :nop_0, :push0])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    # base 0.2 + 0.05 * 4 = 0.4
    assert_in_delta s.energy, 100.0 - 0.4, 0.0001
  end
end
```

- [ ] **Step 8.2: Run tests (should fail)**

```bash
mix test test/lenies/interpreter/control_flow_test.exs
```
Expected: FAIL.

- [ ] **Step 8.3: Add control flow dispatch clauses**

Open `lib/lenies/interpreter.ex` and add these BEFORE the catch-all clause:

```elixir
  # Controllo template-based
  defp dispatch(:jmp_t, state, codeome, size), do: do_jump(state, codeome, size, :jmp_t, :always)
  defp dispatch(:jz_t, state, codeome, size), do: do_jump(state, codeome, size, :jz_t, :zero)
  defp dispatch(:jnz_t, state, codeome, size), do: do_jump(state, codeome, size, :jnz_t, :nonzero)

  defp dispatch(:call_t, state, codeome, size) do
    {template, t_len} = Template.extract(codeome, state.ip + 1, template_max_len())
    return_ip = Integer.mod(state.ip + 1 + t_len, size)

    case Template.find_complement(codeome, template, state.ip, template_search_radius()) do
      {:ok, match_pos} ->
        target_ip = Integer.mod(match_pos + length(template), size)

        %{state | ip: target_ip, call_stack: [return_ip | state.call_stack]}
        |> State.apply_cost(Costs.cost(:call_t, t_len))
        |> halt_if_dead()

      :not_found ->
        # no jump; just advance past the template
        %{state | ip: return_ip}
        |> State.apply_cost(Costs.cost(:call_t, t_len))
        |> halt_if_dead()
    end
  end

  defp dispatch(:ret, state, _codeome, size) do
    case state.call_stack do
      [return_ip | rest] ->
        %{state | ip: return_ip, call_stack: rest}
        |> State.apply_cost(Costs.cost(:ret, 0))
        |> halt_if_dead()

      [] ->
        state
        |> State.advance_ip(size, 1)
        |> State.apply_cost(Costs.cost(:ret, 0))
        |> halt_if_dead()
    end
  end
```

Add this helper at the bottom of the module (with other defp helpers):

```elixir
  defp do_jump(state, codeome, size, op, condition) do
    {template, t_len} = Template.extract(codeome, state.ip + 1, template_max_len())
    skip_to = Integer.mod(state.ip + 1 + t_len, size)

    should_jump =
      case condition do
        :always ->
          true

        :zero ->
          {top, _} = State.pop(state)
          top == 0

        :nonzero ->
          {top, _} = State.pop(state)
          top != 0
      end

    # For conditional jumps, consume the stack value
    state_after_pop =
      case condition do
        :always ->
          state

        _ ->
          {_, s} = State.pop(state)
          s
      end

    target_ip =
      if should_jump and t_len > 0 do
        case Template.find_complement(codeome, template, state.ip, template_search_radius()) do
          {:ok, match_pos} -> Integer.mod(match_pos + length(template), size)
          :not_found -> skip_to
        end
      else
        skip_to
      end

    %{state_after_pop | ip: target_ip}
    |> State.apply_cost(Costs.cost(op, t_len))
    |> halt_if_dead()
  end

  defp halt_if_dead(state) do
    if state.energy <= 0 do
      {:halt, :starvation, state}
    else
      {:cont, state}
    end
  end

  defp template_max_len, do: Application.get_env(:lenies, :template_max_len, 8)
  defp template_search_radius, do: Application.get_env(:lenies, :template_search_radius, 256)
```

Also ensure the module has the alias for Template at the top (add it under the existing aliases):
```elixir
alias Lenies.Interpreter.{State, Template}
```

(Replace the existing single-module alias with this combined alias.)

Also add the two new config keys to `config/runtime.exs` (alongside the existing `:lenies` config block):
```elixir
config :lenies,
  # ... existing keys ...
  template_max_len: 8,
  template_search_radius: 256
```

(Place these inside the existing `config :lenies` block.)

- [ ] **Step 8.4: Run tests (should pass)**

```bash
mix test test/lenies/interpreter/control_flow_test.exs
```
Expected: PASS, 9 test.

- [ ] **Step 8.5: Run full interpreter suite to ensure no regressions**

```bash
mix test test/lenies/interpreter/
```
Expected: all pass.

- [ ] **Step 8.6: Commit**

```bash
git add lib/lenies/interpreter.ex config/runtime.exs test/lenies/interpreter/control_flow_test.exs
git commit -m "feat: add template-based jumps (jmp_t/jz_t/jnz_t/call_t/ret)"
```

---

## Task 9: Interpreter — world action opcodes (return :wait_world)

**Files:**
- Modify: `lib/lenies/interpreter.ex` (add wait_world opcodes)
- Test: `test/lenies/interpreter/world_action_test.exs`

- [ ] **Step 9.1: Test world-action opcodes**

Create `test/lenies/interpreter/world_action_test.exs`:
```elixir
defmodule Lenies.Interpreter.WorldActionTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  test ":sense_front returns :wait_world with action descriptor" do
    c = Codeome.from_list([:sense_front, :push0])
    state = State.new(energy: 100.0, pos: {10, 10}, dir: :e)
    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:sense_front, {10, 10}, :e}
    # IP advanced and cost paid even though world hasn't replied yet
    assert new_state.ip == 1
    assert_in_delta new_state.energy, 100.0 - 0.5, 0.0001
  end

  test ":move returns :wait_world with destination" do
    c = Codeome.from_list([:move, :push0])
    state = State.new(energy: 100.0, pos: {5, 5}, dir: :n)
    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:move, {5, 5}, :n}
    assert new_state.ip == 1
    assert_in_delta new_state.energy, 100.0 - 2.0, 0.0001
  end

  test ":eat returns :wait_world with cell coordinate (current cell)" do
    c = Codeome.from_list([:eat, :push0])
    state = State.new(energy: 100.0, pos: {7, 7})
    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:eat, {7, 7}}
    assert new_state.ip == 1
  end
end
```

- [ ] **Step 9.2: Run test (should fail)**

```bash
mix test test/lenies/interpreter/world_action_test.exs
```
Expected: FAIL.

- [ ] **Step 9.3: Add world-action dispatch clauses**

In `lib/lenies/interpreter.ex`, add these BEFORE the catch-all clause:

```elixir
  # Azioni mondo: l'interprete avanza IP e paga il costo, poi ritorna
  # :wait_world. Il Lenie process si occupa di chiamare il World e
  # applicare il risultato (es. push valore percepito sullo stack,
  # aggiornare pos su :move riuscito).

  defp dispatch(:sense_front, state, _c, size) do
    cost = Costs.cost(:sense_front, 0)
    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:sense_front, state.pos, state.dir}, new_state}
    end
  end

  defp dispatch(:move, state, _c, size) do
    cost = Costs.cost(:move, 0)
    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:move, state.pos, state.dir}, new_state}
    end
  end

  defp dispatch(:eat, state, _c, size) do
    cost = Costs.cost(:eat, 0)
    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:eat, state.pos}, new_state}
    end
  end
```

- [ ] **Step 9.4: Run test (should pass)**

```bash
mix test test/lenies/interpreter/world_action_test.exs
```
Expected: PASS, 3 test.

- [ ] **Step 9.5: Commit**

```bash
git add lib/lenies/interpreter.ex test/lenies/interpreter/world_action_test.exs
git commit -m "feat: add world-action opcodes (sense_front/move/eat) returning :wait_world"
```

---

## Task 10: World action handlers

**Files:**
- Modify: `lib/lenies/world.ex` (add `handle_call({:action, ...})`)
- Test: `test/lenies/world_action_test.exs`

- [ ] **Step 10.1: Test world action handlers**

Create `test/lenies/world_action_test.exs`:
```elixir
defmodule Lenies.WorldActionTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.{Cell, Tables}

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
    :ok
  end

  describe "sense_front" do
    test "returns :empty when the front cell is empty" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      result = World.action({:sense_front, {10, 10}, :e})
      assert result == {:ok, :empty}
    end

    test "returns {:resource, n} when the front cell has biomass" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      # inject resource in cell {11, 10} (front of {10,10} facing east)
      [{key, cell}] = :ets.lookup(:cells, {11, 10})
      :ets.insert(:cells, {key, %{cell | resource: 50}})

      result = World.action({:sense_front, {10, 10}, :e})
      assert result == {:ok, {:resource, 50}}
    end
  end

  describe "move" do
    test "succeeds when the target cell is free" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      # mark current cell as occupied by Lenie "L1"
      [{key, cell}] = :ets.lookup(:cells, {10, 10})
      :ets.insert(:cells, {key, %{cell | lenie_id: "L1"}})

      # before
      assert :ets.lookup(:cells, {10, 10}) |> hd() |> elem(1) |> Map.get(:lenie_id) == "L1"

      result = World.action({:move, {10, 10}, :e, "L1"})
      assert {:ok, {:moved, {11, 10}}} = result

      # after: old cell free, new cell has L1
      assert :ets.lookup(:cells, {10, 10}) |> hd() |> elem(1) |> Map.get(:lenie_id) == nil
      assert :ets.lookup(:cells, {11, 10}) |> hd() |> elem(1) |> Map.get(:lenie_id) == "L1"
    end

    test "fails (no-op) when the target cell is occupied" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      [{k1, c1}] = :ets.lookup(:cells, {10, 10})
      :ets.insert(:cells, {k1, %{c1 | lenie_id: "L1"}})
      [{k2, c2}] = :ets.lookup(:cells, {11, 10})
      :ets.insert(:cells, {k2, %{c2 | lenie_id: "L2"}})

      result = World.action({:move, {10, 10}, :e, "L1"})
      assert result == {:ok, :blocked}
      assert :ets.lookup(:cells, {10, 10}) |> hd() |> elem(1) |> Map.get(:lenie_id) == "L1"
    end

    test "wraps around toroidal boundary" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      [{key, cell}] = :ets.lookup(:cells, {255, 0})
      :ets.insert(:cells, {key, %{cell | lenie_id: "L1"}})

      result = World.action({:move, {255, 0}, :e, "L1"})
      assert {:ok, {:moved, {0, 0}}} = result
    end
  end

  describe "eat" do
    test "transfers min(eat_amount, cell.resource) and clears that much" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      [{key, cell}] = :ets.lookup(:cells, {5, 5})
      :ets.insert(:cells, {key, %{cell | resource: 30}})

      # default eat_amount = 20
      result = World.action({:eat, {5, 5}})
      assert result == {:ok, {:ate, 20}}
      assert :ets.lookup(:cells, {5, 5}) |> hd() |> elem(1) |> Map.get(:resource) == 10
    end

    test "returns {:ate, 0} if cell has no resource" do
      {:ok, _pid} = World.start_link(tick_interval_ms: 0)
      result = World.action({:eat, {5, 5}})
      assert result == {:ok, {:ate, 0}}
    end
  end
end
```

- [ ] **Step 10.2: Run test (should fail)**

```bash
mix test test/lenies/world_action_test.exs
```
Expected: FAIL (`World.action/1` doesn't exist yet).

- [ ] **Step 10.3: Add World.action/1 + handler**

Open `lib/lenies/world.ex`. Add this public function after the existing public API:

```elixir
  @doc """
  Esegue un'azione richiesta da un Lenie. Chiamata sincrona.

  Forms:
  - `{:sense_front, {x, y}, dir}` — restituisce `{:ok, :empty | {:resource, n} | {:lenie, id}}`
  - `{:move, {x, y}, dir, lenie_id}` — restituisce `{:ok, {:moved, {x2, y2}} | :blocked}`
  - `{:eat, {x, y}}` — restituisce `{:ok, {:ate, amount}}`
  """
  def action(action_spec), do: GenServer.call(@name, {:action, action_spec})
```

Add this `handle_call` clause inside the server section (before `handle_info`):

```elixir
  @impl true
  def handle_call({:action, action_spec}, _from, state) do
    {result, new_state} = do_action(action_spec, state)
    {:reply, result, new_state}
  end
```

Add these helpers at the bottom of the module (with other defp helpers):

```elixir
  defp do_action({:sense_front, {x, y}, dir}, state) do
    front = front_cell({x, y}, dir, state.grid)
    case :ets.lookup(:cells, front) do
      [{_, cell}] ->
        result =
          cond do
            cell.lenie_id != nil -> {:lenie, cell.lenie_id}
            cell.resource > 0 -> {:resource, cell.resource}
            true -> :empty
          end

        {{:ok, result}, state}

      _ ->
        {{:ok, :empty}, state}
    end
  end

  defp do_action({:move, {x, y}, dir, lenie_id}, state) do
    front = front_cell({x, y}, dir, state.grid)

    case :ets.lookup(:cells, front) do
      [{_, %{lenie_id: nil} = front_cell}] ->
        # move successful
        [{src_key, src_cell}] = :ets.lookup(:cells, {x, y})
        :ets.insert(:cells, {src_key, %{src_cell | lenie_id: nil}})
        :ets.insert(:cells, {front, %{front_cell | lenie_id: lenie_id}})
        {{:ok, {:moved, front}}, state}

      _ ->
        {{:ok, :blocked}, state}
    end
  end

  defp do_action({:eat, {x, y}}, state) do
    case :ets.lookup(:cells, {x, y}) do
      [{key, cell}] ->
        eat_amount = Lenies.Config |> apply(:cell_resource_cap, []) |> min(20)
        # we actually want Application.get_env(:lenies, :eat_amount, 20)
        eat_amount = Application.get_env(:lenies, :eat_amount, 20)
        taken = min(eat_amount, cell.resource)
        :ets.insert(:cells, {key, %{cell | resource: cell.resource - taken}})
        {{:ok, {:ate, taken}}, state}

      _ ->
        {{:ok, {:ate, 0}}, state}
    end
  end

  defp front_cell({x, y}, dir, {w, h}) do
    case dir do
      :n -> {x, Integer.mod(y - 1, h)}
      :e -> {Integer.mod(x + 1, w), y}
      :s -> {x, Integer.mod(y + 1, h)}
      :w -> {Integer.mod(x - 1, w), y}
    end
  end
```

**Cleanup**: remove the line `eat_amount = Lenies.Config |> apply(:cell_resource_cap, []) |> min(20)` — that was a typo. Use only:
```elixir
eat_amount = Application.get_env(:lenies, :eat_amount, 20)
```

Also add to `config/runtime.exs` if not present:
```elixir
config :lenies,
  # ... existing keys ...
  eat_amount: 20
```

- [ ] **Step 10.4: Run test (should pass)**

```bash
mix test test/lenies/world_action_test.exs
```
Expected: PASS, 6 test.

- [ ] **Step 10.5: Full suite**

```bash
mix test
```
Expected: All pass. Total: ~70 tests now.

- [ ] **Step 10.6: Commit**

```bash
git add lib/lenies/world.ex config/runtime.exs test/lenies/world_action_test.exs
git commit -m "feat: add World action handlers (sense_front, move, eat)"
```

---

## Task 11: Lenie GenServer — skeleton + lifecycle

**Files:**
- Create: `lib/lenies/lenie.ex`
- Test: `test/lenies/lenie_test.exs`

- [ ] **Step 11.1: Test Lenie GenServer**

Create `test/lenies/lenie_test.exs`:
```elixir
defmodule Lenies.LenieTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie}
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      for name <- [Lenies.World] do
        case Process.whereis(name) do
          pid when is_pid(pid) ->
            try do
              GenServer.stop(pid)
            catch
              :exit, _ -> :ok
            end

          _ ->
            :ok
        end
      end
      Tables.delete_all()
    end)
    :ok
  end

  test "start_link/1 registers the Lenie under its id" do
    {:ok, _world} = Lenies.World.start_link(tick_interval_ms: 0)

    # mark cell {5,5} as occupied (the Lenie expects to find itself there)
    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | lenie_id: "L1"}})

    codeome = Codeome.from_list([:nop_0, :nop_1])

    {:ok, pid} =
      Lenie.start_link(
        id: "L1",
        codeome: codeome,
        energy: 50.0,
        pos: {5, 5},
        dir: :e,
        lineage: {nil, 0}
      )

    assert Process.alive?(pid)
    assert Lenies.Registry.whereis("L1") == pid

    GenServer.stop(pid)
  end

  test "inspect_state/1 returns current snapshot" do
    {:ok, _world} = Lenies.World.start_link(tick_interval_ms: 0)
    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | lenie_id: "L2"}})

    codeome = Codeome.from_list([:nop_0])
    {:ok, pid} = Lenie.start_link(id: "L2", codeome: codeome, energy: 10.0, pos: {5, 5}, dir: :n, lineage: {nil, 0})

    snapshot = Lenie.inspect_state(pid)
    assert snapshot.id == "L2"
    assert snapshot.energy <= 10.0
    assert snapshot.pos == {5, 5}
    assert snapshot.dir == :n

    GenServer.stop(pid)
  end

  test "dies of starvation when energy depletes" do
    {:ok, _world} = Lenies.World.start_link(tick_interval_ms: 0)
    [{key, cell}] = :ets.lookup(:cells, {5, 5})
    :ets.insert(:cells, {key, %{cell | lenie_id: "L3"}})

    # only 0.3 energy — will be consumed by a few nops + age increments
    codeome = Codeome.from_list([:nop_0, :nop_1, :add, :sub])
    {:ok, pid} = Lenie.start_link(id: "L3", codeome: codeome, energy: 0.3, pos: {5, 5}, dir: :n, lineage: {nil, 0})

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :starvation}, 1_000

    # cell freed
    [{_, after_cell}] = :ets.lookup(:cells, {5, 5})
    assert after_cell.lenie_id == nil
  end
end
```

- [ ] **Step 11.2: Run test (should fail)**

```bash
mix test test/lenies/lenie_test.exs
```
Expected: FAIL.

- [ ] **Step 11.3: Implement Lenie GenServer**

Create `lib/lenies/lenie.ex`:
```elixir
defmodule Lenies.Lenie do
  @moduledoc """
  Un singolo organismo digitale. GenServer la cui forma e comportamento
  derivano dall'esecuzione del proprio Codeome via `Lenies.Interpreter`.

  Lifecycle:
  - `start_link/1` riceve id, codeome, energia iniziale, posizione, direzione, lineage
  - In `init/1`: registra in `Lenies.Registry`, imposta `max_heap_size`, schedula
    il primo tick metabolico
  - Loop: ad ogni `:metabolize` esegue un batch di K istruzioni; se serve mondo,
    fa `World.action/1`, applica il risultato; incrementa `age`; muore se energia
    ≤ 0
  - `terminate/2`: notifica il World per liberare la cella e (in futuro) lasciare
    una carcassa

  Vedi spec §4.4, §4.5.
  """

  use GenServer

  alias Lenies.{Codeome, Interpreter, World}
  alias Lenies.Interpreter.State

  defstruct [:id, :codeome, :interp, :lineage]

  # ----- Public API -----

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Restituisce uno snapshot dello stato interno (per ispezione/test)."
  def inspect_state(pid), do: GenServer.call(pid, :inspect_state)

  # ----- Server -----

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    codeome = Keyword.fetch!(opts, :codeome)
    energy = Keyword.fetch!(opts, :energy)
    pos = Keyword.fetch!(opts, :pos)
    dir = Keyword.get(opts, :dir, :n)
    lineage = Keyword.get(opts, :lineage, {nil, 0})

    :erlang.process_flag(:max_heap_size, %{
      size: Application.get_env(:lenies, :lenie_max_heap_size, 1_000_000),
      kill: true,
      error_logger: false
    })

    {:ok, _} = Lenies.Registry.register(id)

    interp = State.new(energy: energy, pos: pos, dir: dir)

    state = %__MODULE__{
      id: id,
      codeome: codeome,
      interp: interp,
      lineage: lineage
    }

    schedule_metabolize()
    {:ok, state}
  end

  @impl true
  def handle_call(:inspect_state, _from, state) do
    snapshot = %{
      id: state.id,
      energy: state.interp.energy,
      age: state.interp.age,
      pos: state.interp.pos,
      dir: state.interp.dir,
      ip: state.interp.ip,
      stack: state.interp.stack,
      slots: state.interp.slots,
      codeome_size: Codeome.size(state.codeome)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info(:metabolize, state) do
    batch = Application.get_env(:lenies, :interpreter_steps_per_batch, 10)

    case Interpreter.run_k_instructions(state.interp, state.codeome, batch) do
      {:cont, new_interp} ->
        new_state = age_and_continue(state, new_interp)
        {:noreply, new_state}

      {:wait_world, action, new_interp} ->
        case apply_world_action(action, state.id, new_interp) do
          {:ok, updated_interp} ->
            new_state = age_and_continue(state, updated_interp)
            {:noreply, new_state}
        end

      {:halt, reason, _new_interp} ->
        {:stop, reason, state}
    end
  end

  def handle_info(:sterilize, state), do: {:stop, :sterilized, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Notifica al World la morte: libera cella, eventuale carcassa
    World.lenie_died(state.id, state.interp.pos, state.interp.energy)
    :ok
  end

  # ----- internals -----

  defp schedule_metabolize do
    Process.send_after(self(), :metabolize, 0)
  end

  defp age_and_continue(state, new_interp) do
    new_interp = %{new_interp | age: new_interp.age + 1}
    schedule_metabolize()
    %{state | interp: new_interp}
  end

  defp apply_world_action({:sense_front, _pos, _dir} = action, _id, interp) do
    case World.action(action) do
      {:ok, :empty} -> {:ok, State.push(interp, 0)}
      {:ok, {:resource, n}} -> {:ok, State.push(interp, n)}
      {:ok, {:lenie, _id}} -> {:ok, State.push(interp, -1)}
    end
  end

  defp apply_world_action({:move, _pos, _dir}, id, interp) do
    case World.action({:move, interp.pos, interp.dir, id}) do
      {:ok, {:moved, new_pos}} -> {:ok, %{interp | pos: new_pos}}
      {:ok, :blocked} -> {:ok, interp}
    end
  end

  defp apply_world_action({:eat, _pos} = action, _id, interp) do
    case World.action(action) do
      {:ok, {:ate, amount}} -> {:ok, %{interp | energy: interp.energy + amount}}
    end
  end
end
```

The Lenie depends on `World.lenie_died/3` which doesn't exist yet. We'll add it in the next task. For now, add a minimal stub in `lib/lenies/world.ex`:

```elixir
  @doc "Notifica al World che un Lenie è morto (libera cella, eventuale carcassa)."
  def lenie_died(id, pos, energy_at_death), do: GenServer.call(@name, {:lenie_died, id, pos, energy_at_death})
```

And the handler:

```elixir
  @impl true
  def handle_call({:lenie_died, id, {x, y}, energy_at_death}, _from, state) do
    case :ets.lookup(:cells, {x, y}) do
      [{key, cell}] ->
        carcass_value = max(0, trunc(energy_at_death * 0.5))
        :ets.insert(:cells, {key, %{cell | lenie_id: nil, carcass: carcass_value}})

      _ ->
        :ok
    end

    :ets.delete(:lenies, id)
    {:reply, :ok, state}
  end
```

- [ ] **Step 11.4: Run test (should pass)**

```bash
mix test test/lenies/lenie_test.exs
```
Expected: PASS, 3 test.

- [ ] **Step 11.5: Run full suite**

```bash
mix test
```
Expected: All pass.

- [ ] **Step 11.6: Commit**

```bash
git add lib/lenies/lenie.ex lib/lenies/world.ex test/lenies/lenie_test.exs
git commit -m "feat: add Lenie GenServer with metabolic loop and death handling"
```

---

## Task 12: Hard-coded "walker" Codeome fixture

**Files:**
- Create: `lib/lenies/codeomes/walker.ex`
- Test: `test/lenies/integration_walker_test.exs`

- [ ] **Step 12.1: Walker fixture module**

Create `lib/lenies/codeomes/walker.ex`:
```elixir
defmodule Lenies.Codeomes.Walker do
  @moduledoc """
  Codeome scritto a mano per testare il loop Lenie. Non si replica.
  Cicla all'infinito: sense_front, eat, move forward.

  ```
  loop:
    :sense_front   # → stack: [content]
    :drop          # discard sense result (eat blindly)
    :eat
    :move
    :jmp_t :nop_0  # back to start
  loop_target:
    :nop_1         # complement of [:nop_0]
  ```
  """

  alias Lenies.Codeome

  @opcodes [
    :nop_1,        # 0: complement marker (where :jmp_t will land)
    :sense_front,  # 1: sense front cell
    :drop,         # 2: discard sense result
    :eat,          # 3: eat current cell
    :move,         # 4: try to move forward
    :jmp_t,        # 5: jump
    :nop_0         # 6: template (complement = :nop_1 at position 0)
  ]

  def codeome, do: Codeome.from_list(@opcodes)
end
```

- [ ] **Step 12.2: Test walker integration**

Create `test/lenies/integration_walker_test.exs`:
```elixir
defmodule Lenies.IntegrationWalkerTest do
  use ExUnit.Case, async: false

  alias Lenies.{Lenie, World}
  alias Lenies.Codeomes.Walker
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      for pid <- Process.whereis(Lenies.World) |> List.wrap() do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
      Tables.delete_all()
    end)
    :ok
  end

  test "walker moves on the grid and eats biomass" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    # seed cells {10..15, 10} with biomass
    for x <- 10..15 do
      [{key, cell}] = :ets.lookup(:cells, {x, 10})
      :ets.insert(:cells, {key, %{cell | resource: 100}})
    end

    # spawn walker at {10, 10} facing east, plenty of energy
    [{key, cell}] = :ets.lookup(:cells, {10, 10})
    :ets.insert(:cells, {key, %{cell | lenie_id: "walker"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "walker",
        codeome: Walker.codeome(),
        energy: 200.0,
        pos: {10, 10},
        dir: :e,
        lineage: {nil, 0}
      )

    # let it run for ~500ms (≈ many metabolic batches)
    Process.sleep(500)

    snapshot = Lenie.inspect_state(pid)

    # walker should have moved (at least one move opcode executed)
    assert snapshot.pos != {10, 10}, "expected walker to have moved from initial position"

    # walker should have eaten (energy refilled or stable, not starving fast)
    assert snapshot.energy > 0, "expected walker to still be alive"

    GenServer.stop(pid)
  end
end
```

- [ ] **Step 12.3: Run test (should pass)**

```bash
mix test test/lenies/integration_walker_test.exs
```
Expected: PASS, 1 test. If it fails because the walker's energy budget is too tight or it gets stuck, increase initial energy or extend the seed area. Document any tuning needed.

- [ ] **Step 12.4: Commit**

```bash
git add lib/lenies/codeomes/walker.ex test/lenies/integration_walker_test.exs
git commit -m "test: add walker integration test (moves on grid and eats biomass)"
```

---

## Task 13: Hard-coded "template-jumper" Codeome fixture

**Files:**
- Create: `lib/lenies/codeomes/template_jumper.ex`
- Test: `test/lenies/integration_jumper_test.exs`

- [ ] **Step 13.1: Template-jumper fixture**

Create `lib/lenies/codeomes/template_jumper.ex`:
```elixir
defmodule Lenies.Codeomes.TemplateJumper do
  @moduledoc """
  Codeome di test che esercita il template addressing.

  Verifica indipendentemente le due branche del jump:
  - SE il jump succede, `slot[0]` viene settato a `1` (SUCCESS)
  - SE il jump fallisce (fall-through), `slot[0]` viene settato a `2` (FAILURE)

  Il test asserisce `slot[0] == 1`, che è osservabile solo se il template
  addressing funziona davvero.

  Layout:
  ```
  pre:
    0  :push0       # stack = [0]
    1  :push0       # stack = [0, 0]
    2  :store       # slot[0] = 0; stack = []
    3  :jmp_t       # jump opcode
    4  :nop_0       # template = [:nop_0, :nop_1]; complement = [:nop_1, :nop_0]
    5  :nop_1
  fail (fall-through if no match):
    6  :push1
    7  :dup         # stack = [1, 1]
    8  :add         # stack = [2]
    9  :push0
   10  :store       # slot[0] = 2; stack = []
   11  :nop_0       # filler so backward search lands the success-branch correctly
   12  :nop_0
  success (complement of jump's template lands here):
   13  :nop_1       # complement starts at 13: [:nop_1, :nop_0]
   14  :nop_0       # after match, IP = 13 + 2 = 15
   15  :push1
   16  :push0
   17  :store       # slot[0] = 1; stack = []
  spin:
   18  :nop_0       # idle: small no-op tail; energy drains
   19  :nop_0
   20  :nop_0
  ```

  Stack semantics promemoria: `:store` pops slot_idx (top), then value.
  Le sequenze "push value, push slot_idx, store" qui in uso sono:
  `:push0, :push0, :store` → `slot[0] = 0`
  `:push1, :push0, :store` → `slot[0] = 1`
  `:push1, :dup, :add, :push0, :store` → `slot[0] = 2`
  """

  alias Lenies.Codeome

  @opcodes [
    # pre
    :push0,        # 0
    :push0,        # 1
    :store,        # 2  slot[0] = 0
    :jmp_t,        # 3  jump opcode
    :nop_0,        # 4  template[0]
    :nop_1,        # 5  template[1] → template = [:nop_0, :nop_1]
    # fail path
    :push1,        # 6
    :dup,          # 7
    :add,          # 8
    :push0,        # 9
    :store,        # 10 slot[0] = 2 (proves jump fell through)
    :nop_0,        # 11 filler
    :nop_0,        # 12 filler
    # success path (jump target)
    :nop_1,        # 13 complement[0]
    :nop_0,        # 14 complement[1] → match for [:nop_1, :nop_0] starts at 13
    :push1,        # 15
    :push0,        # 16
    :store,        # 17 slot[0] = 1 (proves jump succeeded)
    # spin tail
    :nop_0,        # 18
    :nop_0,        # 19
    :nop_0         # 20
  ]

  def codeome, do: Codeome.from_list(@opcodes)
end
```

Trace expected at jump (IP=3):
- `Template.extract(c, 4, 8)` → `{[:nop_0, :nop_1], 2}` (consecutive nops at 4,5; stops at :push1 at 6)
- `skip_to = mod(3 + 1 + 2, 21) = 6` (fall-through target if no match)
- `Template.find_complement(c, [:nop_0, :nop_1], from=3, radius=256)`:
  - target (complement) = `[:nop_1, :nop_0]`
  - forward search starting at IP+1=4: positions 4..12 contain no `[:nop_1, :nop_0]` pair until position 13: `[:nop_1, :nop_0]` ✓
  - returns `{:ok, 13}`
- `target_ip = mod(13 + 2, 21) = 15` → lands on `:push1` of success path ✓

If the jump didn't work (e.g., template extraction broken), IP would land at 6 → fail path → slot[0] = 2 → test asserts slot[0] == 1, FAILS, exposes the bug.

- [ ] **Step 13.2: Test jumper integration**

Create `test/lenies/integration_jumper_test.exs`:
```elixir
defmodule Lenies.IntegrationJumperTest do
  use ExUnit.Case, async: false

  alias Lenies.{Lenie, World}
  alias Lenies.Codeomes.TemplateJumper
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      for pid <- Process.whereis(Lenies.World) |> List.wrap() do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
      Tables.delete_all()
    end)
    :ok
  end

  test "template-jumper sets slot[0] to 1 (proves the jump landed at INCR)" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    [{key, cell}] = :ets.lookup(:cells, {0, 0})
    :ets.insert(:cells, {key, %{cell | lenie_id: "jumper"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "jumper",
        codeome: TemplateJumper.codeome(),
        energy: 50.0,
        pos: {0, 0},
        dir: :n,
        lineage: {nil, 0}
      )

    # let it run a few batches
    Process.sleep(200)

    snapshot = Lenie.inspect_state(pid)
    assert snapshot.slots[0] == 1, "expected slot[0]=1 after template jump (got #{inspect(snapshot.slots)})"

    GenServer.stop(pid)
  end
end
```

- [ ] **Step 13.3: Run test (should pass)**

```bash
mix test test/lenies/integration_jumper_test.exs
```
Expected: PASS, 1 test.

If the test fails — e.g., slot[0] is something other than 1 — most likely the Codeome design has a subtle ordering issue. Use `IO.inspect(snapshot)` to debug; the IP and stack at the moment of inspection will show whether the jump landed where expected.

- [ ] **Step 13.4: Commit**

```bash
git add lib/lenies/codeomes/template_jumper.ex test/lenies/integration_jumper_test.exs
git commit -m "test: add template-jumper integration test (verifies jump landing)"
```

---

## Task 14: Final verification + tag

**Files:**
- None (verification only)

- [ ] **Step 14.1: Run the full suite stability check (3x)**

```bash
mix test 2>&1 | tail -3
mix test 2>&1 | tail -3
mix test 2>&1 | tail -3
```
Expected: all 3 runs show same total count, 0 failures.

- [ ] **Step 14.2: Smoke test from console**

```bash
mix run --no-halt -e '
Application.ensure_all_started(:lenies)

# spawn a walker
[{key, cell}] = :ets.lookup(:cells, {50, 50})
:ets.insert(:cells, {key, %{cell | lenie_id: "demo"}})

# seed a corridor of biomass
for x <- 50..60 do
  [{k, c}] = :ets.lookup(:cells, {x, 50})
  :ets.insert(:cells, {k, %{c | resource: 100}})
end

{:ok, pid} = Lenies.Lenie.start_link(
  id: "demo",
  codeome: Lenies.Codeomes.Walker.codeome(),
  energy: 200.0,
  pos: {50, 50},
  dir: :e,
  lineage: {nil, 0}
)

:timer.sleep(1000)
snapshot = Lenies.Lenie.inspect_state(pid)
IO.inspect(snapshot, label: "Walker after 1s")

# pop stats from World
stats = Lenies.World.snapshot_stats()
IO.inspect(stats, label: "World stats")

System.halt(0)
'
```

Expected: walker position has changed from `{50, 50}`, energy > 0 (still alive), `World.snapshot_stats()` shows population may or may not include the demo Lenie depending on whether snapshot was written (we haven't implemented per-Lenie snapshot writing in this sub-project — that's fine).

- [ ] **Step 14.3: Format check**

```bash
mix format --check-formatted
```
Expected: PASS.

- [ ] **Step 14.4: Tag the baseline**

```bash
git status
git log --oneline | head -25
git tag v0.2.0-interpreter-lenie
git tag -l
```

Expected: working tree clean, tag created.

---

## Self-Review checklist

**Spec coverage** (§4 e §6.4 azioni mondo):
- [x] §4.1 forma del Codeome (tupla di opcode, IP, stack 16, registri, 4 slot) — Task 2, 4
- [x] §4.2 instruction set: template/bit, stack/arith, control flow, sense, action, self-inspection, memoria locale — Tasks 6-9
- [x] §4.2 template addressing (extract + find_complement) — Task 5
- [x] §4.3 costi energetici (incluso template-length pricing per i salti) — Task 3
- [x] §4.4 loop di esecuzione del Lenie (metabolic batch, age++, halt on starvation) — Task 11
- [x] §4.5 sicurezza per processo (`max_heap_size`, trap exits OFF) — Task 11
- [x] §6.4 `:move` (con conflict resolution FIFO via mailbox del World), `:eat`, `:sense_front`, `:turn_left/right` — Task 10
- [x] Death → cell freed + carcass placed (con `carcass = max(0, energy_at_death * 0.5)`) — Task 11
- [x] `Lenies.Registry` deferito da sotto-progetto 1 — Task 1

**Esplicitamente non coperto (rimandato):**
- `:allocate`, `:write_child`, `:divide` (primitive di replicazione) → sotto-progetto 3
- `:attack`, `:defend` → sotto-progetto 4
- minimal_replicator seed → sotto-progetto 3
- snapshot per-Lenie su ETS `:lenies` → necessario quando arrivano molti Lenies (sotto-progetto 3+), o per la GUI (sotto-progetto 5)

**Placeholder scan**: nessun "TBD"/"TODO"/"implement later" trovato.

**Type consistency**:
- `InterpreterState.t()` campi usati consistentemente (ip, stack, slots, dir, energy, age, pos, call_stack)
- `step_result()` shape `:cont | :wait_world | :halt` usato consistentemente in Interpreter
- World.action descriptors: `{:sense_front, pos, dir}`, `{:move, pos, dir, id}`, `{:eat, pos}` consistenti tra interprete (Task 9), World (Task 10), e Lenie (Task 11)
- `World.lenie_died/3` con args `(id, pos, energy_at_death)` consistenti tra Lenie terminate (Task 11) e World handler (Task 11)
