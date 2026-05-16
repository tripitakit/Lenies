# Species Color (Phase A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render every Lenie on the dashboard canvas with a color derived deterministically from its `codeome_hash`, with the same color appearing on the species table swatch, on the per-species chart polyline, and on the carcass left behind when that species dies.

**Architecture:** Single shared `Lenies.SpeciesColor` module computes a stable hue from a `codeome_hash` via `:erlang.phash2`. The `lenies` canvas layer changes from a binary occupancy flag to a hue byte (`0..255`). A new fourth layer `carcass_hue` carries the species hue stored at the moment of death on the `Cell` struct. The JS canvas hook converts hue bytes to HSL fills with shared S=70%, L=55%; the Elixir hex formatter uses the same formula so the table swatch matches the canvas exactly.

**Tech Stack:** Elixir 1.19, Phoenix LiveView, ETS, ExUnit, vanilla JS (canvas hook).

**Spec:** `docs/superpowers/specs/2026-05-15-species-color.md`

---

## Task 1: `Lenies.SpeciesColor` module — deterministic hash→color

**Files:**
- Create: `lib/lenies/species_color.ex`
- Create: `test/lenies/species_color_test.exs`

- [ ] **Step 1: Write the failing test**

`test/lenies/species_color_test.exs`:

```elixir
defmodule Lenies.SpeciesColorTest do
  use ExUnit.Case, async: true

  alias Lenies.SpeciesColor

  describe "hue_byte/1" do
    test "is deterministic for the same hash" do
      hash = "abc123"
      assert SpeciesColor.hue_byte(hash) == SpeciesColor.hue_byte(hash)
    end

    test "is always in 1..255 (0 is reserved)" do
      for n <- 1..200 do
        hash = :crypto.strong_rand_bytes(16)
        byte = SpeciesColor.hue_byte(hash)
        assert byte >= 1 and byte <= 255, "got #{byte} for hash #{inspect(hash)}"
      end
    end

    test "produces a reasonable spread across distinct hashes" do
      hashes = for n <- 1..50, do: :crypto.strong_rand_bytes(16)
      bytes = Enum.map(hashes, &SpeciesColor.hue_byte/1)
      distinct = bytes |> MapSet.new() |> MapSet.size()
      assert distinct >= 30, "expected at least 30 distinct bytes for 50 hashes, got #{distinct}"
    end
  end

  describe "byte_to_hex/1" do
    test "returns a 7-character #RRGGBB string" do
      hex = SpeciesColor.byte_to_hex(1)
      assert String.length(hex) == 7
      assert String.starts_with?(hex, "#")
      assert hex =~ ~r/^#[0-9A-F]{6}$/
    end

    test "is deterministic" do
      assert SpeciesColor.byte_to_hex(42) == SpeciesColor.byte_to_hex(42)
    end

    test "different bytes produce different colors" do
      assert SpeciesColor.byte_to_hex(1) != SpeciesColor.byte_to_hex(128)
    end
  end

  describe "hex/1" do
    test "matches byte_to_hex(hue_byte(hash))" do
      hash = "any-hash-bytes"
      assert SpeciesColor.hex(hash) == SpeciesColor.byte_to_hex(SpeciesColor.hue_byte(hash))
    end

    test "is deterministic for the same hash" do
      assert SpeciesColor.hex("seed") == SpeciesColor.hex("seed")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/lenies/species_color_test.exs
```

Expected: module not found / undefined function errors for `Lenies.SpeciesColor.hue_byte/1` etc.

- [ ] **Step 3: Implement the module**

`lib/lenies/species_color.ex`:

```elixir
defmodule Lenies.SpeciesColor do
  @moduledoc """
  Deterministic mapping from a Lenie `codeome_hash` to a display color.

  Single source of truth for color across the dashboard:
    - canvas pixels (server emits a hue byte, JS converts byte → HSL fill)
    - species table swatch (hex string in the HTML)
    - per-species polyline in the telemetry chart

  Stability: derived from `:erlang.phash2`, so the same hash always maps to
  the same color across restarts and across the Elixir/JS divide (as long
  as the byte → hue formula stays in sync).
  """

  @saturation 0.70
  @lightness 0.55

  @doc """
  Hue byte 1..255 for a species hash.

  The value 0 is reserved on the wire to mean "no species on this cell",
  so this function never returns 0.
  """
  @spec hue_byte(binary()) :: 1..255
  def hue_byte(hash) when is_binary(hash) do
    :erlang.phash2(hash, 255) + 1
  end

  @doc "CSS hex color (#RRGGBB) for a species hash."
  @spec hex(binary()) :: String.t()
  def hex(hash) when is_binary(hash) do
    hash |> hue_byte() |> byte_to_hex()
  end

  @doc """
  Convert a hue byte 1..255 to a #RRGGBB hex string.

  Uses the same saturation/lightness pair as the JS canvas, so the table
  swatch and the pixel for that species are visually identical.
  """
  @spec byte_to_hex(1..255) :: String.t()
  def byte_to_hex(byte) when byte in 1..255 do
    hue_deg = (byte - 1) / 255 * 360
    {r, g, b} = hsl_to_rgb(hue_deg, @saturation, @lightness)
    "#" <> byte_hex(r) <> byte_hex(g) <> byte_hex(b)
  end

  defp hsl_to_rgb(h, s, l) do
    c = (1 - abs(2 * l - 1)) * s
    h_prime = h / 60
    x = c * (1 - abs(:math.fmod(h_prime, 2) - 1))

    {r1, g1, b1} =
      cond do
        h_prime < 1 -> {c, x, 0}
        h_prime < 2 -> {x, c, 0}
        h_prime < 3 -> {0, c, x}
        h_prime < 4 -> {0, x, c}
        h_prime < 5 -> {x, 0, c}
        true -> {c, 0, x}
      end

    m = l - c / 2
    {round((r1 + m) * 255), round((g1 + m) * 255), round((b1 + m) * 255)}
  end

  defp byte_hex(b) do
    b
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/lenies/species_color_test.exs
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/lenies/species_color.ex test/lenies/species_color_test.exs
git commit -m "feat: Lenies.SpeciesColor — deterministic hash→HSL color"
```

---

## Task 2: `Cell.carcass_hue` field + decay clears hue at zero

**Files:**
- Modify: `lib/lenies/world/cell.ex`
- Modify: `test/lenies/world/cell_test.exs` (create if it doesn't exist; otherwise put tests in `test/lenies/world_test.exs`)

- [ ] **Step 1: Check whether `test/lenies/world/cell_test.exs` exists**

```bash
ls test/lenies/world/cell_test.exs 2>&1
```

If it doesn't exist, create it with:

```elixir
defmodule Lenies.World.CellTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Cell
end
```

- [ ] **Step 2: Write the failing tests**

Add to `test/lenies/world/cell_test.exs`:

```elixir
  describe "carcass_hue field" do
    test "defaults to 0" do
      assert %Cell{}.carcass_hue == 0
    end
  end

  describe "decay_carcass/2" do
    test "leaves carcass_hue alone while carcass > 0 after decay" do
      cell = %Cell{carcass: 100, carcass_hue: 42}
      decayed = Cell.decay_carcass(cell, 0.10)
      assert decayed.carcass == 90
      assert decayed.carcass_hue == 42
    end

    test "clears carcass_hue when carcass reaches 0" do
      cell = %Cell{carcass: 3, carcass_hue: 42}
      decayed = Cell.decay_carcass(cell, 1.0)
      assert decayed.carcass == 0
      assert decayed.carcass_hue == 0
    end

    test "clears carcass_hue when carcass was already 0" do
      cell = %Cell{carcass: 0, carcass_hue: 42}
      decayed = Cell.decay_carcass(cell, 0.10)
      assert decayed.carcass == 0
      assert decayed.carcass_hue == 0
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
mix test test/lenies/world/cell_test.exs
```

Expected: failures because the `carcass_hue` field doesn't exist on the struct.

- [ ] **Step 4: Modify `Cell` to add the field and clear it in decay**

Replace `lib/lenies/world/cell.ex` with:

```elixir
defmodule Lenies.World.Cell do
  @moduledoc """
  Struct di una cella della griglia mondo.

  - `lenie_id`: id del Lenie residente, o `nil` se vuota.
  - `resource`: biomassa accumulata dalla radiazione (clamp a `cell_resource_cap`).
  - `carcass`: energia da carcasse (decay-tasso `carcass_decay`/tick).
  - `carcass_hue`: hue byte (1..255) della specie del Lenie morto in cella,
    oppure 0 se nessuna carcassa colorata. Azzerato quando `carcass` torna a 0.
  """

  alias Lenies.Config

  @type t :: %__MODULE__{
          lenie_id: nil | binary(),
          resource: non_neg_integer(),
          carcass: non_neg_integer(),
          carcass_hue: 0..255
        }

  defstruct lenie_id: nil, resource: 0, carcass: 0, carcass_hue: 0

  def new, do: %__MODULE__{}

  def add_resource(%__MODULE__{} = cell, amount) when amount > 0 do
    cap = Config.cell_resource_cap()
    %{cell | resource: min(cap, cell.resource + amount)}
  end

  def add_resource(%__MODULE__{} = cell, _), do: cell

  def decay_carcass(%__MODULE__{} = cell, rate) when rate >= 0 and rate <= 1 do
    new_amount = max(0, floor(cell.carcass * (1 - rate)))
    new_hue = if new_amount == 0, do: 0, else: cell.carcass_hue
    %{cell | carcass: new_amount, carcass_hue: new_hue}
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/lenies/world/cell_test.exs
```

Expected: 4 tests pass.

- [ ] **Step 6: Run full suite to catch surprises**

```bash
mix test
```

Expected: all tests still pass (or at most the same flaky `telemetry_test.exs` ring-buffer one already known).

- [ ] **Step 7: Commit**

```bash
git add lib/lenies/world/cell.ex test/lenies/world/cell_test.exs
git commit -m "feat: Cell.carcass_hue field + auto-clear in decay_carcass/2"
```

---

## Task 3: `World.lenie_died/4` carries the hash; sets carcass_hue

**Files:**
- Modify: `lib/lenies/world.ex` (public API `lenie_died/3` → `lenie_died/4`, `handle_cast` clause)
- Modify: `lib/lenies/lenie.ex` (`terminate/2` passes hash)
- Modify: `test/lenies/world_test.exs` (cover the new behavior; update existing tests that call the 3-arg form, if any)

- [ ] **Step 1: Find current callers of `World.lenie_died/3`**

```bash
grep -rn "World.lenie_died\|lenie_died(" lib test
```

Expected callers: `lib/lenies/lenie.ex:136` (production), maybe a few tests.

- [ ] **Step 2: Write the failing test for hash-aware death**

Add to `test/lenies/world_test.exs` (inside an appropriate `describe` block or at the end of the module):

```elixir
  describe "lenie_died/4 — carcass_hue" do
    setup do
      case Process.whereis(Lenies.World) do
        nil -> {:ok, _} = Lenies.World.start_link(tick_interval_ms: 0)
        _ -> :ok
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

        Lenies.World.Tables.delete_all()
      end)

      :ok
    end

    test "death stores SpeciesColor.hue_byte(hash) into the cell's carcass_hue" do
      hash = "test-hash-abc"
      expected_hue = Lenies.SpeciesColor.hue_byte(hash)

      # Pretend a Lenie occupies (3, 4)
      :ets.insert(:cells, {{3, 4}, %Lenies.World.Cell{lenie_id: "L1"}})
      :ets.insert(:lenies, {"L1", %{id: "L1"}})

      Lenies.World.lenie_died("L1", {3, 4}, 200.0, hash)

      # Cast is async; sync via a synchronous call to the same GenServer
      _ = Lenies.World.snapshot_stats()

      [{_, cell}] = :ets.lookup(:cells, {3, 4})
      assert cell.lenie_id == nil
      assert cell.carcass > 0
      assert cell.carcass_hue == expected_hue
    end
  end
```

- [ ] **Step 3: Run test to verify it fails**

```bash
mix test test/lenies/world_test.exs
```

Expected: failure — `lenie_died/4` does not yet exist.

- [ ] **Step 4: Update `World.lenie_died` and `handle_cast`**

In `lib/lenies/world.ex`, replace the `lenie_died` public function (around line 52-54):

```elixir
  @doc "Notifica al World che un Lenie è morto (libera cella, eventuale carcassa)."
  def lenie_died(id, pos, energy_at_death, codeome_hash)
      when is_binary(codeome_hash) do
    GenServer.cast(@name, {:lenie_died, id, pos, energy_at_death, codeome_hash})
  end
```

And replace the `handle_cast({:lenie_died, ...}, state)` clause (around line 187-200):

```elixir
  @impl true
  def handle_cast({:lenie_died, id, {x, y}, energy_at_death, codeome_hash}, state) do
    case :ets.lookup(:cells, {x, y}) do
      [{key, cell}] ->
        carcass_value = max(0, trunc(energy_at_death * 0.5))
        hue = Lenies.SpeciesColor.hue_byte(codeome_hash)

        :ets.insert(:cells, {
          key,
          %{cell | lenie_id: nil, carcass: cell.carcass + carcass_value, carcass_hue: hue}
        })

      _ ->
        :ok
    end

    :ets.delete(:lenies, id)
    {:noreply, state}
  end
```

- [ ] **Step 5: Update `Lenie.terminate/2` to pass the hash**

In `lib/lenies/lenie.ex`, replace the `terminate/2` function (around line 133-138):

```elixir
  @impl true
  def terminate(_reason, state) do
    hash = Lenies.Codeome.hash(state.codeome)
    World.lenie_died(state.id, state.interp.pos, state.interp.energy, hash)
    :ok
  end
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
mix test test/lenies/world_test.exs
```

Expected: the new test passes; existing tests still pass.

- [ ] **Step 7: Run full suite**

```bash
mix test
```

Expected: all green except the known telemetry flake.

- [ ] **Step 8: Commit**

```bash
git add lib/lenies/world.ex lib/lenies/lenie.ex test/lenies/world_test.exs
git commit -m "feat: lenie_died/4 carries codeome_hash, sets cell.carcass_hue"
```

---

## Task 4: `GridRenderer` emits hue byte for lenies layer + new carcass_hue layer

**Files:**
- Modify: `lib/lenies_web/grid_renderer.ex`
- Modify: `test/lenies_web/grid_renderer_test.exs`

- [ ] **Step 1: Update existing tests + add new assertions**

Replace `test/lenies_web/grid_renderer_test.exs` with:

```elixir
defmodule LeniesWeb.GridRendererTest do
  use ExUnit.Case, async: false

  alias LeniesWeb.GridRenderer
  alias Lenies.World.Tables

  setup do
    Tables.create_all()
    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  test "encode_layers/1 returns 4 binaries of grid_w * grid_h bytes" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    {lenies_bin, resource_bin, carcass_bin, carcass_hue_bin} =
      GridRenderer.encode_layers(grid)

    assert byte_size(lenies_bin) == 16
    assert byte_size(resource_bin) == 16
    assert byte_size(carcass_bin) == 16
    assert byte_size(carcass_hue_bin) == 16

    assert lenies_bin == <<0::128>>
    assert resource_bin == <<0::128>>
    assert carcass_bin == <<0::128>>
    assert carcass_hue_bin == <<0::128>>
  end

  test "encode_layers/1 writes the species hue byte into the lenies layer at occupied cells" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    :ets.insert(:cells, {{1, 2}, %Lenies.World.Cell{lenie_id: "L1"}})
    :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "hash-A"}})

    expected_byte = Lenies.SpeciesColor.hue_byte("hash-A")

    {lenies_bin, _, _, _} = GridRenderer.encode_layers(grid)

    # Row-major: byte index = y * w + x = 2 * 4 + 1 = 9
    assert :binary.at(lenies_bin, 9) == expected_byte

    for i <- 0..15, i != 9 do
      assert :binary.at(lenies_bin, i) == 0
    end
  end

  test "encode_layers/1 emits 0 for an occupied cell whose lenie has no snapshot yet" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    # Lenie occupies the cell but the `:lenies` snapshot row hasn't been written
    :ets.insert(:cells, {{0, 0}, %Lenies.World.Cell{lenie_id: "ORPHAN"}})

    {lenies_bin, _, _, _} = GridRenderer.encode_layers(grid)

    assert :binary.at(lenies_bin, 0) == 0
  end

  test "encode_layers/1 includes resource, carcass, and carcass_hue values" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    :ets.insert(:cells, {
      {0, 0},
      %Lenies.World.Cell{resource: 75, carcass: 30, carcass_hue: 137}
    })

    {_, resource_bin, carcass_bin, carcass_hue_bin} = GridRenderer.encode_layers(grid)
    assert :binary.at(resource_bin, 0) == 75
    assert :binary.at(carcass_bin, 0) == 30
    assert :binary.at(carcass_hue_bin, 0) == 137
  end

  test "encode_payload/1 returns 4 base64-encoded layers in a map" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    payload = GridRenderer.encode_payload(grid)

    assert %{
             lenies: lenies_b64,
             resource: resource_b64,
             carcass: carcass_b64,
             carcass_hue: carcass_hue_b64,
             width: 4,
             height: 4
           } = payload

    for b64 <- [lenies_b64, resource_b64, carcass_b64, carcass_hue_b64] do
      assert is_binary(b64)
      {:ok, decoded} = Base.decode64(b64)
      assert byte_size(decoded) == 16
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/lenies_web/grid_renderer_test.exs
```

Expected: failures — `encode_layers/1` returns 3 elements not 4, and the lenies byte is 1 not the hue byte.

- [ ] **Step 3: Rewrite `GridRenderer`**

Replace `lib/lenies_web/grid_renderer.ex` with:

```elixir
defmodule LeniesWeb.GridRenderer do
  @moduledoc """
  Encodes the `:cells` ETS table into compact binary layers for the dashboard
  canvas.

  Four layers, each `width * height` bytes, row-major (`byte_index = y * width + x`):

    - `lenies`       — 0 if cell is empty; otherwise the species hue byte
                       (1..255) of the Lenie occupying the cell. The mapping is
                       `Lenies.SpeciesColor.hue_byte(codeome_hash)`. If the
                       Lenie hasn't written its first snapshot yet so the
                       hash isn't in `:lenies`, the byte is 0 (rendered as
                       no-species briefly).
    - `resource`     — `cell.resource` clamped to 0..255.
    - `carcass`      — `cell.carcass` clamped to 0..255.
    - `carcass_hue`  — `cell.carcass_hue` (0 means no species color, render
                       as generic; 1..255 is the hue byte of the dead Lenie).

  `encode_payload/1` returns a base64-encoded map for transport over
  LiveView's `push_event/3` to the client JS hook.
  """

  alias Lenies.SpeciesColor

  @doc "Encode cells into 4 binary layers (lenies, resource, carcass, carcass_hue)."
  @spec encode_layers({pos_integer(), pos_integer()}) ::
          {binary(), binary(), binary(), binary()}
  def encode_layers({w, h}) do
    cells = :ets.tab2list(:cells) |> Map.new()
    hash_by_id = build_hash_index()

    bytes =
      for y <- 0..(h - 1), x <- 0..(w - 1) do
        case Map.get(cells, {x, y}) do
          nil ->
            {0, 0, 0, 0}

          cell ->
            l = lenies_byte(cell, hash_by_id)
            r = cell.resource |> clamp_byte()
            c = cell.carcass |> clamp_byte()
            ch = cell.carcass_hue |> clamp_byte()
            {l, r, c, ch}
        end
      end

    lenies_bin = bytes |> Enum.map(fn {l, _, _, _} -> l end) |> :erlang.list_to_binary()
    resource_bin = bytes |> Enum.map(fn {_, r, _, _} -> r end) |> :erlang.list_to_binary()
    carcass_bin = bytes |> Enum.map(fn {_, _, c, _} -> c end) |> :erlang.list_to_binary()
    carcass_hue_bin =
      bytes |> Enum.map(fn {_, _, _, ch} -> ch end) |> :erlang.list_to_binary()

    {lenies_bin, resource_bin, carcass_bin, carcass_hue_bin}
  end

  @doc "Encode the grid for transport: base64-encoded layers + dimensions."
  @spec encode_payload({pos_integer(), pos_integer()}) :: map()
  def encode_payload({w, h} = grid) do
    {l, r, c, ch} = encode_layers(grid)

    %{
      lenies: Base.encode64(l),
      resource: Base.encode64(r),
      carcass: Base.encode64(c),
      carcass_hue: Base.encode64(ch),
      width: w,
      height: h
    }
  end

  # One ETS scan to build {lenie_id => codeome_hash}. Avoids a per-cell lookup
  # in the inner row-major loop.
  defp build_hash_index do
    case :ets.info(:lenies) do
      :undefined ->
        %{}

      _ ->
        :ets.tab2list(:lenies)
        |> Map.new(fn {id, record} -> {id, Map.get(record, :codeome_hash)} end)
    end
  end

  defp lenies_byte(%{lenie_id: nil}, _index), do: 0

  defp lenies_byte(%{lenie_id: id}, index) when is_binary(id) do
    case Map.get(index, id) do
      hash when is_binary(hash) -> SpeciesColor.hue_byte(hash)
      _ -> 0
    end
  end

  defp lenies_byte(_, _), do: 0

  defp clamp_byte(n) when is_integer(n) and n >= 0 and n <= 255, do: n
  defp clamp_byte(n) when is_integer(n) and n < 0, do: 0
  defp clamp_byte(n) when is_integer(n) and n > 255, do: 255
  defp clamp_byte(_), do: 0
end
```

- [ ] **Step 4: Run grid renderer tests**

```bash
mix test test/lenies_web/grid_renderer_test.exs
```

Expected: 5 tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: all green except the known flake.

- [ ] **Step 6: Commit**

```bash
git add lib/lenies_web/grid_renderer.ex test/lenies_web/grid_renderer_test.exs
git commit -m "feat: GridRenderer emits 4 layers — lenies hue byte + carcass_hue"
```

---

## Task 5: JS hook renders hue byte → HSL and colored carcasses

**Files:**
- Modify: `assets/js/hooks/grid_canvas.js`

There are no JS unit tests in this project, so this task is validated manually after the dev server reloads. Be precise with the algorithm so the colors match `Lenies.SpeciesColor.byte_to_hex/1`.

- [ ] **Step 1: Replace the hook implementation**

Replace `assets/js/hooks/grid_canvas.js` with:

```javascript
// GridCanvas hook: renders 4 layers (lenies, resource, carcass, carcass_hue)
// onto the dashboard's 2D canvas.
//
// Wire format (per Lenies.SpeciesColor / LeniesWeb.GridRenderer):
//   - lenies      : 1 byte/cell. 0 = empty, 1..255 = species hue byte
//   - resource    : 1 byte/cell, 0..100 (clamped)
//   - carcass     : 1 byte/cell, 0..50 (clamped intensity)
//   - carcass_hue : 1 byte/cell. 0 = no species color, 1..255 = species hue byte
//
// Hue byte → degrees: deg = (byte - 1) / 255 * 360. Must match
// Lenies.SpeciesColor.byte_to_hex/1 (S=0.70, L=0.55).
//
// Pixel composition priority per cell:
//   1. occupied (lenies > 0)  + show_lenies   → HSL species fill, alpha 255
//   2. carcass > 0           + show_carcass   →
//        if carcass_hue > 0 → HSL species fill, alpha = carcass * 4
//        else                → red (255, 60, 60), alpha = carcass * 4
//   3. resource > 0          + show_resource  → green channel = resource * 2
//   4. default                                → empty (alpha 192)

const SATURATION = 0.70;
const LIGHTNESS = 0.55;

function hueDegFromByte(b) {
  return ((b - 1) / 255) * 360;
}

// HSL → RGB, returns {r, g, b} as 0..255 ints. Same formula as
// Lenies.SpeciesColor.hsl_to_rgb/3 in Elixir.
function hslToRgb(h, s, l) {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const hPrime = h / 60;
  const x = c * (1 - Math.abs((hPrime % 2) - 1));

  let r1 = 0, g1 = 0, b1 = 0;
  if (hPrime < 1) { r1 = c; g1 = x; b1 = 0; }
  else if (hPrime < 2) { r1 = x; g1 = c; b1 = 0; }
  else if (hPrime < 3) { r1 = 0; g1 = c; b1 = x; }
  else if (hPrime < 4) { r1 = 0; g1 = x; b1 = c; }
  else if (hPrime < 5) { r1 = x; g1 = 0; b1 = c; }
  else { r1 = c; g1 = 0; b1 = x; }

  const m = l - c / 2;
  return {
    r: Math.round((r1 + m) * 255),
    g: Math.round((g1 + m) * 255),
    b: Math.round((b1 + m) * 255),
  };
}

// Precompute a 256-entry RGB lookup so the per-pixel loop is just a table read.
const HUE_LUT = (() => {
  const lut = new Array(256);
  lut[0] = null; // reserved: "no species"
  for (let b = 1; b < 256; b++) {
    lut[b] = hslToRgb(hueDegFromByte(b), SATURATION, LIGHTNESS);
  }
  return lut;
})();

const GridCanvas = {
  mounted() {
    this.canvas = this.el;
    this.ctx = this.canvas.getContext("2d");
    this.gridW = parseInt(this.canvas.dataset.gridWidth, 10);
    this.gridH = parseInt(this.canvas.dataset.gridHeight, 10);

    this.bufferCanvas = document.createElement("canvas");
    this.bufferCanvas.width = this.gridW;
    this.bufferCanvas.height = this.gridH;
    this.bufferCtx = this.bufferCanvas.getContext("2d");

    this.handleEvent("render_frame", (payload) => {
      this.renderFrame(payload);
    });

    this.ctx.fillStyle = "#000";
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);

    this.canvas.addEventListener("click", (event) => {
      const rect = this.canvas.getBoundingClientRect();
      const x = event.clientX - rect.left;
      const y = event.clientY - rect.top;
      const cellX = Math.floor((x / this.canvas.width) * this.gridW);
      const cellY = Math.floor((y / this.canvas.height) * this.gridH);
      this.pushEvent("cell_clicked", { x: cellX, y: cellY });
    });
  },

  updated() {},

  decodeBase64(b64) {
    const binStr = atob(b64);
    const len = binStr.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) bytes[i] = binStr.charCodeAt(i);
    return bytes;
  },

  renderFrame({ lenies, resource, carcass, carcass_hue, width, height }) {
    const lBytes = this.decodeBase64(lenies);
    const rBytes = this.decodeBase64(resource);
    const cBytes = this.decodeBase64(carcass);
    const hBytes = this.decodeBase64(carcass_hue);

    const showLenies = this.canvas.hasAttribute("data-show-lenies");
    const showResource = this.canvas.hasAttribute("data-show-resource");
    const showCarcass = this.canvas.hasAttribute("data-show-carcass");

    const imageData = this.bufferCtx.createImageData(width, height);
    const px = imageData.data; // RGBA

    for (let i = 0; i < width * height; i++) {
      const speciesByte = lBytes[i];
      const res = rBytes[i];
      const carc = cBytes[i];
      const carcHueByte = hBytes[i];

      let r = 0, g = 0, b = 0, a = 192;

      if (showLenies && speciesByte > 0) {
        const rgb = HUE_LUT[speciesByte];
        r = rgb.r; g = rgb.g; b = rgb.b;
        a = 255;
      } else if (showCarcass && carc > 0) {
        if (carcHueByte > 0) {
          const rgb = HUE_LUT[carcHueByte];
          r = rgb.r; g = rgb.g; b = rgb.b;
        } else {
          r = 255; g = 60; b = 60;
        }
        a = Math.min(255, carc * 4);
      } else if (showResource && res > 0) {
        g = Math.min(255, res * 2);
      }

      const off = i * 4;
      px[off] = r;
      px[off + 1] = g;
      px[off + 2] = b;
      px[off + 3] = a;
    }

    this.bufferCtx.putImageData(imageData, 0, 0);

    this.ctx.imageSmoothingEnabled = false;
    this.ctx.fillStyle = "#000";
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
    this.ctx.drawImage(
      this.bufferCanvas,
      0,
      0,
      this.canvas.width,
      this.canvas.height
    );
  },
};

export default GridCanvas;
```

- [ ] **Step 2: Rebuild assets and confirm Phoenix live reload picks the change up**

The dev server should already be running. Phoenix's `esbuild` watcher will pick up the change automatically. Reload the dashboard in the browser. Expected: lenies appear in distinct hues per species (the seed-spawned ones share the `MinimalReplicator` hash, so they're all the same color, while mutated descendants drift to other hues).

If the dev server isn't running, start it:

```bash
mix phx.server
```

- [ ] **Step 3: Run the full test suite (no JS tests, but check Elixir tests still pass)**

```bash
mix test
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add assets/js/hooks/grid_canvas.js
git commit -m "feat: GridCanvas renders species hue byte → HSL pixels + colored carcasses"
```

---

## Task 6: Dashboard uses `SpeciesColor.hex/1` for table swatch + chart lines

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Modify: `test/lenies_web/live/dashboard_live_test.exs` (only if existing tests assert on the swatch color)

- [ ] **Step 1: Check whether the existing test asserts on the index-based palette**

```bash
grep -n "species_color\|species_palette\|swatch\|#22d3ee" test/lenies_web/live/dashboard_live_test.exs
```

If no matches, the tests do not depend on the specific colors — proceed without changing them.

- [ ] **Step 2: Replace the palette helpers and call sites in `dashboard_live.ex`**

In `lib/lenies_web/live/dashboard_live.ex`:

a) Remove the palette/helper (around lines 45-52, the block beginning `@species_palette` and ending with `defp species_color/1`):

```elixir
  @species_palette ~w(
    #22d3ee #a78bfa #34d399 #fb7185 #fbbf24
    #60a5fa #e879f9 #a3e635 #fb923c #38bdf8
  )

  defp species_color(idx), do: Enum.at(@species_palette, rem(idx, length(@species_palette)))
```

b) In the chart polyline (the loop building per-species `polyline` elements, around the `stroke={species_color(idx)}` line), change `stroke={species_color(idx)}` to `stroke={Lenies.SpeciesColor.hex(sp.hash)}`. The `idx` binding can stay or be removed — it's only used here if we kept it for the loop variable. Keep `Enum.with_index/1` for now to minimize diff.

c) In the species table row (around `style={"background:#{species_color(idx)}"}`), change to `style={"background:#{Lenies.SpeciesColor.hex(sp.hash)}"}`.

d) `Enum.with_index/1` over `@species` is no longer needed for coloring but stays harmless if used for keys; remove if unused.

The complete edits (replace each block, leave the rest untouched):

Before (lines ≈ 178-186 of the polyline loop):
```elixir
                <%= for {sp, idx} <- tracked do %>
                  <polyline
                    fill="none"
                    stroke={species_color(idx)}
                    stroke-width="1"
                    opacity="0.85"
```

After:
```elixir
                <%= for sp <- @species do %>
                  <polyline
                    fill="none"
                    stroke={Lenies.SpeciesColor.hex(sp.hash)}
                    stroke-width="1"
                    opacity="0.85"
```

Also remove the `<% tracked = Enum.with_index(@species) %>` binding directly above if present, and replace the closing `<% end %>` block of `tracked` with iteration over `@species` only.

Before (the table row block, lines ≈ 222-241):
```elixir
                    <%= for {sp, idx} <- Enum.with_index(@species) do %>
                      <tr class="hover:bg-cyan-500/10">
                        <td class="py-0.5 flex items-center gap-1.5">
                          <span
                            class="inline-block w-2 h-2 shrink-0"
                            style={"background:#{species_color(idx)}"}
                          >
```

After:
```elixir
                    <%= for sp <- @species do %>
                      <tr class="hover:bg-cyan-500/10">
                        <td class="py-0.5 flex items-center gap-1.5">
                          <span
                            class="inline-block w-2 h-2 shrink-0"
                            style={"background:#{Lenies.SpeciesColor.hex(sp.hash)}"}
                          >
```

- [ ] **Step 3: Compile and run dashboard tests**

```bash
mix compile --warnings-as-errors
mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: clean compile (no warnings), all dashboard tests pass.

- [ ] **Step 4: Run the full suite**

```bash
mix test
```

Expected: all green.

- [ ] **Step 5: Verify in the browser**

The dev server should hot-reload. Open the dashboard:
- The species table swatch colors should now be derived from the hash (different colors than before, but stable).
- The chart polylines should match the swatch colors.
- The canvas lenies should match too.
- Kill some lenies (e.g., crank `radiation_per_tick` to 0 to starve them) and confirm carcasses appear with the same hue as the dead species before fading.

This visual check is the success criterion for the whole plan.

- [ ] **Step 6: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex
git commit -m "feat: dashboard uses SpeciesColor.hex/1 for swatches + chart lines"
```

---

## Final sweep

- [ ] **Step 1: Run the full test suite once more**

```bash
mix test
```

Expected: all green except the known intermittent `Lenies.TelemetryTest` ring-buffer test, which is pre-existing.

- [ ] **Step 2: Confirm no leftover references to the removed helpers**

```bash
grep -rn "species_color\|@species_palette" lib test
```

Expected: no matches in `lib/` or `test/` (only the spec/plan markdown files may mention them historically).

- [ ] **Step 3: Quick visual smoke test in the browser**

With the dev server running:
1. Sterilize the world from the dashboard.
2. Spawn 20 `MinimalReplicator`. Confirm they all share the same color (one hash, one hue).
3. Watch a generation pass. Mutated descendants (different hashes) should appear in different colors.
4. Confirm the carcass left by a dying lenie keeps the species color, then fades.
5. Confirm the species table swatch, the chart polyline, and the canvas pixel for a given species are visually identical.

If all five hold, the plan is complete.
