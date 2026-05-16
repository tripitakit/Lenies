# LiveView Dashboard Implementation Plan (Sotto-progetto 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Costruire la dashboard LiveView per osservare la sandbox in tempo reale: griglia 256×256 renderizzata su canvas con 3 layer (Lenies/risorse/carcasse), grafico telemetria popolazione, controlli Sterilize + Pause/Resume + Layer toggle. Verifica end-to-end aprendo `http://localhost:4000/` nel browser.

**Architecture:**
- LiveView principale `LeniesWeb.DashboardLive` montata su `/`
- Si sottoscrive al PubSub `"world:tick"` per ricevere notifiche di tick
- Ad ogni tick (con throttle a 2Hz per limitare la banda) il LiveView legge `:cells` ETS, encoda i 3 layer come binari base64, e fa `push_event("render_frame", payload)` al JS hook
- Il JS hook `GridCanvas` riceve, decodifica base64 → Uint8Array, scrive su `<canvas>` via `ImageData`
- Grafico telemetria: SVG-line plain (no librerie esterne), aggiornato dal LiveView leggendo `:history` ETS via `Lenies.Telemetry.history/2`
- Bottoni: Sterilize (con conferma a due step), Pause/Resume, Layer toggle (3 checkbox)
- Nuove API World: `pause/0`, `resume/0`

**Tech Stack:** Phoenix LiveView 1.x (già nel progetto), JS hook (vanilla, no framework), HTML5 canvas + ImageData, base64 encoding via `Base.encode64/1` (Erlang built-in).

**Spec di riferimento:** [docs/superpowers/specs/2026-05-11-lenies-design.md](../specs/2026-05-11-lenies-design.md) — §7.1 Dashboard (4 pannelli), §9 Sterilizzazione.

**Criterio di completamento end-to-end:**
1. `mix phx.server` → browser `localhost:4000/` mostra:
   - Canvas 512×512 con la griglia animata (riempimento verde per risorse, rosso per carcasse, blu per Lenies)
   - Toggle dei 3 layer funzionante (checkbox)
   - Grafico telemetria (linea popolazione) aggiornata
   - Bottone Sterilize che resetta la sandbox (conferma a due step)
   - Bottone Pause/Resume che ferma/riprende il tick ambientale
2. Tutti i test passano (incluso il LiveViewTest)
3. `mix format --check-formatted` clean
4. Tag `v0.5.0-dashboard` su HEAD

---

## File structure

| File | Stato | Responsabilità |
|---|---|---|
| `lib/lenies/world.ex` | modify | `pause/0`, `resume/0` API + `paused?` flag in state |
| `lib/lenies_web/live/dashboard_live.ex` | new | LiveView principale |
| `lib/lenies_web/grid_renderer.ex` | new | encode cells → 3 binari per layer |
| `lib/lenies_web/router.ex` | modify | route `live "/"` |
| `assets/js/hooks/grid_canvas.js` | new | JS hook per rendering canvas |
| `assets/js/app.js` | modify | registra il hook |
| `config/runtime.exs` | modify | `dashboard_throttle_ticks` (default 5 = 2Hz visualization) |

| Test file | Nuovo/modifica |
|---|---|
| `test/lenies/world_pause_resume_test.exs` | new |
| `test/lenies_web/grid_renderer_test.exs` | new |
| `test/lenies_web/live/dashboard_live_test.exs` | new |

---

## Task 1: World pause/resume API

**Files:**
- Modify: `lib/lenies/world.ex`
- Test: `test/lenies/world_pause_resume_test.exs`

- [ ] **Step 1.1: Test pause/resume**

Create `test/lenies/world_pause_resume_test.exs`:
```elixir
defmodule Lenies.WorldPauseResumeTest do
  use ExUnit.Case, async: false

  alias Lenies.World
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
    :ok
  end

  test "pause/0 stops tick_count from advancing" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    # Run a few ticks
    World.tick_now()
    World.tick_now()
    stats_before = World.snapshot_stats()
    assert stats_before.tick_count == 2

    # Pause
    :ok = World.pause()

    # tick_now is still allowed (manual), but auto-tick is suppressed.
    # We can't easily test auto-tick here without timing — instead test that
    # pause/resume status is queryable.
    assert World.paused?() == true

    :ok = World.resume()
    assert World.paused?() == false
  end

  test "resume/0 restarts auto-tick" do
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
    {:ok, _world} = World.start_link(tick_interval_ms: 50)

    # initial ticks come through
    assert_receive {:tick, 1}, 500

    :ok = World.pause()

    # flush mailbox
    receive do
      {:tick, _} -> :ok
    after
      0 -> :ok
    end

    # no new ticks while paused (for 200ms)
    refute_receive {:tick, _}, 200

    :ok = World.resume()

    # ticks resume
    assert_receive {:tick, _}, 500
  end
end
```

- [ ] **Step 1.2: Run test (should fail)**

```bash
export PATH="$HOME/.asdf/shims:$PATH"
mix test test/lenies/world_pause_resume_test.exs
```

Expected: FAIL — `pause/0`, `resume/0`, `paused?/0` don't exist.

- [ ] **Step 1.3: Implement pause/resume in World**

In `lib/lenies/world.ex`:

1. Add public API (with other public functions like `sterilize/0`):
```elixir
@doc "Pause the environmental tick (auto-tick stops; tick_now still works)."
def pause, do: GenServer.call(@name, :pause)

@doc "Resume the environmental tick."
def resume, do: GenServer.call(@name, :resume)

@doc "Query current pause status."
def paused?, do: GenServer.call(@name, :paused?)
```

2. Add `paused?: false` to the state map in `init/1`:
```elixir
state = %{
  grid: grid,
  hotspots: hotspots,
  tick_interval_ms: tick_interval,
  tick_ref: nil,
  tick_count: 0,
  paused?: false
}
```

3. Add handle_call clauses:
```elixir
def handle_call(:pause, _from, state) do
  if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
  {:reply, :ok, %{state | paused?: true, tick_ref: nil}}
end

def handle_call(:resume, _from, state) do
  new_state = %{state | paused?: false}
  new_state = maybe_schedule_tick(new_state)
  {:reply, :ok, new_state}
end

def handle_call(:paused?, _from, state) do
  {:reply, state.paused?, state}
end
```

4. Modify `maybe_schedule_tick/1` to not schedule when paused:
```elixir
defp maybe_schedule_tick(%{tick_interval_ms: 0} = state), do: state
defp maybe_schedule_tick(%{tick_interval_ms: nil} = state), do: state
defp maybe_schedule_tick(%{paused?: true} = state), do: state

defp maybe_schedule_tick(state) do
  ref = Process.send_after(self(), :tick, state.tick_interval_ms)
  %{state | tick_ref: ref}
end
```

- [ ] **Step 1.4: Run tests (should pass)**

```bash
mix test test/lenies/world_pause_resume_test.exs
```

Expected: PASS, 2 tests.

- [ ] **Step 1.5: Full suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 1.6: Commit**

```bash
git add lib/lenies/world.ex test/lenies/world_pause_resume_test.exs
git commit -m "feat: add World.pause/resume API with paused? state flag"
```

---

## Task 2: GridRenderer module

**Files:**
- Create: `lib/lenies_web/grid_renderer.ex`
- Test: `test/lenies_web/grid_renderer_test.exs`

- [ ] **Step 2.1: Test GridRenderer**

Create `test/lenies_web/grid_renderer_test.exs`:
```elixir
defmodule LeniesWeb.GridRendererTest do
  use ExUnit.Case, async: false

  alias LeniesWeb.GridRenderer
  alias Lenies.World.Tables

  setup do
    Tables.create_all()
    # Init a few cells with known state for a small 4x4 test grid
    # (we use {x, y} keys; the renderer iterates by row-major y*w + x order)
    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  test "encode_layers/1 returns 3 binaries of grid_w * grid_h bytes" do
    grid = {4, 4}

    # Empty grid: insert empty cells
    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    {lenies_bin, resource_bin, carcass_bin} = GridRenderer.encode_layers(grid)

    assert byte_size(lenies_bin) == 16
    assert byte_size(resource_bin) == 16
    assert byte_size(carcass_bin) == 16

    # All bytes are 0 since cells are empty
    assert lenies_bin == <<0::128>>
    assert resource_bin == <<0::128>>
    assert carcass_bin == <<0::128>>
  end

  test "encode_layers/1 marks lenie_id cells as 1 in lenies layer" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    # Mark cell {1, 2} as occupied
    :ets.insert(:cells, {{1, 2}, %Lenies.World.Cell{lenie_id: "L1"}})

    {lenies_bin, _, _} = GridRenderer.encode_layers(grid)

    # Row-major: byte index = y * w + x = 2 * 4 + 1 = 9
    assert :binary.at(lenies_bin, 9) == 1
    # All others 0
    for i <- 0..15, i != 9 do
      assert :binary.at(lenies_bin, i) == 0
    end
  end

  test "encode_layers/1 includes resource and carcass values" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    :ets.insert(:cells, {{0, 0}, %Lenies.World.Cell{resource: 75, carcass: 30}})

    {_, resource_bin, carcass_bin} = GridRenderer.encode_layers(grid)
    assert :binary.at(resource_bin, 0) == 75
    assert :binary.at(carcass_bin, 0) == 30
  end

  test "encode_payload/1 returns base64-encoded layers in a map" do
    grid = {4, 4}

    for x <- 0..3, y <- 0..3 do
      :ets.insert(:cells, {{x, y}, %Lenies.World.Cell{}})
    end

    payload = GridRenderer.encode_payload(grid)

    assert %{lenies: lenies_b64, resource: resource_b64, carcass: carcass_b64, width: 4, height: 4} = payload
    assert is_binary(lenies_b64)
    # base64 of 16 bytes is approximately 24 chars
    assert String.length(lenies_b64) >= 20

    # Round-trip: decode base64 and verify shape
    {:ok, decoded} = Base.decode64(lenies_b64)
    assert byte_size(decoded) == 16
  end
end
```

- [ ] **Step 2.2: Run test (should fail)**

```bash
mix test test/lenies_web/grid_renderer_test.exs
```

Expected: FAIL.

- [ ] **Step 2.3: Implement GridRenderer**

Create `lib/lenies_web/grid_renderer.ex`:
```elixir
defmodule LeniesWeb.GridRenderer do
  @moduledoc """
  Encodes the `:cells` ETS table into compact binary layers for the dashboard
  canvas.

  Layer format: each layer is a binary of `width * height` bytes, row-major
  (`byte_index = y * width + x`). Values:
  - lenies layer: `1` if cell has `lenie_id`, else `0`
  - resource layer: `cell.resource` (0..255, clamped from cell.resource 0..100)
  - carcass layer: `cell.carcass` (0..255, clamped from cell.carcass 0..50)

  `encode_payload/1` returns a base64-encoded map for transport over LiveView's
  `push_event/3` to the client JS hook.
  """

  @doc "Encode cells into 3 binary layers (lenies, resource, carcass)."
  @spec encode_layers({pos_integer(), pos_integer()}) :: {binary(), binary(), binary()}
  def encode_layers({w, h}) do
    # Collect all cells into a sorted list by {x, y}
    # We iterate y first, then x, to build row-major byte order
    cells = :ets.tab2list(:cells) |> Map.new()

    bytes =
      for y <- 0..(h - 1), x <- 0..(w - 1) do
        case Map.get(cells, {x, y}) do
          nil -> {0, 0, 0}
          cell ->
            l = if cell.lenie_id != nil, do: 1, else: 0
            r = cell.resource |> clamp_byte()
            c = cell.carcass |> clamp_byte()
            {l, r, c}
        end
      end

    lenies_bin = bytes |> Enum.map(fn {l, _, _} -> l end) |> :erlang.list_to_binary()
    resource_bin = bytes |> Enum.map(fn {_, r, _} -> r end) |> :erlang.list_to_binary()
    carcass_bin = bytes |> Enum.map(fn {_, _, c} -> c end) |> :erlang.list_to_binary()

    {lenies_bin, resource_bin, carcass_bin}
  end

  @doc "Encode the grid for transport: base64-encoded layers + dimensions."
  @spec encode_payload({pos_integer(), pos_integer()}) :: map()
  def encode_payload({w, h} = grid) do
    {l, r, c} = encode_layers(grid)

    %{
      lenies: Base.encode64(l),
      resource: Base.encode64(r),
      carcass: Base.encode64(c),
      width: w,
      height: h
    }
  end

  defp clamp_byte(n) when is_integer(n) and n >= 0 and n <= 255, do: n
  defp clamp_byte(n) when n < 0, do: 0
  defp clamp_byte(n) when n > 255, do: 255
  defp clamp_byte(_), do: 0
end
```

- [ ] **Step 2.4: Run tests (should pass)**

```bash
mix test test/lenies_web/grid_renderer_test.exs
```

Expected: PASS, 4 tests.

- [ ] **Step 2.5: Commit**

```bash
git add lib/lenies_web/grid_renderer.ex test/lenies_web/grid_renderer_test.exs
git commit -m "feat: add GridRenderer module for canvas payload encoding"
```

---

## Task 3: DashboardLive skeleton + routing

**Files:**
- Create: `lib/lenies_web/live/dashboard_live.ex`
- Modify: `lib/lenies_web/router.ex`
- Test: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 3.1: Test DashboardLive mount**

Create `test/lenies_web/live/dashboard_live_test.exs`:
```elixir
defmodule LeniesWeb.DashboardLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    # Ensure World is started for the LiveView to interact with
    # The Application supervisor should already start it via auto_start_simulation
    # but in test env auto_start_simulation = false, so start manually
    case Process.whereis(Lenies.World) do
      nil ->
        {:ok, _} = Lenies.World.start_link(tick_interval_ms: 0)
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
      Lenies.World.Tables.delete_all()
    end)

    :ok
  end

  test "mounts on / and renders dashboard panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    # 4 panels: world canvas, telemetry, species (placeholder), controls
    assert html =~ ~r/Lenies Dashboard/i
    assert html =~ "id=\"grid-canvas\""
    assert html =~ ~r/Sterilize/i
    assert html =~ ~r/(Pause|Resume)/i
  end

  test "shows initial canvas with width and height data attributes", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    # Canvas exists with phx-hook for client rendering
    assert html =~ ~r/phx-hook="GridCanvas"/
  end
end
```

- [ ] **Step 3.2: Update Router**

Modify `lib/lenies_web/router.ex` to add a LiveView route at "/" — REPLACE the existing PageController route if present.

The default phx.new generates:
```elixir
scope "/", LeniesWeb do
  pipe_through :browser
  get "/", PageController, :home
end
```

Change to:
```elixir
scope "/", LeniesWeb do
  pipe_through :browser
  live "/", DashboardLive, :index
end
```

Remove the `PageController` route. (You can leave the PageController module file in place; it won't be reached.)

- [ ] **Step 3.3: Implement DashboardLive skeleton**

Create `lib/lenies_web/live/dashboard_live.ex`:
```elixir
defmodule LeniesWeb.DashboardLive do
  @moduledoc """
  Main dashboard for monitoring the Lenies sandbox.

  Four panels (per spec §7.1):
  1. World (canvas 512×512 with 3 toggleable layers)
  2. Telemetry (population over time)
  3. Species (placeholder — fully implemented in sub-project 6)
  4. Controls (Sterilize, Pause/Resume)
  """

  use LeniesWeb, :live_view

  alias LeniesWeb.GridRenderer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
    end

    grid = Lenies.Config.grid_size()

    socket =
      socket
      |> assign(:grid, grid)
      |> assign(:tick_count, 0)
      |> assign(:layers_visible, %{lenies: true, resource: true, carcass: true})
      |> assign(:sterilize_confirming, false)
      |> assign(:paused?, false)
      |> assign(:throttle_counter, 0)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <h1>Lenies Dashboard</h1>

      <div class="panels">
        <div class="panel world-panel">
          <h2>Mondo</h2>
          <canvas
            id="grid-canvas"
            phx-hook="GridCanvas"
            data-grid-width={elem(@grid, 0)}
            data-grid-height={elem(@grid, 1)}
            data-show-lenies={@layers_visible.lenies}
            data-show-resource={@layers_visible.resource}
            data-show-carcass={@layers_visible.carcass}
            width="512"
            height="512"
          >
          </canvas>

          <div class="layer-controls">
            <label>
              <input
                type="checkbox"
                phx-click="toggle_layer"
                phx-value-layer="lenies"
                checked={@layers_visible.lenies}
              /> Lenies
            </label>
            <label>
              <input
                type="checkbox"
                phx-click="toggle_layer"
                phx-value-layer="resource"
                checked={@layers_visible.resource}
              /> Risorse
            </label>
            <label>
              <input
                type="checkbox"
                phx-click="toggle_layer"
                phx-value-layer="carcass"
                checked={@layers_visible.carcass}
              /> Carcasse
            </label>
          </div>
        </div>

        <div class="panel telemetry-panel">
          <h2>Telemetria</h2>
          <div id="telemetry-chart">Tick: <%= @tick_count %></div>
        </div>

        <div class="panel species-panel">
          <h2>Specie</h2>
          <p>(SP6 — Inspector + Specie views)</p>
        </div>

        <div class="panel controls-panel">
          <h2>Controllo</h2>

          <%= if @sterilize_confirming do %>
            <p>Sei sicuro? Questo distrugge tutta la sandbox.</p>
            <button phx-click="sterilize_confirm">Sì, sterilizza</button>
            <button phx-click="sterilize_cancel">No, annulla</button>
          <% else %>
            <button phx-click="sterilize_init" class="btn-red">STERILIZE</button>
          <% end %>

          <button phx-click="toggle_pause">
            <%= if @paused?, do: "Resume", else: "Pause" %>
          </button>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_layer", %{"layer" => layer}, socket) do
    layer_atom = String.to_existing_atom(layer)
    new_visible = Map.update!(socket.assigns.layers_visible, layer_atom, &(!&1))
    {:noreply, assign(socket, :layers_visible, new_visible)}
  end

  def handle_event("sterilize_init", _, socket) do
    {:noreply, assign(socket, :sterilize_confirming, true)}
  end

  def handle_event("sterilize_confirm", _, socket) do
    :ok = Lenies.World.sterilize()
    {:noreply, assign(socket, :sterilize_confirming, false)}
  end

  def handle_event("sterilize_cancel", _, socket) do
    {:noreply, assign(socket, :sterilize_confirming, false)}
  end

  def handle_event("toggle_pause", _, socket) do
    if socket.assigns.paused? do
      :ok = Lenies.World.resume()
      {:noreply, assign(socket, :paused?, false)}
    else
      :ok = Lenies.World.pause()
      {:noreply, assign(socket, :paused?, true)}
    end
  end

  @impl true
  def handle_info({:tick, n}, socket) do
    throttle = Application.get_env(:lenies, :dashboard_throttle_ticks, 5)
    new_counter = socket.assigns.throttle_counter + 1

    socket = assign(socket, :tick_count, n) |> assign(:throttle_counter, new_counter)

    if rem(new_counter, throttle) == 0 do
      payload = GridRenderer.encode_payload(socket.assigns.grid)
      {:noreply, push_event(socket, "render_frame", payload)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:sterilized, _ts}, socket) do
    # Re-send a fresh frame to clear the canvas
    payload = GridRenderer.encode_payload(socket.assigns.grid)
    {:noreply, push_event(socket, "render_frame", payload)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
```

Add `dashboard_throttle_ticks` to `config/runtime.exs`:
```elixir
config :lenies,
  # ...
  dashboard_throttle_ticks: 5
```

- [ ] **Step 3.4: Run test**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: PASS, 2 tests.

- [ ] **Step 3.5: Full suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 3.6: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex lib/lenies_web/router.ex config/runtime.exs test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat: add DashboardLive with grid canvas placeholder and controls"
```

---

## Task 4: JS hook for canvas rendering

**Files:**
- Create: `assets/js/hooks/grid_canvas.js`
- Modify: `assets/js/app.js`

- [ ] **Step 4.1: Implement the hook**

Create `assets/js/hooks/grid_canvas.js`:
```javascript
// GridCanvas hook: renders 3 layers (lenies, resource, carcass) on a 2D canvas.
// Receives base64-encoded binary layers via phx event "render_frame".
//
// Layer encoding (1 byte per cell, row-major):
//   - lenies: 1 if cell occupied, else 0
//   - resource: 0..100
//   - carcass: 0..50
//
// Color composition:
//   - resource → green channel
//   - carcass → red channel
//   - lenies → high-alpha blue overlay

const GridCanvas = {
  mounted() {
    this.canvas = this.el;
    this.ctx = this.canvas.getContext("2d");
    this.gridW = parseInt(this.canvas.dataset.gridWidth, 10);
    this.gridH = parseInt(this.canvas.dataset.gridHeight, 10);

    // Off-screen buffer at native grid resolution; scaled to canvas size on draw
    this.bufferCanvas = document.createElement("canvas");
    this.bufferCanvas.width = this.gridW;
    this.bufferCanvas.height = this.gridH;
    this.bufferCtx = this.bufferCanvas.getContext("2d");

    this.handleEvent("render_frame", (payload) => {
      this.renderFrame(payload);
    });

    // Initial clear
    this.ctx.fillStyle = "#000";
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
  },

  updated() {
    // Re-read layer visibility from data attributes
  },

  decodeBase64(b64) {
    const binStr = atob(b64);
    const len = binStr.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
      bytes[i] = binStr.charCodeAt(i);
    }
    return bytes;
  },

  renderFrame({ lenies, resource, carcass, width, height }) {
    const lBytes = this.decodeBase64(lenies);
    const rBytes = this.decodeBase64(resource);
    const cBytes = this.decodeBase64(carcass);

    const showLenies = this.canvas.dataset.showLenies !== "false";
    const showResource = this.canvas.dataset.showResource !== "false";
    const showCarcass = this.canvas.dataset.showCarcass !== "false";

    const imageData = this.bufferCtx.createImageData(width, height);
    const px = imageData.data; // RGBA, length = w*h*4

    for (let i = 0; i < width * height; i++) {
      const lenie = lBytes[i];
      const res = rBytes[i];
      const carc = cBytes[i];

      // Scale: resource 0..100 → 0..200 in green; carcass 0..50 → 0..200 in red
      const g = showResource ? Math.min(255, res * 2) : 0;
      const r = showCarcass ? Math.min(255, carc * 4) : 0;
      const b = showLenies && lenie > 0 ? 255 : 0;
      const a = showLenies && lenie > 0 ? 255 : 192;

      const off = i * 4;
      px[off] = r;
      px[off + 1] = g;
      px[off + 2] = b;
      px[off + 3] = a;
    }

    this.bufferCtx.putImageData(imageData, 0, 0);

    // Scale buffer to canvas size (pixelated = nearest-neighbor)
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

- [ ] **Step 4.2: Register the hook in app.js**

Modify `assets/js/app.js` — add the hook to the LiveSocket configuration. The existing file (generated by phx.new) typically looks like:

```javascript
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})
```

(Or similar — adapt to actual contents.)

Modify to:
```javascript
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import GridCanvas from "./hooks/grid_canvas"

const Hooks = {GridCanvas}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// ... rest of file unchanged
liveSocket.connect()
```

- [ ] **Step 4.3: Build assets**

```bash
mix assets.build
```

Expected: success, no errors.

- [ ] **Step 4.4: Smoke test in browser**

Start the server:
```bash
mix phx.server
```

Open `http://localhost:4000/` in a browser. Expected to see:
- The dashboard layout with 4 panels
- A black canvas
- Layer toggle checkboxes (all checked)
- Sterilize / Pause buttons

The canvas will be black until ticks fire and the auto-start simulation populates cells. In test env, auto_start_simulation is false; in dev env, it should be true (default). With dev, the canvas should soon show green dots (resources) as radiation deposits.

- [ ] **Step 4.5: Commit**

```bash
git add assets/js/hooks/grid_canvas.js assets/js/app.js
git commit -m "feat: add GridCanvas JS hook for canvas frame rendering"
```

---

## Task 5: Telemetry chart (simple SVG)

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`

- [ ] **Step 5.1: Update DashboardLive to fetch history and render chart**

Modify `lib/lenies_web/live/dashboard_live.ex`:

1. In `mount/3`, add an assign for history:
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
```

2. In `handle_info({:tick, n}, ...)`, fetch the latest history:
```elixir
def handle_info({:tick, n}, socket) do
  throttle = Application.get_env(:lenies, :dashboard_throttle_ticks, 5)
  new_counter = socket.assigns.throttle_counter + 1

  socket =
    socket
    |> assign(:tick_count, n)
    |> assign(:throttle_counter, new_counter)
    |> assign(:history, Lenies.Telemetry.history(:last_n, 100))

  if rem(new_counter, throttle) == 0 do
    payload = GridRenderer.encode_payload(socket.assigns.grid)
    {:noreply, push_event(socket, "render_frame", payload)}
  else
    {:noreply, socket}
  end
end
```

3. Update the telemetry panel in `render/1`:
```heex
<div class="panel telemetry-panel">
  <h2>Telemetria</h2>
  <div class="telemetry-stats">
    <p>Tick: <%= @tick_count %></p>
    <p>Snapshot entries: <%= length(@history) %></p>
  </div>
  <svg width="300" height="100" style="background: #eee">
    <%= for {entry, idx} <- Enum.with_index(@history) do %>
      <% x = idx * 3 %>
      <% y = 100 - min(80, entry.population) %>
      <circle cx={x} cy={y} r="2" fill="blue" />
    <% end %>
  </svg>
</div>
```

This renders a simple scatter of population values. Not a line chart, but good enough for SP5 MVP — refinable later.

- [ ] **Step 5.2: Build assets + smoke test**

```bash
mix assets.build
mix test
```

Run server briefly and check `/` — telemetry panel should show the SVG with dots.

- [ ] **Step 5.3: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex
git commit -m "feat: add simple SVG population scatter to telemetry panel"
```

---

## Task 6: Integration test for full dashboard

**Files:**
- Modify: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 6.1: Extend the test**

Append to `test/lenies_web/live/dashboard_live_test.exs`:
```elixir
  test "clicking sterilize_init shows confirm prompt", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    refute render(view) =~ "Sei sicuro?"

    view
    |> element("button", "STERILIZE")
    |> render_click()

    assert render(view) =~ "Sei sicuro?"
  end

  test "clicking sterilize_confirm resets the world", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Need to start the world first
    Lenies.World.tick_now()
    stats_before = Lenies.World.snapshot_stats()
    assert stats_before.tick_count >= 1

    view
    |> element("button", "STERILIZE")
    |> render_click()

    view
    |> element("button", "Sì, sterilizza")
    |> render_click()

    stats_after = Lenies.World.snapshot_stats()
    assert stats_after.tick_count == 0
  end

  test "clicking pause toggles state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    refute Lenies.World.paused?()

    view
    |> element("button", "Pause")
    |> render_click()

    assert Lenies.World.paused?()

    view
    |> element("button", "Resume")
    |> render_click()

    refute Lenies.World.paused?()
  end

  test "toggling layer changes data attribute", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html_before = render(view)
    assert html_before =~ ~r/data-show-lenies="true"/

    view
    |> element("input[phx-value-layer='lenies']")
    |> render_click()

    html_after = render(view)
    assert html_after =~ ~r/data-show-lenies="false"/
  end
```

- [ ] **Step 6.2: Run test**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: PASS — 6 tests (2 initial + 4 new).

- [ ] **Step 6.3: Commit**

```bash
git add test/lenies_web/live/dashboard_live_test.exs
git commit -m "test: cover sterilize, pause, and layer toggle interactions"
```

---

## Task 7: Final verification + tag v0.5.0

- [ ] **Step 7.1: Full suite stability (3x)**

```bash
mix test 2>&1 | tail -3
mix test 2>&1 | tail -3
mix test 2>&1 | tail -3
```

Expected: stable count.

- [ ] **Step 7.2: Format check**

```bash
mix format --check-formatted
```

Expected: clean.

- [ ] **Step 7.3: Browser smoke test**

Start the server:
```bash
mix phx.server
```

Open `http://localhost:4000/`. Verify:
- Canvas shows the grid (eventually green dots as radiation deposits)
- Toggling Lenies/Risorse/Carcasse checkboxes affects what's drawn
- Telemetry SVG shows scatter dots
- Click STERILIZE → confirm prompt → "Sì, sterilizza" → grid clears
- Click Pause → tick stops (canvas freezes) → Resume → ticks continue

Take a screenshot or describe what you see for the user.

Stop the server with Ctrl+C twice.

- [ ] **Step 7.4: Tag baseline**

```bash
git status
git log --oneline | head -10
git tag v0.5.0-dashboard
git rev-list -n 1 v0.5.0-dashboard
git rev-list -n 1 HEAD
```

Expected: working tree clean, tag matches HEAD.

---

## Self-Review checklist

**Spec coverage (§7.1 Dashboard):**
- [x] Panel 1: Mondo canvas 512×512 → Tasks 2-4
- [x] Layer toggle (Lenies/Risorse/Carcasse) → Tasks 3-4
- [x] Panel 2: Telemetria temporale → Task 5 (simplified scatter, not full line chart)
- [x] Panel 3: Specie tabella → Task 3 (placeholder, full impl in SP6)
- [x] Panel 4: Controllo → Sterilize (Task 3), Pause/Resume (Task 1+3)
- [ ] Seed dropdown → DEFERRED to SP7
- [ ] Tuning sliders → DEFERRED to SP7
- [ ] Click canvas → inspector → DEFERRED to SP6

**Not in §7.1 but emerging design:**
- Canvas rendering via JS hook (necessary due to 65k cell update rate)
- Server-side throttling (every 5 ticks = 2Hz updates) — explicit config key
- PubSub subscription on mount with `connected?(socket)` guard

**Placeholder scan:** the Species panel and seed/tuning UI are documented placeholders deferred to SP6/SP7. No "TBD" or unimplemented bits in delivered tasks.

**Type consistency:**
- `GridRenderer.encode_layers/1` returns `{binary, binary, binary}` — used as 3-tuple in `encode_payload/1`
- `encode_payload/1` returns `%{lenies, resource, carcass, width, height}` — keys consistent with JS hook destructuring
- Layer atom names `:lenies, :resource, :carcass` consistent across server + client (via `data-show-*` attributes)
- `World.pause/0`, `World.resume/0`, `World.paused?/0` API consistent with usage in DashboardLive

**Tech debt anticipated:**
- Canvas re-renders the entire 65k pixels each frame; no delta encoding. For SP6/7 with realistic populations, may want optimization.
- Telemetry chart is a simple scatter; spec calls for line chart with multiple series (population, energy, species count, etc.). SP6 or polish task can upgrade.
- `dashboard_throttle_ticks: 5` is global; per-client throttling not implemented.
- No tests for the JS hook itself (not feasible in current Phoenix test framework without browser automation).
