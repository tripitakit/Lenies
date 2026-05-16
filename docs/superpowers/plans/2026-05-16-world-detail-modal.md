# World Detail Modal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a full-screen modal in the Lenies dashboard that shows the world canvas zoomed to fill viewport height alongside a right pane listing every active species, where clicking a species row highlights its cells on the canvas.

**Architecture:** New `LeniesWeb.WorldDetailComponent` LiveComponent rendered conditionally from `DashboardLive` when `@world_detail_open?` is true, following the same `position: fixed; inset: 1.5rem` overlay pattern as the codeome editor modal. The component re-uses the existing `render_frame` push_event pipeline; the dashboard merges a `highlight_hue` byte into the payload when a species row is selected. A new JS hook `WorldDetailCanvas` decodes the standard payload and dims pixels whose species byte does not match the highlight.

**Tech Stack:** Elixir 1.19 + Phoenix 1.8 + Phoenix LiveView 1.1, Tailwind v4, SortableJS already vendored (unused here), Canvas 2D API.

**Spec:** `docs/superpowers/specs/2026-05-16-world-detail-modal.md`

---

## File map

- **New** `lib/lenies_web/live/world_detail_component.ex` — modal component
- **New** `assets/js/hooks/world_detail_canvas.js` — JS canvas hook with highlight
- **New** `test/lenies_web/live/world_detail_component_test.exs` — component tests
- **Modify** `lib/lenies_web/live/dashboard_live.ex` — new assigns, events, conditional render, highlight injection into render_frame
- **Modify** `lib/lenies_web/live/controls_panel_component.ex` — new ⛶ World detail button
- **Modify** `test/lenies_web/live/dashboard_live_test.exs` — open/close + highlight integration tests
- **Modify** `assets/js/app.js` — register `WorldDetailCanvas`
- **Modify** `assets/css/app.css` — modal + species list styles

---

## Task 1: DashboardLive assigns + open/close events

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex` (mount + new handle_event clauses)
- Test: `test/lenies_web/live/dashboard_live_test.exs` (new describe block at end of file, before the final `end`)

- [ ] **Step 1.1: Write failing tests** — append a new describe block to `test/lenies_web/live/dashboard_live_test.exs` just before the file's final `end`:

```elixir
  describe "world detail modal — open/close" do
    test "world_detail_open? starts false", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      refute html =~ ~s(id="world-detail")
    end

    test ":open_world_detail info message sets the flag", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)
      html = render(view)
      assert html =~ ~s(id="world-detail")
    end

    test "close_world_detail event clears the flag and the highlight", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)
      assert render(view) =~ ~s(id="world-detail")

      # Set a highlight via the highlight event so we can verify clear.
      render_hook(view, "highlight_species_in_world", %{"hash" => "DOES-NOT-EXIST"})

      view |> element("button#world-detail-close") |> render_click()
      refute render(view) =~ ~s(id="world-detail")
    end
  end
```

- [ ] **Step 1.2: Run the new tests — they must fail**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs -t describe:"world detail modal — open/close"
```

Expected output: 3 failures, all citing `refute html =~ ~s(id="world-detail")` for test 1, and assertion failures (no such element) for tests 2 and 3.

- [ ] **Step 1.3: Add the assigns in `DashboardLive.mount/3`** — open `lib/lenies_web/live/dashboard_live.ex`, find the existing block ending with `|> assign(:editor_mode, nil)` (around line 41) and add two more lines so the chain reads:

```elixir
      |> assign(:editor_mode, nil)
      |> assign(:world_detail_open?, false)
      |> assign(:world_detail_highlight_hash, nil)
```

- [ ] **Step 1.4: Add three handle_event/handle_info clauses** — anywhere after the existing handle_event clauses in `dashboard_live.ex` (e.g. after the `cell_clicked` handler around line 335), add:

```elixir
  @impl true
  def handle_info(:open_world_detail, socket) do
    {:noreply,
     socket
     |> assign(:world_detail_open?, true)
     |> assign(:world_detail_highlight_hash, nil)}
  end

  def handle_event("close_world_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:world_detail_open?, false)
     |> assign(:world_detail_highlight_hash, nil)}
  end

  def handle_event("highlight_species_in_world", %{"hash" => hash}, socket)
      when is_binary(hash) do
    new_hash =
      if socket.assigns.world_detail_highlight_hash == hash, do: nil, else: hash

    {:noreply, assign(socket, :world_detail_highlight_hash, new_hash)}
  end
```

- [ ] **Step 1.5: Add a temporary stub render of the modal** — find the existing `<%= if @selected_hash || @editor_mode == :new_seed do %>` block in the render function (around line 282). Immediately after the closing `<% end %>` of that block (and before the `</div>` that closes the row), add:

```heex
          <%= if @world_detail_open? do %>
            <aside id="world-detail" class="panel codeome-editor-modal world-detail-modal flex flex-col gap-2 p-4">
              <header class="flex items-center gap-2">
                <h2 class="text-xs flex-1">World detail</h2>
                <button
                  id="world-detail-close"
                  type="button"
                  phx-click="close_world_detail"
                  class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
                  title="Close"
                >
                  ×
                </button>
              </header>
            </aside>
          <% end %>
```

- [ ] **Step 1.6: Run the tests — they must pass**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs -t describe:"world detail modal — open/close"
```

Expected output: `3 tests, 0 failures`.

- [ ] **Step 1.7: Run the full dashboard test file as a regression sanity check**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: all previous tests still pass, plus the 3 new ones.

- [ ] **Step 1.8: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat(world-detail): assigns + open/close plumbing in DashboardLive"
```

---

## Task 2: ⛶ World detail button in controls panel

**Files:**
- Modify: `lib/lenies_web/live/controls_panel_component.ex`
- Test: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 2.1: Write the failing test** — add to the `world detail modal — open/close` describe block in `test/lenies_web/live/dashboard_live_test.exs`:

```elixir
    test "clicking the ⛶ World detail button opens the modal", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      view
      |> element("button#world-detail-open")
      |> render_click()

      assert render(view) =~ ~s(id="world-detail")
    end
```

- [ ] **Step 2.2: Run to confirm failure**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs -t describe:"world detail modal — open/close"
```

Expected: one failure, complaining `button#world-detail-open` is not found in the DOM.

- [ ] **Step 2.3: Add the button in ControlsPanelComponent** — open `lib/lenies_web/live/controls_panel_component.ex`, find the `+ New Seed` button (around line 129–137). Immediately AFTER that button (still inside the same `<div class="flex items-center gap-2 text-xs">`), insert:

```heex
          <button
            id="world-detail-open"
            type="button"
            phx-click="open_world_detail"
            phx-target={@myself}
            class="px-2 py-0.5 border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40"
            title="Open the zoomed world detail view"
          >
            ⛶ World detail
          </button>
```

- [ ] **Step 2.4: Add the matching handle_event in ControlsPanelComponent** — find the existing `handle_event("open_codeome_editor", ...)` clause (around line 390) and add this clause right after it:

```elixir
  def handle_event("open_world_detail", _params, socket) do
    send(self(), :open_world_detail)
    {:noreply, socket}
  end
```

- [ ] **Step 2.5: Run the new test — must pass**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs -t describe:"world detail modal — open/close"
```

Expected: `4 tests, 0 failures`.

- [ ] **Step 2.6: Commit**

```bash
git add lib/lenies_web/live/controls_panel_component.ex test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat(world-detail): + World detail button in controls panel"
```

---

## Task 3: WorldDetailComponent skeleton + integration

**Files:**
- Create: `lib/lenies_web/live/world_detail_component.ex`
- Modify: `lib/lenies_web/live/dashboard_live.ex` (replace stub aside with live_component)
- Create: `test/lenies_web/live/world_detail_component_test.exs`

- [ ] **Step 3.1: Write the failing component test** — create `test/lenies_web/live/world_detail_component_test.exs`:

```elixir
defmodule LeniesWeb.WorldDetailComponentTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LeniesWeb.WorldDetailComponent

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        id: "world-detail",
        species: [],
        species_total: 0,
        highlight_hash: nil,
        grid: {256, 256}
      },
      overrides
    )
  end

  test "renders the modal aside with the close button" do
    html = render_component(WorldDetailComponent, base_assigns())
    assert html =~ ~s(id="world-detail")
    assert html =~ ~s(id="world-detail-close")
    assert html =~ "World detail"
  end

  test "renders the world canvas with grid width/height from assigns" do
    html = render_component(WorldDetailComponent, base_assigns(%{grid: {256, 256}}))
    assert html =~ ~s(id="world-detail-canvas")
    assert html =~ ~s(data-grid-width="256")
    assert html =~ ~s(data-grid-height="256")
    assert html =~ ~s(phx-hook="WorldDetailCanvas")
  end
end
```

- [ ] **Step 3.2: Run to verify failure**

```bash
mix test test/lenies_web/live/world_detail_component_test.exs
```

Expected: compile error / `WorldDetailComponent` not defined.

- [ ] **Step 3.3: Create the component** — write `lib/lenies_web/live/world_detail_component.ex`:

```elixir
defmodule LeniesWeb.WorldDetailComponent do
  @moduledoc """
  Full-screen modal overlay showing the simulation world zoomed to fill
  viewport height, with a right pane listing every active species and
  letting the user click one to highlight its cells on the canvas.

  Stateful LiveComponent (single static root: the `<aside>`). State lives
  in the parent `DashboardLive` so the component is essentially a view
  layer over `@species`, `@grid`, and `@highlight_hash`.
  """

  use LeniesWeb, :live_component

  alias Lenies.SpeciesColor

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id="world-detail"
      class="panel codeome-editor-modal world-detail-modal flex flex-col gap-3 p-4"
    >
      <header class="flex items-center gap-2">
        <h2 class="text-xs flex-1">World detail</h2>
        <button
          id="world-detail-close"
          type="button"
          phx-click="close_world_detail"
          class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
          title="Close"
        >
          ×
        </button>
      </header>

      <div class="world-detail-body grid gap-4 min-h-0 flex-1">
        <section class="world-detail-canvas-pane">
          <canvas
            id="world-detail-canvas"
            phx-hook="WorldDetailCanvas"
            phx-update="ignore"
            data-grid-width={elem(@grid, 0)}
            data-grid-height={elem(@grid, 1)}
            data-highlight-hue={highlight_hue(@highlight_hash)}
            width={elem(@grid, 0) * 2}
            height={elem(@grid, 1) * 2}
            class="world-detail-canvas"
          >
          </canvas>
        </section>

        <section class="world-detail-species-pane">
          <div class="world-detail-species-header">
            Species — <span class="text-cyan-300">{length(@species)}</span> attive
          </div>
          <ul id="world-detail-species-list" class="world-detail-species-list">
            <%= if @species == [] do %>
              <li class="world-detail-species-empty">No active species</li>
            <% end %>
            <%= for sp <- Enum.sort_by(@species, & &1.population, :desc) do %>
              <li>
                <button
                  type="button"
                  phx-click="highlight_species_in_world"
                  phx-value-hash={sp.hash}
                  class={[
                    "world-detail-species-row",
                    @highlight_hash == sp.hash && "selected"
                  ]}
                >
                  <span
                    class="world-detail-species-swatch"
                    style={"background:#{SpeciesColor.hex(sp.hash)}"}
                  >
                  </span>
                  <span class="world-detail-species-hash">{String.slice(sp.hash, 0..7)}</span>
                  <span class="world-detail-species-pop">{sp.population}</span>
                  <span class="world-detail-species-gen">{Float.round(sp.avg_generation, 2)}</span>
                </button>
              </li>
            <% end %>
          </ul>
        </section>
      </div>
    </aside>
    """
  end

  # Map an optional hash to the 0..255 highlight hue byte we ship to the
  # canvas. 0 means "no highlight" — the hook renders normally.
  defp highlight_hue(nil), do: 0
  defp highlight_hue(hash) when is_binary(hash), do: SpeciesColor.hue_byte(hash)
end
```

- [ ] **Step 3.4: Replace the stub aside in DashboardLive with the live_component**
  — open `lib/lenies_web/live/dashboard_live.ex`, find the stub aside added in Task 1 (the `<%= if @world_detail_open? do %><aside id="world-detail" ...>...</aside><% end %>` block) and replace it with:

```heex
          <%= if @world_detail_open? do %>
            <.live_component
              module={LeniesWeb.WorldDetailComponent}
              id="world-detail"
              species={@species}
              species_total={@species_total}
              highlight_hash={@world_detail_highlight_hash}
              grid={@grid}
            />
          <% end %>
```

- [ ] **Step 3.5: Run the component tests — they must pass**

```bash
mix test test/lenies_web/live/world_detail_component_test.exs
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 3.6: Run the dashboard tests — open/close still passes**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs -t describe:"world detail modal — open/close"
```

Expected: `4 tests, 0 failures`.

- [ ] **Step 3.7: Commit**

```bash
git add lib/lenies_web/live/world_detail_component.ex \
        lib/lenies_web/live/dashboard_live.ex \
        test/lenies_web/live/world_detail_component_test.exs
git commit -m "feat(world-detail): WorldDetailComponent with canvas + species list"
```

---

## Task 4: Species list sorting + empty state

**Files:**
- Test: `test/lenies_web/live/world_detail_component_test.exs`

- [ ] **Step 4.1: Write failing tests** — append to the test file:

```elixir
  test "species list rows are sorted by population descending" do
    species = [
      %{hash: "AAAA1111", population: 5, avg_generation: 1.0},
      %{hash: "BBBB2222", population: 17, avg_generation: 1.0},
      %{hash: "CCCC3333", population: 11, avg_generation: 1.0}
    ]

    html = render_component(WorldDetailComponent, base_assigns(%{species: species}))

    # Pull every hash short-id in order of appearance and assert it matches
    # the population-desc order: BBBB(17), CCCC(11), AAAA(5).
    hashes = Regex.scan(~r/world-detail-species-hash">([A-F0-9]{8})</, html)
            |> Enum.map(fn [_, h] -> h end)

    assert hashes == ["BBBB2222", "CCCC3333", "AAAA1111"]
  end

  test "empty species list shows the no-active-species notice" do
    html = render_component(WorldDetailComponent, base_assigns(%{species: []}))
    assert html =~ "No active species"
  end

  test "selected species row carries the .selected class" do
    species = [
      %{hash: "BBBB2222", population: 5, avg_generation: 1.0},
      %{hash: "AAAA1111", population: 3, avg_generation: 1.0}
    ]

    html =
      render_component(
        WorldDetailComponent,
        base_assigns(%{species: species, highlight_hash: "BBBB2222"})
      )

    assert html =~ ~s(world-detail-species-row selected)
  end
```

- [ ] **Step 4.2: Run them**

```bash
mix test test/lenies_web/live/world_detail_component_test.exs
```

Expected: all three new tests should already pass (the component code in Task 3 already implements sorting, empty state, and the selected class). If they do, skip to commit. If any fail, fix the component until they pass.

- [ ] **Step 4.3: Commit**

```bash
git add test/lenies_web/live/world_detail_component_test.exs
git commit -m "test(world-detail): species list sorting, empty state, selection"
```

---

## Task 5: Highlight toggle integration in DashboardLive

**Files:**
- Test: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 5.1: Write failing integration tests** — add to the world detail describe block:

```elixir
    test "clicking a species row sets the highlight on the canvas", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-WD-A", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)

      html =
        view
        |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-A']")
        |> render_click()

      hue = Lenies.SpeciesColor.hue_byte("HASH-WD-A")
      assert html =~ ~s(data-highlight-hue="#{hue}")
    end

    test "clicking the same species row twice clears the highlight", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-WD-B", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)

      view
      |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-B']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-B']")
        |> render_click()

      assert html =~ ~s(data-highlight-hue="0")
    end

    test "clicking a different species row swaps the highlight", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-WD-X", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"L2", %{id: "L2", codeome_hash: "HASH-WD-Y", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)

      view
      |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-X']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-Y']")
        |> render_click()

      hue_y = Lenies.SpeciesColor.hue_byte("HASH-WD-Y")
      assert html =~ ~s(data-highlight-hue="#{hue_y}")
    end
```

- [ ] **Step 5.2: Run — they must pass**

The plumbing was put in place in Task 1 (`handle_event("highlight_species_in_world", ...)`) and Task 3 (component reads `@highlight_hash` and emits `data-highlight-hue`). So these are end-to-end assertions, not new code.

```bash
mix test test/lenies_web/live/dashboard_live_test.exs -t describe:"world detail modal — open/close"
```

Expected: all tests in the describe block pass.

- [ ] **Step 5.3: Commit**

```bash
git add test/lenies_web/live/dashboard_live_test.exs
git commit -m "test(world-detail): species highlight toggle end-to-end"
```

---

## Task 6: Server-side highlight injection into render_frame

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Test: `test/lenies_web/live/dashboard_live_test.exs`

The component renders the highlight byte as a DOM attribute. The JS hook will read that attribute on every frame, so we do **not** need to put the byte in the `render_frame` payload itself. However, we should still confirm with a test that the dashboard pushes a `render_frame` whether or not the modal is open — the modal does not change the push cadence.

- [ ] **Step 6.1: Write the regression test** — add to the describe block:

```elixir
    test "render_frame events are still pushed while the modal is open", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)

      # Force a tick to make sure the dashboard re-pushes.
      Lenies.World.tick_now()
      send(view.pid, {:tick, 1})

      assert_push_event view, "render_frame", %{lenies: _}
    end
```

- [ ] **Step 6.2: Run — must pass with no code changes**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs:LINE_OF_NEW_TEST
```

(Replace `LINE_OF_NEW_TEST` with the actual line number, or just run the whole file.) Expected: pass; the modal does not gate `push_event/3`.

- [ ] **Step 6.3: Commit**

```bash
git add test/lenies_web/live/dashboard_live_test.exs
git commit -m "test(world-detail): render_frame keeps pushing while modal is open"
```

---

## Task 7: WorldDetailCanvas JS hook with highlight

**Files:**
- Create: `assets/js/hooks/world_detail_canvas.js`
- Modify: `assets/js/app.js`

- [ ] **Step 7.1: Write the hook** — create `assets/js/hooks/world_detail_canvas.js`:

```javascript
// WorldDetailCanvas hook: renders the same render_frame payload as the
// dashboard's GridCanvas hook but at a larger pixel scale and with an
// optional "highlight" filter that dims every pixel whose species byte
// does not match data-highlight-hue.
//
// The highlight byte is read at draw time from the DOM attribute, so
// LiveView re-renders that change data-highlight-hue automatically take
// effect on the next frame without any extra event plumbing.

import { HUE_LUT } from "./grid_canvas_hue_lut.js";

const WorldDetailCanvas = {
  mounted() {
    this.canvas = this.el;
    this.ctx = this.canvas.getContext("2d");
    this.gridW = parseInt(this.canvas.dataset.gridWidth, 10);
    this.gridH = parseInt(this.canvas.dataset.gridHeight, 10);

    this.bufferCanvas = document.createElement("canvas");
    this.bufferCanvas.width = this.gridW;
    this.bufferCanvas.height = this.gridH;
    this.bufferCtx = this.bufferCanvas.getContext("2d");

    this.lastPayload = null;

    this.handleEvent("render_frame", (payload) => {
      this.lastPayload = payload;
      this.renderFrame();
    });

    // Initial black fill until the first frame arrives.
    this.ctx.fillStyle = "#000";
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
  },

  // LiveView morphs data-highlight-hue when the user clicks a row.
  // Re-render with the cached payload so the dim filter applies
  // immediately without waiting for the next server frame.
  updated() {
    if (this.lastPayload) this.renderFrame();
  },

  decodeBase64(b64) {
    const binStr = atob(b64);
    const len = binStr.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) bytes[i] = binStr.charCodeAt(i);
    return bytes;
  },

  renderFrame() {
    const { lenies, resource, carcass, carcass_hue, width, height } = this.lastPayload;
    const lBytes = this.decodeBase64(lenies);
    const rBytes = this.decodeBase64(resource);
    const cBytes = this.decodeBase64(carcass);
    const hBytes = this.decodeBase64(carcass_hue);

    const highlightHue = parseInt(this.canvas.dataset.highlightHue || "0", 10);

    const imageData = this.bufferCtx.createImageData(width, height);
    const px = imageData.data;

    for (let i = 0; i < width * height; i++) {
      const speciesByte = lBytes[i];
      const res = rBytes[i];
      const carc = cBytes[i];
      const carcHueByte = hBytes[i];

      let r = 0, g = 0, b = 0, a = 192;

      if (speciesByte > 0) {
        const rgb = HUE_LUT[speciesByte];
        r = rgb.r; g = rgb.g; b = rgb.b;
        a = 255;
      } else if (carc > 0) {
        if (carcHueByte > 0) {
          const rgb = HUE_LUT[carcHueByte];
          r = rgb.r; g = rgb.g; b = rgb.b;
        } else {
          r = 255; g = 60; b = 60;
        }
        a = Math.min(255, carc * 4);
      } else if (res > 0) {
        g = Math.min(255, res * 2);
      }

      // Dim everything that doesn't belong to the highlighted species.
      // highlightHue === 0 means "no highlight" — full intensity for all.
      if (highlightHue > 0 && speciesByte !== highlightHue) {
        a = Math.floor(a * 0.3);
      }

      const off = i * 4;
      px[off] = r;
      px[off + 1] = g;
      px[off + 2] = b;
      px[off + 3] = a;
    }

    this.bufferCtx.putImageData(imageData, 0, 0);

    // Nearest-neighbor upscale onto the display canvas.
    this.ctx.imageSmoothingEnabled = false;
    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.ctx.drawImage(
      this.bufferCanvas,
      0, 0, this.gridW, this.gridH,
      0, 0, this.canvas.width, this.canvas.height
    );
  },

  destroyed() {
    this.lastPayload = null;
  }
};

export default WorldDetailCanvas;
```

- [ ] **Step 7.2: Extract `HUE_LUT` to a shared module** — `WorldDetailCanvas` imports `./grid_canvas_hue_lut.js`. Create that file with the existing `HUE_LUT` const. First, find the LUT in `assets/js/hooks/grid_canvas.js` (top of file, around lines 1–55), then create `assets/js/hooks/grid_canvas_hue_lut.js` with exactly:

```javascript
// Shared 256-entry HSV→RGB lookup table for species hue bytes.
// Used by both GridCanvas and WorldDetailCanvas so a hue byte renders the
// same colour on every canvas.
//
// Generated once at module load — the math is identical to the inlined
// version that used to live in grid_canvas.js.

const HUE_LUT = (() => {
  const lut = new Array(256);
  for (let i = 0; i < 256; i++) {
    const h = (i - 1) / 254;          // 0..1
    const s = 0.85;
    const v = 1.0;
    const c = v * s;
    const x = c * (1 - Math.abs(((h * 6) % 2) - 1));
    const m = v - c;
    let r1, g1, b1;
    if (h < 1 / 6)      { r1 = c; g1 = x; b1 = 0; }
    else if (h < 2 / 6) { r1 = x; g1 = c; b1 = 0; }
    else if (h < 3 / 6) { r1 = 0; g1 = c; b1 = x; }
    else if (h < 4 / 6) { r1 = 0; g1 = x; b1 = c; }
    else if (h < 5 / 6) { r1 = x; g1 = 0; b1 = c; }
    else                { r1 = c; g1 = 0; b1 = x; }
    lut[i] = {
      r: Math.round((r1 + m) * 255),
      g: Math.round((g1 + m) * 255),
      b: Math.round((b1 + m) * 255)
    };
  }
  return lut;
})();

export { HUE_LUT };
```

**Important:** verify the existing `HUE_LUT` IIFE in `assets/js/hooks/grid_canvas.js` matches the math above before extracting. If it differs (e.g. different `s` or `v`), copy the existing math verbatim instead and update the comments. Do not change the LUT semantics.

- [ ] **Step 7.3: Replace the inlined LUT in `grid_canvas.js` with an import** — at the top of `assets/js/hooks/grid_canvas.js`, replace the inlined `const HUE_LUT = (() => {...})()` block with:

```javascript
import { HUE_LUT } from "./grid_canvas_hue_lut.js";
```

Do not change any logic that uses `HUE_LUT` — it remains a 256-entry array indexed by hue byte.

- [ ] **Step 7.4: Register the new hook** — open `assets/js/app.js`, find the existing imports/`Hooks` declaration (around lines 27–33), add an import and update the registration:

```javascript
import WorldDetailCanvas from "./hooks/world_detail_canvas"
```

And change:

```javascript
const Hooks = {GridCanvas, ActionFeedback, CodeomeSortable, ConfirmAction, CodeomePalette, ...colocatedHooks}
```

to:

```javascript
const Hooks = {GridCanvas, ActionFeedback, CodeomeSortable, ConfirmAction, CodeomePalette, WorldDetailCanvas, ...colocatedHooks}
```

- [ ] **Step 7.5: Smoke test — recompile and confirm no JS errors**

```bash
mix assets.build
```

Expected: success. If esbuild errors out on the LUT extraction, fix the import path or function signature until it compiles cleanly. There are no Elixir tests for the JS hook itself; manual verification follows in Task 10.

- [ ] **Step 7.6: Commit**

```bash
git add assets/js/hooks/world_detail_canvas.js \
        assets/js/hooks/grid_canvas_hue_lut.js \
        assets/js/hooks/grid_canvas.js \
        assets/js/app.js
git commit -m "feat(world-detail): WorldDetailCanvas hook with dim-non-highlight filter"
```

---

## Task 8: Auto-clear extinct-species highlight

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Test: `test/lenies_web/live/dashboard_live_test.exs`

- [ ] **Step 8.1: Write the failing test** — add to the world detail describe block:

```elixir
    test "highlight is cleared when the selected species drops out of the species list", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-WD-GONE", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")
      send(view.pid, :open_world_detail)

      view
      |> element("button[phx-click='highlight_species_in_world'][phx-value-hash='HASH-WD-GONE']")
      |> render_click()

      hue = Lenies.SpeciesColor.hue_byte("HASH-WD-GONE")
      assert render(view) =~ ~s(data-highlight-hue="#{hue}")

      # The Lenie disappears (extinct).
      :ets.delete(:lenies, "L1")
      send(view.pid, {:tick, 1})

      assert render(view) =~ ~s(data-highlight-hue="0")
    end
```

- [ ] **Step 8.2: Run — must fail**

The dashboard currently keeps the highlight assign even when the species is gone. The render still emits a non-zero `data-highlight-hue` because the component computes it from the (still-set) `@world_detail_highlight_hash`.

```bash
mix test test/lenies_web/live/dashboard_live_test.exs -t describe:"world detail modal — open/close"
```

Expected: the new test fails on the second assertion (expected `data-highlight-hue="0"`, got the live hue byte).

- [ ] **Step 8.3: Add the cleanup logic** — open `lib/lenies_web/live/dashboard_live.ex`, find the `handle_info({:tick, n}, socket)` clause (around line 338). After the assigns block that updates `:species` and `:species_total` (around lines 351–352), add this cleanup step:

```elixir
        |> maybe_clear_world_detail_highlight(species)
```

and define the helper at the bottom of the module (before the final `end`):

```elixir
  defp maybe_clear_world_detail_highlight(socket, species) do
    case socket.assigns.world_detail_highlight_hash do
      nil ->
        socket

      hash ->
        if Enum.any?(species, &(&1.hash == hash)) do
          socket
        else
          assign(socket, :world_detail_highlight_hash, nil)
        end
    end
  end
```

- [ ] **Step 8.4: Run — must pass**

```bash
mix test test/lenies_web/live/dashboard_live_test.exs -t describe:"world detail modal — open/close"
```

Expected: all tests pass.

- [ ] **Step 8.5: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex test/lenies_web/live/dashboard_live_test.exs
git commit -m "fix(world-detail): clear highlight when the selected species goes extinct"
```

---

## Task 9: CSS — modal layout + species list

**Files:**
- Modify: `assets/css/app.css`

There are no automated tests for CSS; verify visually via the running dev server in Task 10.

- [ ] **Step 9.1: Append the styles** — append at the end of `assets/css/app.css`:

```css
/* ----- World Detail modal ----- */
.lenies-dashboard .world-detail-modal {
  /* reuses .codeome-editor-modal for the overlay + backdrop; only add
     layout adjustments here */
  padding: 1rem;
}

.lenies-dashboard .world-detail-body {
  grid-template-columns: 1fr 340px;
  min-height: 0;
}

.lenies-dashboard .world-detail-canvas-pane {
  display: flex;
  justify-content: center;
  align-items: center;
  min-width: 0;
  min-height: 0;
}

.lenies-dashboard .world-detail-canvas {
  /* keep the 1:1 grid square; cap to the smaller of available height
     and (available width − right pane) */
  width: min(calc(100vh - 6rem), calc(100vw - 340px - 6rem));
  height: min(calc(100vh - 6rem), calc(100vw - 340px - 6rem));
  image-rendering: pixelated;
  background: #050816;
  border: 1px solid rgba(34, 211, 238, 0.25);
}

.lenies-dashboard .world-detail-species-pane {
  display: flex;
  flex-direction: column;
  gap: 6px;
  border: 1px solid rgba(34, 211, 238, 0.18);
  background: rgba(2, 6, 23, 0.4);
  padding: 8px;
  min-height: 0;
  overflow: hidden;
}

.lenies-dashboard .world-detail-species-header {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  opacity: 0.7;
  color: #22d3ee;
  border-bottom: 1px solid rgba(34, 211, 238, 0.15);
  padding-bottom: 4px;
  flex-shrink: 0;
}

.lenies-dashboard .world-detail-species-list {
  list-style: none;
  padding: 0;
  margin: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
  overflow-y: auto;
  flex: 1 1 auto;
  min-height: 0;
}

.lenies-dashboard .world-detail-species-empty {
  opacity: 0.5;
  font-size: 10px;
  padding: 6px 4px;
}

.lenies-dashboard .world-detail-species-row {
  display: grid;
  grid-template-columns: 12px 1fr 56px 48px;
  align-items: center;
  gap: 6px;
  padding: 3px 6px;
  width: 100%;
  background: rgba(2, 6, 23, 0.5);
  border: 1px solid transparent;
  font-family: ui-monospace, "JetBrains Mono", "Fira Code", monospace;
  font-size: 10px;
  text-align: left;
  cursor: pointer;
  transition: background 80ms ease, border-color 80ms ease;
}

.lenies-dashboard .world-detail-species-row:hover {
  background: rgba(34, 211, 238, 0.08);
}

.lenies-dashboard .world-detail-species-row.selected {
  border-color: rgba(34, 211, 238, 0.7);
  background: rgba(34, 211, 238, 0.12);
}

.lenies-dashboard .world-detail-species-swatch {
  display: inline-block;
  width: 10px;
  height: 10px;
  border-radius: 2px;
}

.lenies-dashboard .world-detail-species-hash {
  color: #67e8f9;
}

.lenies-dashboard .world-detail-species-pop {
  text-align: right;
  color: #e2e8f0;
  font-weight: 600;
}

.lenies-dashboard .world-detail-species-gen {
  text-align: right;
  opacity: 0.6;
}
```

- [ ] **Step 9.2: Rebuild assets and verify no errors**

```bash
mix assets.build
```

Expected: success, no Tailwind/PostCSS errors.

- [ ] **Step 9.3: Commit**

```bash
git add assets/css/app.css
git commit -m "style(world-detail): modal layout + species list rows"
```

---

## Task 10: Escape-to-close keyboard shortcut

**Files:**
- Modify: `lib/lenies_web/live/world_detail_component.ex`
- Test: `test/lenies_web/live/world_detail_component_test.exs`

- [ ] **Step 10.1: Write the failing test**:

```elixir
  test "the aside has a phx-window-keydown handler for Escape" do
    html = render_component(WorldDetailComponent, base_assigns())
    assert html =~ ~s(phx-window-keydown="close_world_detail")
    assert html =~ ~s(phx-key="Escape")
  end
```

- [ ] **Step 10.2: Run — must fail**

```bash
mix test test/lenies_web/live/world_detail_component_test.exs
```

Expected: the new test fails (assertion that the markup contains `phx-window-keydown`).

- [ ] **Step 10.3: Add the handler attributes** — in `lib/lenies_web/live/world_detail_component.ex`, change the opening `<aside>` tag from:

```heex
<aside
  id="world-detail"
  class="panel codeome-editor-modal world-detail-modal flex flex-col gap-3 p-4"
>
```

to:

```heex
<aside
  id="world-detail"
  class="panel codeome-editor-modal world-detail-modal flex flex-col gap-3 p-4"
  phx-window-keydown="close_world_detail"
  phx-key="Escape"
>
```

- [ ] **Step 10.4: Run — must pass**

```bash
mix test test/lenies_web/live/world_detail_component_test.exs
```

Expected: all tests pass.

- [ ] **Step 10.5: Commit**

```bash
git add lib/lenies_web/live/world_detail_component.ex test/lenies_web/live/world_detail_component_test.exs
git commit -m "feat(world-detail): Escape key closes the modal"
```

---

## Task 11: Final full-suite regression check + manual smoke test

**Files:**
- (no code changes)

- [ ] **Step 11.1: Run the entire test suite**

```bash
mix test
```

Expected: every previous test still passes plus all the new tests added in this plan (the dashboard `world detail modal — open/close` describe block + the component test file). Document the final count in your commit message if you change anything.

- [ ] **Step 11.2: Manual smoke test in dev**

1. Make sure the Phoenix dev server is running (`iex -S mix phx.server`) or start it.
2. Open <http://localhost:4001>.
3. Click **⛶ World detail** in the controls panel. Verify the modal opens and the world is rendered at the larger size.
4. Click a row in the species list. Verify cells of every other species dim to ~30 %.
5. Click the same row again. Verify the dim clears.
6. Click a different row. Verify the highlight swaps.
7. Press Escape. Verify the modal closes.
8. Re-open the modal, click ×. Verify the modal closes.
9. Re-open with a species selected, then sterilize the world. Verify the highlight clears once the species drops out.

- [ ] **Step 11.3: If you found a bug in step 11.2, fix it and commit** — otherwise skip.

- [ ] **Step 11.4: Final summary commit (optional)** — only if no code changes:

```bash
git log --oneline --grep="world-detail" | head -20
```

Verify the chain of commits looks coherent and push when satisfied:

```bash
git push origin master
```

---

## Self-review check (already performed by the plan author)

1. **Spec coverage** — every section of the spec has at least one task:
   - User-visible behaviour (button, layout, sorting, highlight, close) → Tasks 1–4, 9, 10
   - Architecture (component, assigns, hooks) → Tasks 1, 3, 7
   - Data flow (render_frame, highlight via attribute) → Tasks 3, 6, 7
   - Edge cases (empty list, extinct species) → Tasks 4, 8
   - Test plan → integrated into every task

2. **Placeholders** — none. Every code block is complete.

3. **Type consistency** — `world_detail_open?`, `world_detail_highlight_hash`, `highlight_hash` (as the component assign), `data-highlight-hue`, `highlight_hue/1` private function all used consistently.

4. **Ambiguity** — pixel size of the canvas is given as an exact CSS expression; right pane width is exactly 340 px; dim alpha is exactly 0.3.
