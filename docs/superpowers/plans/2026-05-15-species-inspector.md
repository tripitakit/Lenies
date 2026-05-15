# Species Inspector (Phase B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an inline read-only side panel to the dashboard that shows the disassembled codeome of a species when the user clicks its row in the species table.

**Architecture:** New `LeniesWeb.SpeciesInspectorComponent` LiveComponent occupies a third column on the right of the dashboard top row, visible only when `@selected_hash` is non-nil on `DashboardLive`. The component caches the disassembled codeome by hash (immutable) so changing population doesn't trigger refetch; stats (population, avg generation) come from a `species_record` map passed in by the parent. CSS opcode-category classes ship in `assets/css/app.css` under `.lenies-dashboard`.

**Tech Stack:** Elixir 1.19, Phoenix LiveView, ExUnit, Tailwind v4 + inline styles.

**Spec:** `docs/superpowers/specs/2026-05-15-species-inspector.md`

---

## Task 1: `SpeciesInspectorComponent` + opcode CSS

**Files:**
- Create: `lib/lenies_web/live/species_inspector_component.ex`
- Create: `test/lenies_web/live/species_inspector_component_test.exs`
- Modify: `assets/css/app.css`

This task lands the entire component: rendering, codeome fetch from a sample Lenie process, caching by hash, and the opcode-category CSS classes used for syntax highlighting. The dashboard integration (row click, conditional rendering) is Task 2.

- [ ] **Step 1: Write the failing test file**

`test/lenies_web/live/species_inspector_component_test.exs`:

```elixir
defmodule LeniesWeb.SpeciesInspectorComponentTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias LeniesWeb.SpeciesInspectorComponent
  alias Lenies.World.Tables

  setup do
    Tables.create_all()

    case Process.whereis(Lenies.Registry) do
      nil -> {:ok, _} = Registry.start_link(keys: :unique, name: Lenies.Registry)
      _ -> :ok
    end

    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        id: "test-inspector",
        selected_hash: "abc12345abc12345",
        species_record: %{hash: "abc12345abc12345", population: 7, avg_generation: 3.5}
      },
      overrides
    )
  end

  describe "header" do
    test "renders the hash truncated with trailing ellipsis" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      assert html =~ "abc12345abc1234"
      assert html =~ "…"
    end

    test "renders the ↗ link to the standalone species page" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      assert html =~ ~s(href="/species/abc12345abc12345")
    end

    test "renders the close button targeting the selected hash" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      assert html =~ ~s(phx-click="select_species")
      assert html =~ ~s(phx-value-hash="abc12345abc12345")
    end
  end

  describe "stats" do
    test "renders population and avg_generation from species_record" do
      record = %{hash: "abc12345abc12345", population: 12, avg_generation: 2.25}
      html = render_component(SpeciesInspectorComponent, base_assigns(%{species_record: record}))
      assert html =~ ~r/>\s*12\s*</
      assert html =~ ~r/>\s*2\.25\s*</
    end

    test "handles an extinct species_record (population 0) without crashing" do
      record = %{hash: "abc12345abc12345", population: 0, avg_generation: 0.0}
      html = render_component(SpeciesInspectorComponent, base_assigns(%{species_record: record}))
      assert html =~ ~r/>\s*0\s*</
    end
  end

  describe "fetch behavior" do
    test "no Lenie of the selected species → no-sample notice, zero opcode count" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      assert html =~ "Nessun Lenie vivo"
      assert html =~ ~r/ops.*?>\s*0\s*</s
    end

    test "with a live Lenie of the species, fetches and disassembles its codeome" do
      codeome = Lenies.Codeomes.MinimalReplicator.codeome()
      hash = Lenies.Codeome.hash(codeome)

      {:ok, _pid} =
        Lenies.Lenie.start_link(
          id: "TEST-INSP-L1",
          codeome: codeome,
          energy: 100.0,
          pos: {0, 0},
          dir: :n,
          lineage: {nil, 0}
        )

      :ets.insert(:lenies, {"TEST-INSP-L1", %{id: "TEST-INSP-L1", codeome_hash: hash}})

      record = %{hash: hash, population: 1, avg_generation: 0.0}

      html =
        render_component(SpeciesInspectorComponent, %{
          id: "live-inspector",
          selected_hash: hash,
          species_record: record
        })

      # MinimalReplicator starts with the LOOP_HEAD anchor (four :nop_1)
      assert html =~ "op-template"
      assert html =~ "nop_1"
      # And it contains :get_size (self-inspect category)
      assert html =~ "op-self_inspect"
      assert html =~ "get_size"
      refute html =~ "Nessun Lenie vivo"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: failure — `LeniesWeb.SpeciesInspectorComponent` does not exist.

- [ ] **Step 3: Implement the component**

`lib/lenies_web/live/species_inspector_component.ex`:

```elixir
defmodule LeniesWeb.SpeciesInspectorComponent do
  @moduledoc """
  Read-only side panel showing the disassembled codeome of the selected species.

  Rendered as the third column of the dashboard top row, visible only when the
  parent `LeniesWeb.DashboardLive` has a non-nil `selected_hash`. The codeome
  is immutable per hash, so the component caches the disassembled lines and
  refetches only when `selected_hash` changes. Population and average
  generation come from the parent via `species_record` and refresh on every
  parent update (same throttle as the species table).
  """

  use LeniesWeb, :live_component

  alias Lenies.SpeciesColor
  alias LeniesWeb.Disassembler

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:codeome_lines, [])
     |> assign(:fetch_status, :ok)
     |> assign(:cached_codeome_hash, nil)}
  end

  @impl true
  def update(%{selected_hash: hash} = assigns, socket)
      when is_binary(hash) and hash != "" do
    if hash == socket.assigns.cached_codeome_hash do
      {:ok, assign(socket, assigns)}
    else
      {status, lines} = fetch_codeome(hash)

      {:ok,
       socket
       |> assign(assigns)
       |> assign(:codeome_lines, lines)
       |> assign(:fetch_status, status)
       |> assign(:cached_codeome_hash, hash)}
    end
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id="species-inspector"
      class="panel w-[320px] shrink-0 flex flex-col gap-2 p-3 min-h-0"
    >
      <header class="flex items-center gap-2">
        <span
          class="inline-block w-3 h-3 shrink-0"
          style={"background:#{SpeciesColor.hex(@selected_hash)}"}
        >
        </span>
        <h2 class="text-xs flex-1 truncate">
          {String.slice(@selected_hash, 0..15)}…
        </h2>
        <.link
          navigate={~p"/species/#{@selected_hash}"}
          class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
          title="Open full species page"
        >
          ↗
        </.link>
        <button
          phx-click="select_species"
          phx-value-hash={@selected_hash}
          class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
        >
          ×
        </button>
      </header>

      <div class="grid grid-cols-3 gap-2 text-[11px]">
        <div class="border border-cyan-500/30 px-2 py-1">
          <div class="opacity-60">pop.</div>
          <div class="text-cyan-300 font-bold tabular-nums text-base">
            {population(@species_record)}
          </div>
        </div>
        <div class="border border-violet-500/30 px-2 py-1">
          <div class="opacity-60">gen.</div>
          <div class="text-violet-300 font-bold tabular-nums text-base">
            {avg_gen(@species_record)}
          </div>
        </div>
        <div class="border border-emerald-500/30 px-2 py-1">
          <div class="opacity-60">ops</div>
          <div class="text-emerald-300 font-bold tabular-nums text-base">
            {length(@codeome_lines)}
          </div>
        </div>
      </div>

      <%= if @fetch_status == :no_sample do %>
        <p class="text-[10px] opacity-60">
          Nessun Lenie vivo di questa specie. Codeome non disponibile.
        </p>
      <% end %>

      <div class="flex-1 min-h-0 overflow-auto">
        <div class="text-[10px] leading-tight font-mono">
          <%= for line <- @codeome_lines do %>
            <div class="flex gap-2">
              <span class="opacity-50 tabular-nums w-8 shrink-0">
                {String.pad_leading(Integer.to_string(line.index), 3, " ")}
              </span>
              <span class={"op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
                {Atom.to_string(line.opcode)}
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </aside>
    """
  end

  defp population(%{population: n}), do: n
  defp population(_), do: 0

  defp avg_gen(%{avg_generation: g}) when is_float(g), do: Float.round(g, 2)
  defp avg_gen(%{avg_generation: g}) when is_integer(g), do: g
  defp avg_gen(_), do: 0

  # Pull a representative Lenie process for the species and disassemble its
  # codeome. Returns {:ok, lines} | {:no_sample, []} | {:error, []}.
  defp fetch_codeome(hash) do
    case safe_for_hash(hash) do
      [] ->
        {:no_sample, []}

      [{sample_id, _} | _] ->
        case safe_whereis(sample_id) do
          pid when is_pid(pid) ->
            try do
              case GenServer.call(pid, :get_codeome, 1_000) do
                {:ok, codeome} -> {:ok, Disassembler.disassemble(codeome, nil)}
                _ -> {:error, []}
              end
            catch
              :exit, _ -> {:error, []}
            end

          _ ->
            {:no_sample, []}
        end
    end
  end

  defp safe_for_hash(hash) do
    if :ets.info(:lenies) != :undefined do
      Lenies.Species.for_hash(hash)
    else
      []
    end
  end

  defp safe_whereis(id) do
    try do
      Lenies.Registry.whereis(id)
    catch
      :exit, _ -> nil
    end
  end
end
```

- [ ] **Step 4: Add the opcode-category CSS rules**

In `assets/css/app.css`, add these rules just before the closing `/* This file is for your main application CSS */` comment at the bottom:

```css
/* ----- Lenies dashboard: codeome opcode category colors ----- */
.lenies-dashboard .op-template     { color: #64748b; }
.lenies-dashboard .op-stack        { color: #fbbf24; }
.lenies-dashboard .op-arith        { color: #f97316; }
.lenies-dashboard .op-control      { color: #a78bfa; }
.lenies-dashboard .op-sense        { color: #22d3ee; }
.lenies-dashboard .op-action       { color: #34d399; }
.lenies-dashboard .op-predation    { color: #f43f5e; }
.lenies-dashboard .op-self_inspect { color: #38bdf8; }
.lenies-dashboard .op-replication  { color: #e879f9; }
.lenies-dashboard .op-memory       { color: #a3e635; }
.lenies-dashboard .op-unknown      { color: #94a3b8; }
```

- [ ] **Step 5: Run the targeted tests**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: 9 tests pass.

- [ ] **Step 6: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green (modulo the known `Lenies.TelemetryTest` ring-buffer flake — re-run that single test once if it surfaces).

- [ ] **Step 7: Compile clean**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix compile --warnings-as-errors
```

Expected: no warnings.

- [ ] **Step 8: Commit**

```bash
git add lib/lenies_web/live/species_inspector_component.ex \
        test/lenies_web/live/species_inspector_component_test.exs \
        assets/css/app.css
git commit -m "feat: SpeciesInspectorComponent — codeome inspection side panel"
```

---

## Task 2: Dashboard wires up the inspector

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Modify: `test/lenies_web/live/dashboard_live_test.exs`

This task adds `selected_hash` and `selected_species_record` assigns to the dashboard, the `select_species` event handler, the conditional third-column rendering of the inspector, and the row-click behavior on the species table (with the hash text no longer being a `<.link>`).

- [ ] **Step 1: Quickly review the current dashboard render**

```bash
grep -n "for sp <- @species\|top_species\|handle_event\|handle_info(:tick\|live_component module={LeniesWeb" lib/lenies_web/live/dashboard_live.ex
```

This shows you the species iteration line, the throttled tick branch, the `top_species/1` helper, and the existing ControlsPanelComponent placement. You'll touch all four areas.

- [ ] **Step 2: Write the failing dashboard tests**

Append these to `test/lenies_web/live/dashboard_live_test.exs` (inside the existing module, after the last existing test):

```elixir
  describe "species inspector panel" do
    test "panel hidden by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      refute html =~ ~s(id="species-inspector")
    end

    test "clicking a species row opens the inspector for that hash", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-X", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"L2", %{id: "L2", codeome_hash: "HASH-X", lineage: {nil, 1}}})

      {:ok, view, _} = live(conn, "/")

      html =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-X']")
        |> render_click()

      assert html =~ ~s(id="species-inspector")
      assert html =~ "HASH-X"
    end

    test "clicking the same row again closes the inspector", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-Y", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")

      view
      |> element("tr[phx-click='select_species'][phx-value-hash='HASH-Y']")
      |> render_click()

      html =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-Y']")
        |> render_click()

      refute html =~ ~s(id="species-inspector")
    end

    test "clicking another row swaps the inspected species", %{conn: conn} do
      :ets.insert(:lenies, {"L1", %{id: "L1", codeome_hash: "HASH-A", lineage: {nil, 0}}})
      :ets.insert(:lenies, {"L2", %{id: "L2", codeome_hash: "HASH-B", lineage: {nil, 0}}})

      {:ok, view, _} = live(conn, "/")

      view
      |> element("tr[phx-click='select_species'][phx-value-hash='HASH-A']")
      |> render_click()

      html =
        view
        |> element("tr[phx-click='select_species'][phx-value-hash='HASH-B']")
        |> render_click()

      assert html =~ ~s(id="species-inspector")
      assert html =~ "HASH-B"
    end
  end
```

- [ ] **Step 3: Run dashboard tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: the four new tests fail because no row carries `phx-click='select_species'` yet.

- [ ] **Step 4: Add the new assigns in `mount/3`**

In `lib/lenies_web/live/dashboard_live.ex`, find the `mount/3` chain that ends with `|> assign(:species_total, species_total)`. Add two more `assign` calls so the full chain reads:

```elixir
    socket =
      socket
      |> assign(:grid, grid)
      |> assign(:tick_count, 0)
      |> assign(:layers_visible, %{lenies: true, resource: true, carcass: true})
      |> assign(:throttle_counter, 0)
      |> assign(:history, [])
      |> assign(:species, species)
      |> assign(:species_total, species_total)
      |> assign(:selected_hash, nil)
      |> assign(:selected_species_record, nil)
```

- [ ] **Step 5: Add the `select_species` handler**

In the same file, in the section near the other `handle_event` clauses, add:

```elixir
  def handle_event("select_species", %{"hash" => hash}, socket) do
    new_hash =
      if socket.assigns.selected_hash == hash do
        nil
      else
        hash
      end

    {:noreply,
     socket
     |> assign(:selected_hash, new_hash)
     |> assign(:selected_species_record, find_selected_record(new_hash, socket.assigns.species))}
  end
```

- [ ] **Step 6: Add the `find_selected_record/2` helper**

In the helpers section near `top_species/1`, add:

```elixir
  defp find_selected_record(nil, _species), do: nil

  defp find_selected_record(hash, species) do
    case Enum.find(species, &(&1.hash == hash)) do
      %{} = found ->
        found

      nil ->
        case Lenies.Species.for_hash(hash) do
          [] ->
            %{hash: hash, population: 0, avg_generation: 0.0}

          records ->
            gens =
              records
              |> Enum.map(fn {_id, snap} -> snap.lineage |> elem(1) end)

            avg =
              if Enum.empty?(gens),
                do: 0.0,
                else: Enum.sum(gens) / length(gens) * 1.0

            %{hash: hash, population: length(records), avg_generation: avg}
        end
    end
  end
```

- [ ] **Step 7: Refresh the selected record on every throttled tick**

Find the `if rem(new_counter, throttle) == 0 do` branch inside `handle_info({:tick, n}, socket)`. It currently calls `top_species(10)` and assigns `:species` and `:species_total`. Extend it so the new branch reads:

```elixir
    if rem(new_counter, throttle) == 0 do
      {species, species_total} = top_species(10)

      socket =
        socket
        |> assign(:history, Lenies.Telemetry.history(:last_n, 100))
        |> assign(:species, species)
        |> assign(:species_total, species_total)
        |> assign(:selected_species_record,
          find_selected_record(socket.assigns.selected_hash, species)
        )

      payload = GridRenderer.encode_payload(socket.assigns.grid)
      {:noreply, push_event(socket, "render_frame", payload)}
    else
      {:noreply, socket}
    end
```

- [ ] **Step 8: Make species rows clickable and drop the hash `<.link>`**

In the species table loop, replace the existing block:

```heex
                    <%= for sp <- @species do %>
                      <tr class="hover:bg-cyan-500/10">
                        <td class="py-0.5 flex items-center gap-1.5">
                          <span
                            class="inline-block w-2 h-2 shrink-0"
                            style={"background:#{Lenies.SpeciesColor.hex(sp.hash)}"}
                          >
                          </span>
                          <.link
                            navigate={~p"/species/#{sp.hash}"}
                            class="text-cyan-400 hover:text-cyan-200 hover:underline"
                          >
                            {String.slice(sp.hash, 0..7)}
                          </.link>
                        </td>
                        <td class="text-right">{sp.population}</td>
                        <td class="text-right">{Float.round(sp.avg_generation, 2)}</td>
                      </tr>
                    <% end %>
```

with:

```heex
                    <%= for sp <- @species do %>
                      <tr
                        class={[
                          "hover:bg-cyan-500/10 cursor-pointer",
                          @selected_hash == sp.hash && "bg-cyan-500/20 ring-1 ring-cyan-400"
                        ]}
                        phx-click="select_species"
                        phx-value-hash={sp.hash}
                      >
                        <td class="py-0.5 flex items-center gap-1.5">
                          <span
                            class="inline-block w-2 h-2 shrink-0"
                            style={"background:#{Lenies.SpeciesColor.hex(sp.hash)}"}
                          >
                          </span>
                          <span class="text-cyan-400">
                            {String.slice(sp.hash, 0..7)}
                          </span>
                        </td>
                        <td class="text-right">{sp.population}</td>
                        <td class="text-right">{Float.round(sp.avg_generation, 2)}</td>
                      </tr>
                    <% end %>
```

The whole row is now the click target. The hash is rendered as plain text. The `↗` button inside the inspector header still navigates to `/species/:hash` for users who want the full page.

- [ ] **Step 9: Render the inspector conditionally as a third top-row column**

Find the top-row flex container in the render (it has two children: the World panel and the Tel+Species grid). Locate the line:

```heex
          <div class="flex-1 grid grid-rows-2 gap-3 min-h-0">
```

Change it to (note the new `min-w-0`):

```heex
          <div class="flex-1 grid grid-rows-2 gap-3 min-h-0 min-w-0">
```

Then find the closing `</div>` of the Tel+Species grid (immediately before the existing `<.live_component module={LeniesWeb.ControlsPanelComponent} ... />`). Insert the inspector component right after it:

```heex
          <%= if @selected_hash do %>
            <.live_component
              module={LeniesWeb.SpeciesInspectorComponent}
              id="species-inspector"
              selected_hash={@selected_hash}
              species_record={@selected_species_record}
            />
          <% end %>
```

So the full top-row structure becomes:

```heex
        <div class="flex gap-3 min-h-0">
          <div class="panel p-3 flex flex-col gap-2 shrink-0">
            <!-- World panel (unchanged) -->
          </div>

          <div class="flex-1 grid grid-rows-2 gap-3 min-h-0 min-w-0">
            <!-- Telemetria + Specie (existing — with the new row-click block from Step 8) -->
          </div>

          <%= if @selected_hash do %>
            <.live_component
              module={LeniesWeb.SpeciesInspectorComponent}
              id="species-inspector"
              selected_hash={@selected_hash}
              species_record={@selected_species_record}
            />
          <% end %>
        </div>
```

(The `<.live_component module={LeniesWeb.ControlsPanelComponent} id="controls" />` stays where it is, outside this flex container.)

- [ ] **Step 10: Compile clean**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix compile --warnings-as-errors
```

Expected: clean (no warnings).

- [ ] **Step 11: Run dashboard tests**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: all tests pass, including the four new species-inspector tests.

- [ ] **Step 12: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green (modulo the telemetry flake).

- [ ] **Step 13: Visual smoke check in the browser**

The dev server should already be running. Open the dashboard:
1. Sterilize and spawn ~20 of any seed.
2. Wait for the species table to populate.
3. Click a row — the inspector appears on the right showing the hash, stats, and the disassembled codeome with category-colored opcode names.
4. Click the same row — panel closes.
5. Click a different row — panel updates to the new species.
6. Click `↗` — opens `/species/:hash`.
7. Click `×` — panel closes.
8. Watch the panel's `pop.` and `gen.` stats refresh on the same cadence as the species table while the world is running.

If any of these fail, stop and report.

- [ ] **Step 14: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex \
        test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat: dashboard wires up species inspector — row click toggles panel"
```

---

## Final sweep

- [ ] **Step 1: Run the full test suite one last time**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green except the known telemetry ring-buffer flake.

- [ ] **Step 2: Confirm the dropped table hash link doesn't survive anywhere**

```bash
grep -rn "navigate={~p\"/species/#{sp.hash}" lib test
```

Expected: no matches. The only remaining `navigate={~p"/species/...` use is in the inspector component header (`@selected_hash`, not `sp.hash`), which the above pattern excludes by design.

- [ ] **Step 3: Visual smoke check (repeat from Task 2 Step 13)**

Re-do the click-through to confirm everything is wired end-to-end after the final commits.
