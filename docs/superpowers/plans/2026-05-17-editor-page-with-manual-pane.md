# Codeome Editor Page with Manual Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the codeome editor from a modal to a dedicated `/editor/new` and `/editor/edit/:hash` LiveView page, with a collapsible left pane that renders the Programming Manual chapter-by-chapter for in-editor study and reference.

**Architecture:** New `Lenies.Manual` Agent loads `docs/manual/*.md` at boot, parses via Earmark, caches HTML. New `LeniesWeb.EditorLive` owns all edit-mode logic moved out of `SpeciesInspectorComponent`. New `LeniesWeb.ManualPaneComponent` renders the manual pane. JS hook `RememberManualState` persists collapse/last-chapter to localStorage. The old modal pathway is fully removed in the final task.

**Tech Stack:** Phoenix LiveView 1.1, Earmark (new dep, pure Elixir markdown), vanilla JS hook for localStorage.

**Spec:** `docs/superpowers/specs/2026-05-17-editor-page-with-manual-pane.md` — read it first.

---

## Invariant for every task

After each task's commit, the app must compile clean and `mix test` must pass. Each task is committed individually and pushed at the end (Task 7).

Setup PATH for every command:

```bash
export PATH="$HOME/.asdf/installs/elixir/1.19.3-otp-28/bin:$HOME/.asdf/installs/erlang/28.1.1/bin:/usr/local/bin:/usr/bin:/bin"
```

A Phoenix dev server is already running on port 4001; do not start a second one.

---

## Task 1: `Lenies.Manual` (Agent + supervision)

**Files:**
- Create: `lib/lenies/manual.ex`
- Create: `test/lenies/manual_test.exs`
- Modify: `mix.exs` (add `{:earmark, "~> 1.4"}` to deps)
- Modify: `lib/lenies/application.ex` (add `Lenies.Manual` to children list)

- [ ] **Step 1.1: Add Earmark dep**

In `mix.exs`, find the `defp deps do` block and add:

```elixir
{:earmark, "~> 1.4"},
```

Then run:

```bash
mix deps.get
mix compile
```

Expected: clean compile.

- [ ] **Step 1.2: Write failing test**

Create `test/lenies/manual_test.exs`:

```elixir
defmodule Lenies.ManualTest do
  use ExUnit.Case, async: false

  alias Lenies.Manual

  setup do
    case Process.whereis(Manual) do
      nil -> {:ok, _} = Manual.start_link([])
      _ -> :ok
    end
    :ok
  end

  test "list_chapters/0 returns all 12 chapters in filename order" do
    chapters = Manual.list_chapters()
    assert length(chapters) == 12

    filenames = Enum.map(chapters, & &1.filename)
    expected = ~w(
      README.md
      00-introduction.md
      01-vm-anatomy.md
      02-opcode-reference.md
      03-first-codeome.md
      04-loops-and-templates.md
      05-memory-and-arithmetic.md
      06-procedures.md
      07-replication.md
      08-energy-economy.md
      09-minimal-replicator.md
      10-cookbook.md
    )

    assert MapSet.new(filenames) == MapSet.new(expected)
  end

  test "each chapter has a non-empty title and html" do
    for ch <- Manual.list_chapters() do
      assert is_binary(ch.title)
      assert byte_size(ch.title) > 0
      entry = Manual.get(ch.filename)
      assert entry.html =~ "<"
    end
  end

  test "get/1 with unknown filename returns nil" do
    assert Manual.get("does-not-exist.md") == nil
  end
end
```

Run:

```bash
mix test test/lenies/manual_test.exs
```

Expected: fail (`Lenies.Manual` not defined).

- [ ] **Step 1.3: Implement `Lenies.Manual`**

Create `lib/lenies/manual.ex`:

```elixir
defmodule Lenies.Manual do
  @moduledoc """
  In-memory store for the Lenies Programming Manual. Loads every `.md`
  file under `docs/manual/` (or `priv/manual/` in releases) at boot,
  parses each with Earmark, and caches `%{title, html}` per filename.

  The editor page renders chapters from this store on demand. Files
  that fail to parse are logged and skipped; the rest of the manual
  is still served.
  """

  use Agent

  require Logger

  @spec start_link(any()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(fn -> load_all() end, name: __MODULE__)
  end

  @doc "Returns the list of loaded chapters, ordered by filename."
  @spec list_chapters() :: [%{filename: String.t(), title: String.t()}]
  def list_chapters do
    Agent.get(__MODULE__, fn state ->
      state
      |> Enum.map(fn {filename, %{title: title}} ->
        %{filename: filename, title: title}
      end)
      |> Enum.sort_by(& &1.filename)
    end)
  end

  @doc "Returns `%{title, html}` for the given chapter filename, or nil."
  @spec get(String.t()) :: %{title: String.t(), html: String.t()} | nil
  def get(filename) when is_binary(filename) do
    Agent.get(__MODULE__, &Map.get(&1, filename))
  end

  # ----- private -----

  defp load_all do
    dir = manual_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reduce(%{}, fn filename, acc ->
          path = Path.join(dir, filename)

          case load_one(path) do
            {:ok, entry} -> Map.put(acc, filename, entry)
            :error -> acc
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "Lenies.Manual: could not list #{dir} (#{inspect(reason)}); manual unavailable"
        )

        %{}
    end
  end

  defp manual_dir do
    priv = Application.app_dir(:lenies, "priv/manual")

    cond do
      File.dir?(priv) -> priv
      File.dir?("docs/manual") -> Path.expand("docs/manual")
      true -> priv
    end
  end

  defp load_one(path) do
    with {:ok, source} <- File.read(path),
         title when is_binary(title) <- extract_title(source),
         {:ok, html, _warnings} <- Earmark.as_html(source) do
      {:ok, %{title: title, html: html}}
    else
      error ->
        Logger.warning("Lenies.Manual: skipping #{path}: #{inspect(error)}")
        :error
    end
  end

  defp extract_title(source) do
    source
    |> String.split("\n", parts: 2)
    |> List.first()
    |> case do
      "# " <> rest -> String.trim(rest)
      _ -> Path.basename("(untitled)", ".md")
    end
  end
end
```

- [ ] **Step 1.4: Add to supervision tree**

In `lib/lenies/application.ex`, find the `children` list and add `Lenies.Manual` between `Lenies.Seeds.CustomStore` and `Lenies.LenieSupervisor`:

```elixir
children = [
  LeniesWeb.Telemetry,
  {DNSCluster, query: Application.get_env(:lenies, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: Lenies.PubSub},
  Lenies.Registry,
  Lenies.Seeds.CustomStore,
  Lenies.Manual,
  Lenies.LenieSupervisor,
  LeniesWeb.Endpoint
]
```

- [ ] **Step 1.5: Run tests**

```bash
mix test test/lenies/manual_test.exs 2>&1 | tail -3
mix test 2>&1 | tail -3
```

Expected: all pass (367 prior + 3 new = 370 tests).

- [ ] **Step 1.6: Commit**

```bash
git add mix.exs mix.lock lib/lenies/manual.ex lib/lenies/application.ex test/lenies/manual_test.exs
git commit -m "feat(manual): Lenies.Manual Agent loads + caches Programming Manual chapters"
```

---

## Task 2: `ManualPaneComponent` + `RememberManualState` JS hook

**Files:**
- Create: `lib/lenies_web/live/manual_pane_component.ex`
- Create: `assets/js/hooks/remember_manual_state.js`
- Modify: `assets/js/app.js` (register the new hook)
- Create: `test/lenies_web/live/manual_pane_component_test.exs`

- [ ] **Step 2.1: Write failing test**

Create `test/lenies_web/live/manual_pane_component_test.exs`:

```elixir
defmodule LeniesWeb.ManualPaneComponentTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LeniesWeb.ManualPaneComponent

  setup do
    case Process.whereis(Lenies.Manual) do
      nil -> {:ok, _} = Lenies.Manual.start_link([])
      _ -> :ok
    end
    :ok
  end

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        id: "manual-pane",
        chapter: "02-opcode-reference.md",
        collapsed?: false
      },
      overrides
    )
  end

  test "renders the chapter selector with all loaded chapters" do
    html = render_component(ManualPaneComponent, base_assigns())
    assert html =~ ~s(id="manual-chapter-select")
    assert html =~ "02-opcode-reference.md"
    assert html =~ "00-introduction.md"
    assert html =~ "10-cookbook.md"
  end

  test "renders the selected chapter's HTML in the content area" do
    html = render_component(ManualPaneComponent, base_assigns())
    # Chapter 2 is the opcode reference; its title contains "Opcode"
    assert html =~ "Opcode"
  end

  test "collapsed mode renders only the ribbon, not the dropdown" do
    html = render_component(ManualPaneComponent, base_assigns(%{collapsed?: true}))
    assert html =~ "manual-ribbon"
    refute html =~ ~s(id="manual-chapter-select")
  end

  test "expanded mode does not render the ribbon" do
    html = render_component(ManualPaneComponent, base_assigns(%{collapsed?: false}))
    refute html =~ "manual-ribbon"
  end
end
```

Run:

```bash
mix test test/lenies_web/live/manual_pane_component_test.exs
```

Expected: fail (component not defined).

- [ ] **Step 2.2: Implement component**

Create `lib/lenies_web/live/manual_pane_component.ex`:

```elixir
defmodule LeniesWeb.ManualPaneComponent do
  @moduledoc """
  Collapsible pane that renders one Lenies Programming Manual chapter
  at a time. Owns no state — receives `chapter` (filename) and
  `collapsed?` from the parent LiveView and bubbles `select_chapter`
  and `toggle_manual` events up.
  """

  use LeniesWeb, :live_component

  alias Lenies.Manual

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:chapters, fn -> Manual.list_chapters() end)
      |> assign_new(:entry, fn -> Manual.get(assigns.chapter) end)

    ~H"""
    <aside id={@id} class={["manual-pane", @collapsed? && "manual-pane-collapsed"]}>
      <%= if @collapsed? do %>
        <button
          type="button"
          phx-click="toggle_manual"
          class="manual-ribbon"
          title="Show manual"
        >
          ▶ Manual
        </button>
      <% else %>
        <header class="manual-pane-header">
          <form phx-change="select_chapter">
            <select
              id="manual-chapter-select"
              name="chapter"
              class="manual-chapter-select"
            >
              <%= for ch <- @chapters do %>
                <option value={ch.filename} selected={ch.filename == @chapter}>
                  {ch.title}
                </option>
              <% end %>
            </select>
          </form>
          <button
            type="button"
            phx-click="toggle_manual"
            class="manual-collapse-btn"
            title="Hide manual"
          >
            ◀
          </button>
        </header>

        <div
          id="manual-content"
          phx-hook="ManualLinkInterceptor"
          phx-update="ignore"
          class="manual-content"
        >
          <%= if @entry do %>
            {Phoenix.HTML.raw(@entry.html)}
          <% else %>
            <p class="manual-unavailable">Manual chapter unavailable.</p>
          <% end %>
        </div>
      <% end %>
    </aside>
    """
  end
end
```

- [ ] **Step 2.3: Implement `RememberManualState` + `ManualLinkInterceptor` JS hooks**

Create `assets/js/hooks/remember_manual_state.js`:

```javascript
// RememberManualState hook: at mount, reads localStorage for the user's
// last viewed chapter and last collapse state, and pushes them up so the
// EditorLive can restore the assigns. Subsequent server updates write
// back to localStorage.
//
// Attaches to the editor page root (NOT to the manual pane itself —
// the pane may be unmounted when collapsed).

const RememberManualState = {
  mounted() {
    const chapter = localStorage.getItem("lenies.manual.lastChapter");
    const collapsed = localStorage.getItem("lenies.manual.collapsed");

    const payload = {};
    if (chapter) payload.chapter = chapter;
    if (collapsed !== null) payload.collapsed = collapsed === "true";

    if (Object.keys(payload).length > 0) {
      this.pushEvent("restore_manual_state", payload);
    }

    this.handleEvent("persist_manual_state", ({ chapter, collapsed }) => {
      if (typeof chapter === "string") {
        localStorage.setItem("lenies.manual.lastChapter", chapter);
      }
      if (typeof collapsed === "boolean") {
        localStorage.setItem("lenies.manual.collapsed", String(collapsed));
      }
    });
  },
};

export default RememberManualState;
```

Create `assets/js/hooks/manual_link_interceptor.js`:

```javascript
// ManualLinkInterceptor hook: rewrites in-content clicks on chapter
// links ([text](04-loops-and-templates.md)) into pushEvent
// select_chapter calls, so cross-chapter navigation works inside the
// manual pane without triggering a full page load.

const ManualLinkInterceptor = {
  mounted() {
    this.handler = (event) => {
      const a = event.target.closest("a[href]");
      if (!a) return;
      const href = a.getAttribute("href");
      if (!href || !href.endsWith(".md")) return;

      event.preventDefault();
      this.pushEvent("select_chapter", { chapter: href });
    };

    this.el.addEventListener("click", this.handler);
  },

  destroyed() {
    if (this.handler) {
      this.el.removeEventListener("click", this.handler);
    }
  },
};

export default ManualLinkInterceptor;
```

- [ ] **Step 2.4: Register hooks in `assets/js/app.js`**

Open `assets/js/app.js`. Find the imports block (around lines 25–31) and add:

```javascript
import RememberManualState from "./hooks/remember_manual_state"
import ManualLinkInterceptor from "./hooks/manual_link_interceptor"
```

Then update the `Hooks` declaration (line ~33) to include them:

```javascript
const Hooks = {GridCanvas, ActionFeedback, CodeomeSortable, ConfirmAction, CodeomePalette, WorldDetailCanvas, RememberManualState, ManualLinkInterceptor, ...colocatedHooks}
```

- [ ] **Step 2.5: Run tests + build assets**

```bash
mix assets.build 2>&1 | tail -5
mix test test/lenies_web/live/manual_pane_component_test.exs 2>&1 | tail -3
mix test 2>&1 | tail -3
```

Expected: all pass; build succeeds (no JS bundling errors).

- [ ] **Step 2.6: Commit**

```bash
git add lib/lenies_web/live/manual_pane_component.ex \
        assets/js/hooks/remember_manual_state.js \
        assets/js/hooks/manual_link_interceptor.js \
        assets/js/app.js \
        test/lenies_web/live/manual_pane_component_test.exs
git commit -m "feat(manual): ManualPaneComponent + JS hooks for localStorage + chapter links"
```

---

## Task 3: `EditorLive` (full-page) — initial skeleton

**Files:**
- Create: `lib/lenies_web/live/editor_live.ex`
- Modify: `lib/lenies_web/router.ex` (two new routes)
- Modify: `assets/css/app.css` (add `.codeome-editor-page` and grid rules)
- Create: `test/lenies_web/live/editor_live_test.exs`

This task creates the new page with a minimal three-column shell that
renders the manual pane and **stub** palette + listing panes. Edit
machinery (drag-drop, save, spawn, validation) is moved in Task 4.
The page is reachable but its palette/listing are placeholders.

- [ ] **Step 3.1: Add routes**

In `lib/lenies_web/router.ex`, add inside the existing browser scope:

```elixir
live "/editor/new", EditorLive, :new
live "/editor/edit/:hash", EditorLive, :edit
```

The block becomes:

```elixir
scope "/", LeniesWeb do
  pipe_through :browser

  live "/", DashboardLive, :index
  live "/lenie/:id", LenieInspectorLive, :show
  live "/species/:hash", SpeciesLive, :show
  live "/editor/new", EditorLive, :new
  live "/editor/edit/:hash", EditorLive, :edit
end
```

- [ ] **Step 3.2: Add CSS for the editor page**

Append to `assets/css/app.css`:

```css
/* ----- Codeome editor page ----- */
.lenies-dashboard .codeome-editor-page {
  display: grid;
  grid-template-rows: auto 1fr;
  height: 100vh;
  overflow: hidden;
}

.lenies-dashboard .codeome-editor-page-header {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.75rem 1rem;
  border-bottom: 1px solid rgba(34, 211, 238, 0.2);
  background: rgba(2, 6, 23, 0.5);
}

.lenies-dashboard .editor-grid {
  display: grid;
  grid-template-columns: 380px 360px 1fr;
  gap: 0.75rem;
  padding: 0.75rem;
  min-height: 0;
  overflow: hidden;
}

.lenies-dashboard .editor-grid.manual-collapsed {
  grid-template-columns: 24px 360px 1fr;
}

.lenies-dashboard .manual-pane {
  display: flex;
  flex-direction: column;
  border: 1px solid rgba(34, 211, 238, 0.2);
  background: rgba(2, 6, 23, 0.4);
  min-height: 0;
  overflow: hidden;
}

.lenies-dashboard .manual-pane-header {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 4px 6px;
  border-bottom: 1px solid rgba(34, 211, 238, 0.15);
}

.lenies-dashboard .manual-chapter-select {
  flex: 1 1 auto;
  font-size: 11px;
  background: rgba(15, 23, 42, 0.7);
  color: #e2e8f0;
  border: 1px solid rgba(34, 211, 238, 0.25);
  padding: 2px 4px;
}

.lenies-dashboard .manual-collapse-btn {
  border: 1px solid rgba(34, 211, 238, 0.4);
  background: transparent;
  color: #67e8f9;
  padding: 0 6px;
  font-size: 11px;
}

.lenies-dashboard .manual-content {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding: 0.75rem;
  font-size: 13px;
  line-height: 1.5;
  color: #cbd5e1;
}

.lenies-dashboard .manual-content h1 { font-size: 18px; color: #22d3ee; margin: 0.5rem 0; }
.lenies-dashboard .manual-content h2 { font-size: 15px; color: #67e8f9; margin: 0.75rem 0 0.25rem; }
.lenies-dashboard .manual-content h3 { font-size: 13px; color: #67e8f9; margin: 0.5rem 0 0.2rem; }
.lenies-dashboard .manual-content p { margin: 0.4rem 0; }
.lenies-dashboard .manual-content code { font-family: ui-monospace, "JetBrains Mono", monospace; background: rgba(15, 23, 42, 0.7); padding: 1px 3px; border-radius: 2px; }
.lenies-dashboard .manual-content pre { background: rgba(15, 23, 42, 0.85); border: 1px solid rgba(34, 211, 238, 0.15); padding: 6px; overflow-x: auto; font-size: 12px; }
.lenies-dashboard .manual-content pre code { background: none; padding: 0; }
.lenies-dashboard .manual-content table { border-collapse: collapse; font-size: 11px; }
.lenies-dashboard .manual-content th, .lenies-dashboard .manual-content td { border: 1px solid rgba(34, 211, 238, 0.15); padding: 3px 6px; }
.lenies-dashboard .manual-content a { color: #22d3ee; text-decoration: underline; }
.lenies-dashboard .manual-unavailable { opacity: 0.5; font-style: italic; }

.lenies-dashboard .manual-pane-collapsed {
  border: none;
  background: transparent;
  padding: 0;
}

.lenies-dashboard .manual-ribbon {
  writing-mode: vertical-rl;
  transform: rotate(180deg);
  border: 1px solid rgba(34, 211, 238, 0.4);
  background: rgba(15, 23, 42, 0.7);
  color: #67e8f9;
  font-size: 10px;
  padding: 6px 2px;
  width: 24px;
  height: 100%;
  cursor: pointer;
}
```

- [ ] **Step 3.3: Implement EditorLive skeleton**

Create `lib/lenies_web/live/editor_live.ex`:

```elixir
defmodule LeniesWeb.EditorLive do
  @moduledoc """
  Full-page codeome editor. Owns drag-drop palette + listing, plus a
  collapsible left pane that renders the Lenies Programming Manual for
  in-editor study and reference.

  Routes:
    /editor/new          — empty buffer (new seed)
    /editor/edit/:hash   — buffer pre-loaded from a representative
                           Lenie of the given species hash
  """

  use LeniesWeb, :live_view

  alias Lenies.Manual

  @default_chapter "02-opcode-reference.md"

  @impl true
  def mount(params, _session, socket) do
    {mode, selected_hash, buffer} = init_for_route(socket.assigns.live_action, params)

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:selected_hash, selected_hash)
      |> assign(:buffer, buffer)
      |> assign(:current_chapter, @default_chapter)
      |> assign(:manual_collapsed?, false)

    {:ok, socket}
  end

  defp init_for_route(:new, _params) do
    {:new_seed, nil, []}
  end

  defp init_for_route(:edit, %{"hash" => hash}) do
    buffer =
      case Lenies.Species.for_hash(hash) do
        [{sample_id, _} | _] ->
          case safe_get_codeome(sample_id) do
            {:ok, codeome} -> Lenies.Codeome.to_list(codeome)
            _ -> []
          end

        [] ->
          []
      end

    {:edit, hash, buffer}
  end

  defp safe_get_codeome(id) do
    case Lenies.Registry.whereis(id) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :get_codeome, 1_000)
        catch
          :exit, _ -> {:error, :dead}
        end

      _ ->
        {:error, :not_alive}
    end
  end

  @impl true
  def handle_event("select_chapter", %{"chapter" => filename}, socket) do
    {:noreply,
     socket
     |> assign(:current_chapter, filename)
     |> push_event("persist_manual_state", %{chapter: filename})}
  end

  def handle_event("toggle_manual", _params, socket) do
    new_collapsed = !socket.assigns.manual_collapsed?

    {:noreply,
     socket
     |> assign(:manual_collapsed?, new_collapsed)
     |> push_event("persist_manual_state", %{collapsed: new_collapsed})}
  end

  def handle_event("restore_manual_state", payload, socket) do
    socket =
      socket
      |> maybe_assign(:current_chapter, payload["chapter"])
      |> maybe_assign(:manual_collapsed?, payload["collapsed"])

    {:noreply, socket}
  end

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="editor-root" phx-hook="RememberManualState" class="lenies-dashboard codeome-editor-page">
      <header class="codeome-editor-page-header">
        <.link navigate={back_to(@mode, @selected_hash)} class="text-xs px-2 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10">
          ← Back
        </.link>
        <h1 class="text-sm flex-1">
          <%= if @mode == :new_seed do %>
            New Seed
          <% else %>
            Edit: {String.slice(@selected_hash || "", 0..15)}…
          <% end %>
        </h1>
        <span class="text-[10px] opacity-60">{length(@buffer)} ops</span>
      </header>

      <div class={["editor-grid", @manual_collapsed? && "manual-collapsed"]}>
        <.live_component
          module={LeniesWeb.ManualPaneComponent}
          id="manual-pane"
          chapter={@current_chapter}
          collapsed?={@manual_collapsed?}
        />

        <section class="palette-pane-placeholder">
          <div class="text-xs opacity-60 p-2">Palette pane (Task 4)</div>
        </section>

        <section class="listing-pane-placeholder">
          <div class="text-xs opacity-60 p-2">Listing pane (Task 4)</div>
        </section>
      </div>
    </div>
    """
  end

  defp back_to(:new_seed, _hash), do: ~p"/"
  defp back_to(:edit, nil), do: ~p"/"
  defp back_to(:edit, hash), do: ~p"/species/#{hash}"
end
```

- [ ] **Step 3.4: Write tests**

Create `test/lenies_web/live/editor_live_test.exs`:

```elixir
defmodule LeniesWeb.EditorLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    case Process.whereis(Lenies.World) do
      nil -> {:ok, _} = Lenies.World.start_link(tick_interval_ms: 0)
      _ -> :ok
    end

    case Process.whereis(Lenies.Manual) do
      nil -> {:ok, _} = Lenies.Manual.start_link([])
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

  test "mounts on /editor/new with empty buffer", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/editor/new")
    assert html =~ "New Seed"
    assert html =~ ~s(id="manual-pane")
  end

  test "mounts on /editor/edit/:hash with empty buffer when hash unknown", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/editor/edit/NONEXISTENT")
    assert html =~ "Edit: NONEXISTENT"
    assert html =~ "0 ops"
  end

  test "toggling the manual pane updates the grid class", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    refute render(view) =~ "manual-collapsed"

    render_hook(view, "toggle_manual", %{})

    assert render(view) =~ "manual-collapsed"
  end

  test "selecting a chapter updates the current chapter", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "select_chapter", %{"chapter" => "04-loops-and-templates.md"})

    html = render(view)
    assert html =~ ~r/Loops|Templates/
  end
end
```

- [ ] **Step 3.5: Verify and commit**

```bash
mix compile --warning-as-errors 2>&1 | tail -3
mix test test/lenies_web/live/editor_live_test.exs 2>&1 | tail -3
mix test 2>&1 | tail -3
```

Expected: all pass.

```bash
git add lib/lenies_web/router.ex \
        assets/css/app.css \
        lib/lenies_web/live/editor_live.ex \
        test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): EditorLive page skeleton with manual pane (no edit machinery yet)"
```

---

## Task 4: Move edit machinery into EditorLive

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex` (port edit-mode logic)
- Modify: `assets/css/app.css` (CSS for the three full panes — palette + listing classes already exist from earlier modal work; keep them)
- Modify: `test/lenies_web/live/editor_live_test.exs` (add edit-flow tests)

This is the largest single task: port `enter_edit`-style buffer, drag-drop, save, spawn, validation from `SpeciesInspectorComponent` into `EditorLive`. The old component keeps its edit code for now — it will be stripped in Task 6.

- [ ] **Step 4.1: Read the source to port**

```bash
sed -n '78,220p' lib/lenies_web/live/species_inspector_component.ex   # handle_events
sed -n '460,610p' lib/lenies_web/live/species_inspector_component.ex  # editor render
```

Note: the relevant pieces are:
- assigns: `:edit_mode`, `:buffer`, `:dirty`, `:validation`, `:show_spawn_form`, `:show_save_form`
- handle_events: `edit_delete`, `edit_reorder`, `edit_insert`, `open_spawn_form`, `cancel_spawn_form`, `submit_spawn`, `open_save_form`, `cancel_save_form`, `submit_save_seed`, `cancel_edit`
- private helpers: `apply_buffer_change/2`, `parse_clamped/4`, `slug/1`, `suggested_color/1`, `format_validation_error/1`, `notify_parent_dirty/2` (this one becomes unused — the LiveView owns its own dirty state)
- the palette + listing markup with `phx-hook="CodeomePalette"` and `phx-hook="CodeomeSortable"`

- [ ] **Step 4.2: Port handle_events and helpers**

Add to `lib/lenies_web/live/editor_live.ex`, after the existing `handle_event` clauses (in handle_event grouping order):

```elixir
  def handle_event("edit_delete", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    new_buffer = LeniesWeb.CodeomeBuffer.delete(socket.assigns.buffer, index)
    {:noreply, apply_buffer_change(socket, new_buffer)}
  end

  def handle_event("edit_reorder", %{"from" => from, "to" => to}, socket) do
    new_buffer = LeniesWeb.CodeomeBuffer.move(socket.assigns.buffer, from, to)
    {:noreply, apply_buffer_change(socket, new_buffer)}
  end

  def handle_event("edit_insert", %{"index" => index, "opcode" => opcode_str}, socket)
      when is_integer(index) and is_binary(opcode_str) do
    try do
      opcode = String.to_existing_atom(opcode_str)

      if Lenies.Codeome.Opcodes.known?(opcode) do
        new_buffer = LeniesWeb.CodeomeBuffer.insert(socket.assigns.buffer, index, opcode)
        {:noreply, apply_buffer_change(socket, new_buffer)}
      else
        {:noreply, socket}
      end
    rescue
      ArgumentError -> {:noreply, socket}
    end
  end

  def handle_event("open_spawn_form", _params, socket) do
    {:noreply, assign(socket, show_spawn_form: true, show_save_form: false)}
  end

  def handle_event("cancel_spawn_form", _params, socket) do
    {:noreply, assign(socket, :show_spawn_form, false)}
  end

  def handle_event("submit_spawn", %{"count" => count_str, "energy" => energy_str}, socket) do
    count = parse_clamped(count_str, 1, 50, 1)
    energy = parse_clamped(energy_str, 1, 1_000_000, 10_000)

    case socket.assigns.validation do
      {:ok, _} ->
        codeome = LeniesWeb.CodeomeBuffer.to_codeome(socket.assigns.buffer)
        dirs = [:n, :s, :e, :w]

        Enum.each(1..count, fn _ ->
          Lenies.World.spawn_lenie(codeome, energy: energy * 1.0, dir: Enum.random(dirs))
        end)

        {:noreply, push_navigate(socket, to: ~p"/")}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("open_save_form", _params, socket) do
    {:noreply, assign(socket, show_save_form: true, show_spawn_form: false)}
  end

  def handle_event("cancel_save_form", _params, socket) do
    {:noreply, assign(socket, :show_save_form, false)}
  end

  def handle_event(
        "submit_save_seed",
        %{"seed_name" => name, "color_hex" => color, "energy_default" => energy_str},
        socket
      ) do
    case socket.assigns.validation do
      {:ok, _} ->
        seed = %{
          id: slug(name),
          name: name,
          color_hex: color,
          energy_default: parse_clamped(energy_str, 1, 1_000_000, 10_000) * 1.0,
          opcodes: socket.assigns.buffer
        }

        case Lenies.Seeds.CustomStore.save(seed) do
          :ok ->
            Phoenix.LiveView.send_update(LeniesWeb.ControlsPanelComponent,
              id: "controls",
              refresh_custom_seeds: true
            )

            {:noreply, push_navigate(socket, to: ~p"/")}

          {:error, _reason} ->
            {:noreply, socket}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, push_navigate(socket, to: back_to(socket.assigns.mode, socket.assigns.selected_hash))}
  end
```

And at the end of the module, add:

```elixir
  defp apply_buffer_change(socket, new_buffer) do
    original = socket.assigns[:original_buffer] || socket.assigns.buffer
    dirty = new_buffer != original

    socket
    |> assign(:buffer, new_buffer)
    |> assign(:dirty, dirty)
    |> assign(:validation, LeniesWeb.CodeomeBuffer.validate(new_buffer))
  end

  defp parse_clamped(str, min, max, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n |> max(min) |> min(max)
      :error -> default
    end
  end

  defp parse_clamped(_, _, _, default), do: default

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp suggested_color(buffer) do
    buffer
    |> Lenies.Codeome.from_list()
    |> Lenies.Codeome.hash()
    |> Lenies.SpeciesColor.hex()
  end

  defp format_validation_error({:too_short, opts}),
    do: "too short (#{opts[:got]} ops, min #{opts[:min]})"

  defp format_validation_error({:too_long, opts}),
    do: "too long (#{opts[:got]} ops, max #{opts[:max]})"

  defp format_validation_error({:insufficient_non_nops, opts}),
    do: "too few non-nops (#{opts[:got]}, min #{opts[:min]})"
```

Also extend the `mount/3` to seed the additional assigns:

```elixir
  @impl true
  def mount(params, _session, socket) do
    {mode, selected_hash, buffer} = init_for_route(socket.assigns.live_action, params)

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:selected_hash, selected_hash)
      |> assign(:buffer, buffer)
      |> assign(:original_buffer, buffer)
      |> assign(:dirty, false)
      |> assign(:validation, LeniesWeb.CodeomeBuffer.validate(buffer))
      |> assign(:show_spawn_form, false)
      |> assign(:show_save_form, false)
      |> assign(:current_chapter, @default_chapter)
      |> assign(:manual_collapsed?, false)

    {:ok, socket}
  end
```

- [ ] **Step 4.3: Implement the palette + listing markup in `render/1`**

Replace the placeholder `<section>` blocks in `EditorLive.render/1` with real palette + listing, modeled exactly on the existing modal markup. The full new render becomes:

```elixir
  alias LeniesWeb.Disassembler

  @impl true
  def render(assigns) do
    ~H"""
    <div id="editor-root" phx-hook="RememberManualState" class="lenies-dashboard codeome-editor-page">
      <header class="codeome-editor-page-header">
        <.link navigate={back_to(@mode, @selected_hash)} class="text-xs px-2 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10">
          ← Back
        </.link>
        <h1 class="text-sm flex-1">
          <%= if @mode == :new_seed do %>
            New Seed
          <% else %>
            Edit: {String.slice(@selected_hash || "", 0..15)}…
          <% end %>
        </h1>

        <span class="text-[10px]">
          <%= case @validation do %>
            <% {:ok, info} -> %>
              <span class="text-emerald-300">✓ valid</span>
              <span class="opacity-60">({info.len} ops, {info.non_nops} non-nop)</span>
            <% {:error, errors} -> %>
              <span class="text-amber-300">⚠</span>
              <span class="opacity-80">{Enum.map_join(errors, ", ", &format_validation_error/1)}</span>
          <% end %>
        </span>

        <%= if @dirty do %>
          <span class="text-amber-300 text-[10px]">●dirty</span>
        <% end %>

        <button
          type="button"
          phx-click="cancel_edit"
          data-confirm={if @dirty, do: "Discard codeome edits?"}
          class="text-xs px-2 py-0.5 border border-slate-500 hover:bg-slate-700"
        >Cancel</button>

        <button
          type="button"
          phx-click="open_spawn_form"
          disabled={!match?({:ok, _}, @validation)}
          class="text-xs px-2 py-0.5 border border-emerald-500/60 text-emerald-200 hover:bg-emerald-900/40 disabled:opacity-40"
        >Spawn</button>

        <%= if @mode == :new_seed do %>
          <button
            type="button"
            phx-click="open_save_form"
            disabled={!match?({:ok, _}, @validation)}
            class="text-xs px-2 py-0.5 border border-violet-500/60 text-violet-200 hover:bg-violet-900/40 disabled:opacity-40"
          >Save</button>
        <% end %>
      </header>

      <%= if @show_spawn_form do %>
        <form phx-submit="submit_spawn" class="flex gap-2 items-center text-[11px] p-2 border-b border-emerald-500/30">
          <label class="flex gap-1 items-center"><span class="opacity-70">count</span>
            <input type="number" name="count" value="1" min="1" max="50" class="w-16 text-xs" />
          </label>
          <label class="flex gap-1 items-center"><span class="opacity-70">energy</span>
            <input type="number" name="energy" value="10000" min="1" max="1000000" class="w-24 text-xs" />
          </label>
          <button type="button" phx-click="cancel_spawn_form" class="px-2 py-0.5 border border-slate-500">Cancel</button>
          <button type="submit" class="px-2 py-0.5 border border-emerald-500/60 text-emerald-200">Spawn</button>
        </form>
      <% end %>

      <%= if @show_save_form do %>
        <form phx-submit="submit_save_seed" class="flex gap-2 items-center text-[11px] p-2 border-b border-violet-500/30">
          <label class="flex gap-1 items-center"><span class="opacity-70">name</span>
            <input type="text" name="seed_name" required minlength="1" maxlength="40" placeholder="my replicator v1" class="text-xs" />
          </label>
          <label class="flex gap-1 items-center"><span class="opacity-70">color</span>
            <input type="color" name="color_hex" value={suggested_color(@buffer)} class="w-12 h-6" />
          </label>
          <label class="flex gap-1 items-center"><span class="opacity-70">energy</span>
            <input type="number" name="energy_default" value="10000" min="1" max="1000000" class="w-24 text-xs" />
          </label>
          <button type="button" phx-click="cancel_save_form" class="px-2 py-0.5 border border-slate-500">Cancel</button>
          <button type="submit" class="px-2 py-0.5 border border-violet-500/60 text-violet-200">Save</button>
        </form>
      <% end %>

      <div class={["editor-grid", @manual_collapsed? && "manual-collapsed"]}>
        <.live_component
          module={LeniesWeb.ManualPaneComponent}
          id="manual-pane"
          chapter={@current_chapter}
          collapsed?={@manual_collapsed?}
        />

        <section class="codeome-palette-pane min-h-0">
          <div class="codeome-palette-pane-title">Opcodes — drag to insert</div>
          <div class="codeome-palette" id="palette-grid" phx-hook="CodeomePalette">
            <%= for {category, ops} <- grouped_opcodes() do %>
              <div class="palette-category">
                <div class="palette-category-label">{category}</div>
                <div class="palette-category-chips">
                  <%= for op <- ops do %>
                    <div class={"palette-chip op op-" <> Atom.to_string(Disassembler.opcode_class(op))} data-opcode={Atom.to_string(op)}>
                      {Atom.to_string(op) |> String.upcase()}
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </section>

        <section class="codeome-listing-pane min-h-0 overflow-auto">
          <div class="codeome-listing-pane-title">Codeome — {length(@buffer)} ops</div>
          <div
            class="codeome-blocks"
            id={"codeome-blocks-#{@mode}-#{@selected_hash || "new"}"}
            phx-hook="CodeomeSortable"
          >
            <%= for {opcode, idx} <- Enum.with_index(@buffer) do %>
              <div class="codeome-insert-slot"></div>
              <div class={"codeome-block codeome-block-editable op op-" <> Atom.to_string(Disassembler.opcode_class(opcode))} data-idx={idx}>
                <span class="codeome-drag-handle" title="Drag to reorder">≡</span>
                <span class="codeome-block-idx">{String.pad_leading(Integer.to_string(idx), 3, "0")}</span>
                <span class="codeome-block-name">{Atom.to_string(opcode) |> String.upcase()}</span>
                <span class="codeome-block-actions">
                  <button type="button" phx-click="edit_delete" phx-value-index={idx} class="codeome-action-btn" title="Delete">⨯</button>
                </span>
              </div>
            <% end %>
            <div class="codeome-insert-slot"></div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  defp grouped_opcodes do
    Lenies.Codeome.Opcodes.all()
    |> Enum.group_by(&Disassembler.opcode_class/1)
    |> Enum.sort_by(fn {class, _} -> class_order(class) end)
  end

  defp class_order(:template), do: 0
  defp class_order(:stack), do: 1
  defp class_order(:arith), do: 2
  defp class_order(:control), do: 3
  defp class_order(:sense), do: 4
  defp class_order(:action), do: 5
  defp class_order(:predation), do: 6
  defp class_order(:self_inspect), do: 7
  defp class_order(:replication), do: 8
  defp class_order(:memory), do: 9
  defp class_order(_), do: 10
```

- [ ] **Step 4.4: Add edit-flow tests**

Extend `test/lenies_web/live/editor_live_test.exs` with three tests appended before the final `end`:

```elixir
  test "/editor/edit/:hash loads codeome of a live species", %{conn: conn} do
    codeome = Lenies.Codeomes.MinimalReplicator.codeome()
    hash = Lenies.Codeome.hash(codeome)

    {:ok, _pid} =
      Lenies.Lenie.start_link(
        id: "TEST-EDITOR-L1",
        codeome: codeome,
        energy: 100.0,
        pos: {0, 0},
        dir: :n,
        lineage: {nil, 0}
      )

    :ets.insert(:lenies, {"TEST-EDITOR-L1", %{id: "TEST-EDITOR-L1", codeome_hash: hash}})

    {:ok, _view, html} = live(conn, "/editor/edit/#{hash}")
    assert html =~ "121 ops"
  end

  test "drag-drop insert via edit_insert handler appends opcode and marks dirty", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    refute render(view) =~ "●dirty"

    render_hook(view, "edit_insert", %{"index" => 0, "opcode" => "push0"})

    html = render(view)
    assert html =~ "1 ops"
    assert html =~ "●dirty"
  end

  test "delete handler removes the opcode at the given index", %{conn: conn} do
    {:ok, view, _} = live(conn, "/editor/new")
    render_hook(view, "edit_insert", %{"index" => 0, "opcode" => "push0"})
    render_hook(view, "edit_insert", %{"index" => 1, "opcode" => "push1"})
    render_hook(view, "edit_delete", %{"index" => "0"})

    html = render(view)
    assert html =~ "1 ops"
    refute html =~ "PUSH0"
  end
```

- [ ] **Step 4.5: Verify and commit**

```bash
mix compile --warning-as-errors 2>&1 | tail -3
mix test test/lenies_web/live/editor_live_test.exs 2>&1 | tail -3
mix test 2>&1 | tail -3
```

Expected: all pass.

```bash
git add lib/lenies_web/live/editor_live.ex test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): port drag-drop, save, spawn, validation into EditorLive"
```

---

## Task 5: Wire navigation from dashboard + inspector

**Files:**
- Modify: `lib/lenies_web/live/controls_panel_component.ex` (the `+ New Seed` button)
- Modify: `lib/lenies_web/live/species_inspector_component.ex` (the `Edit` button)

After this task, users start hitting the new editor page through the
normal UI. The old modal-via-`editor_mode` flow still exists as dead
code (cleaned up in Task 6).

- [ ] **Step 5.1: Change the `+ New Seed` button**

Open `lib/lenies_web/live/controls_panel_component.ex`. Find the
button with `id="world-detail-open"` neighbour, the `+ New Seed`
button. Replace its `<button ... phx-click="open_codeome_editor" phx-target={@myself}>` with:

```heex
          <.link
            id="open-codeome-editor"
            navigate={~p"/editor/new"}
            class="px-2 py-0.5 border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40"
          >
            + New Seed
          </.link>
```

Also remove the `handle_event("open_codeome_editor", _params, socket)` clause from the file (since the button no longer triggers it).

- [ ] **Step 5.2: Change the `Edit` button on the species inspector**

Open `lib/lenies_web/live/species_inspector_component.ex`. Find the button:

```heex
<%= if @editor_mode != :new_seed and not @edit_mode do %>
  <button
    type="button"
    phx-click="enter_edit"
    phx-target={@myself}
    class="..."
  >
    Edit
  </button>
<% end %>
```

Replace it with a navigate link:

```heex
<%= if @selected_hash do %>
  <.link
    id="open-edit-for-species"
    navigate={~p"/editor/edit/#{@selected_hash}"}
    class="px-2 py-0.5 border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40"
  >
    Edit
  </.link>
<% end %>
```

Leave the `enter_edit` handle_event in place for now — Task 6 strips it.

- [ ] **Step 5.3: Update affected tests**

Open `test/lenies_web/live/dashboard_live_test.exs`. The test
`"clicking + New Seed sends :open_codeome_editor to dashboard"`
(around line 320) and the `editor_mode :new_seed flow` describe
block need updating. Replace those tests with:

```elixir
  describe "controls panel — new seed entry point" do
    test "+ New Seed link navigates to /editor/new", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      assert {:error, {:live_redirect, %{to: "/editor/new"}}} =
               view
               |> element("#open-codeome-editor")
               |> render_click()
    end
  end
```

And delete the old `describe "editor_mode :new_seed flow" do` block entirely (the new editor doesn't use `editor_mode`).

Open `test/lenies_web/live/species_inspector_component_test.exs`.
Find the test `"Edit button visible in read mode"`:

```elixir
test "Edit button visible in read mode" do
  html = render_component(SpeciesInspectorComponent, base_assigns())
  assert html =~ ~s(phx-click="enter_edit")
  refute html =~ ~s(phx-click="cancel_edit")
end
```

Replace with:

```elixir
test "Edit link visible in read mode and navigates to /editor/edit/:hash" do
  html = render_component(SpeciesInspectorComponent, base_assigns())
  assert html =~ ~s(href="/editor/edit/abc12345abc12345")
  refute html =~ ~s(phx-click="enter_edit")
end
```

- [ ] **Step 5.4: Verify and commit**

```bash
mix compile --warning-as-errors 2>&1 | tail -3
mix test 2>&1 | tail -3
```

Expected: all pass.

```bash
git add lib/lenies_web/live/controls_panel_component.ex \
        lib/lenies_web/live/species_inspector_component.ex \
        test/lenies_web/live/dashboard_live_test.exs \
        test/lenies_web/live/species_inspector_component_test.exs
git commit -m "feat(editor): route + New Seed and Edit through the new editor page"
```

---

## Task 6: Strip legacy modal code

**Files:**
- Modify: `lib/lenies_web/live/species_inspector_component.ex` (remove all edit-mode machinery)
- Modify: `lib/lenies_web/live/dashboard_live.ex` (remove `editor_mode` assign + related handlers)
- Modify: `assets/css/app.css` (remove `.codeome-editor-modal*`, `.codeome-editor-backdrop`)
- Modify: `test/lenies_web/live/species_inspector_component_test.exs` (delete edit-mode tests)

After this task, the modal pathway no longer exists.

- [ ] **Step 6.1: Strip `SpeciesInspectorComponent`**

The component's `update/2` `:new_seed` clause becomes unreachable
(nothing sets `:new_seed` editor_mode anymore). Remove:

- The first clause `def update(%{editor_mode: :new_seed} = assigns, socket)` entirely.
- The `:edit_mode`, `:buffer`, `:dirty`, `:picker_open` (already gone), `:validation`, `:show_spawn_form`, `:show_save_form`, `:editor_mode` assigns from `mount/1`.
- All `handle_event` clauses for `enter_edit`, `cancel_edit`, `edit_delete`, `edit_reorder`, `edit_insert`, `open_spawn_form`, `cancel_spawn_form`, `submit_spawn`, `open_save_form`, `cancel_save_form`, `submit_save_seed`.
- Private helpers `apply_buffer_change/2`, `parse_clamped/4`, `slug/1`, `suggested_color/1`, `format_validation_error/1`, `notify_parent_dirty/2`.
- The `<%= if @edit_mode do %>...<% end %>` branches in `render/1`.
- The save form, spawn form, palette, sortable, and modal CSS classes — the inspector now only shows: header (hash, color, ↗ link, × close, **Edit** link from Task 5), validation block, stats grid, codeome listing (read-only — no insert slots, no drag handles, no delete buttons).

The simplest way: read the current file, identify everything that depends on `@edit_mode` / `@buffer` / `@validation` etc., delete those branches, and remove the now-orphaned helpers.

After the strip, `update/2` only has the `selected_hash` clause and the catchall. Render becomes:

```elixir
@impl true
def render(assigns) do
  ~H"""
  <aside id="species-inspector" class="panel w-[320px] shrink-0 flex flex-col gap-2 p-3 min-h-0">
    <header class="flex items-center gap-2">
      <span class="inline-block w-3 h-3 shrink-0" style={"background:#{SpeciesColor.hex(@selected_hash)}"}></span>
      <h2 class="text-xs flex-1 truncate">{String.slice(@selected_hash, 0..15)}…</h2>
      <.link navigate={~p"/species/#{@selected_hash}"} class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10" title="Open full species page">↗</.link>
      <%= if @selected_hash do %>
        <.link id="open-edit-for-species" navigate={~p"/editor/edit/#{@selected_hash}"} class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10">Edit</.link>
      <% end %>
      <button
        id={"inspector-close-#{@selected_hash}"}
        phx-click="select_species"
        phx-value-hash={@selected_hash}
        class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
      >×</button>
    </header>

    <div class="grid grid-cols-3 gap-2 text-[11px]">
      <div class="border border-cyan-500/30 px-2 py-1">
        <div class="opacity-60">pop.</div>
        <div class="text-cyan-300 font-bold tabular-nums text-base">{population(@species_record)}</div>
      </div>
      <div class="border border-violet-500/30 px-2 py-1">
        <div class="opacity-60">gen.</div>
        <div class="text-violet-300 font-bold tabular-nums text-base">{avg_gen(@species_record)}</div>
      </div>
      <div class="border border-emerald-500/30 px-2 py-1">
        <div class="opacity-60">ops</div>
        <div class="text-emerald-300 font-bold tabular-nums text-base">{length(@codeome_lines)}</div>
      </div>
    </div>

    <%= if @fetch_status == :no_sample do %>
      <p class="text-[10px] opacity-60">No live Lenie of this species. Codeome unavailable.</p>
    <% end %>

    <div class="flex-1 min-h-0 overflow-auto">
      <div class="codeome-blocks" id={"codeome-blocks-#{@selected_hash}"}>
        <%= for line <- @codeome_lines do %>
          <div class={"codeome-block op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
            <span class="codeome-block-idx">{String.pad_leading(Integer.to_string(line.index), 3, "0")}</span>
            <span class="codeome-block-name">{Atom.to_string(line.opcode) |> String.upcase()}</span>
          </div>
        <% end %>
      </div>
    </div>
  </aside>
  """
end
```

- [ ] **Step 6.2: Strip `DashboardLive` editor plumbing**

In `lib/lenies_web/live/dashboard_live.ex`:

- Remove `|> assign(:editor_mode, nil)` from `mount/3`.
- Remove `handle_info(:open_codeome_editor, ...)` clause (it's a leftover from the old modal flow).
- Remove `handle_info({:editor_mode, mode}, socket)` clause if present.
- Remove the `<%= if @selected_hash || @editor_mode == :new_seed do %>` branch — replace with just `<%= if @selected_hash do %>`.
- The `live_component` call for `SpeciesInspectorComponent` drops the `editor_mode={@editor_mode}` prop.

- [ ] **Step 6.3: Strip stale CSS**

Remove from `assets/css/app.css`:
- `.codeome-editor-modal`
- `.codeome-editor-backdrop` (if still present)
- `.codeome-editor-body`
- `.codeome-palette-pane` rules tied to the modal (keep the rule definition; it's reused by the editor page)
- `.codeome-listing-pane` rules tied to the modal (same — keep, reused)

Practically: identify the rules that begin with `.codeome-editor-modal` or that only apply inside the modal (via parent selector `.codeome-editor-modal .foo`), and rewrite them to apply unconditionally (or rename if conflicting). The palette + listing pane styles need to survive because the editor page uses them.

- [ ] **Step 6.4: Drop edit-mode tests**

In `test/lenies_web/live/species_inspector_component_test.exs`,
delete all tests that use `render_seeded` with `edit_mode: true`,
all tests for `enter_edit` / `cancel_edit` / `edit_delete` /
`edit_insert` / save form / spawn form / picker / Escape key
(the `phx-window-keydown` test).

Keep only tests for: header, hash rendering, ↗ link, × button, stats,
fetch behavior, the new "Edit link navigates" test from Task 5.

- [ ] **Step 6.5: Verify and commit**

```bash
mix compile --warning-as-errors 2>&1 | tail -3
mix test 2>&1 | tail -3
```

Expected: all pass (test count drops — that's expected, dozens of edit-mode tests are now gone, replaced by the EditorLive suite).

```bash
git add lib/lenies_web/live/species_inspector_component.ex \
        lib/lenies_web/live/dashboard_live.ex \
        assets/css/app.css \
        test/lenies_web/live/species_inspector_component_test.exs
git commit -m "refactor(editor): remove modal pathway — SpeciesInspectorComponent is read-only, DashboardLive drops editor_mode"
```

---

## Task 7: Final regression, manual smoke test, push

- [ ] **Step 7.1: Full test sweep + clean compile**

```bash
mix compile --warning-as-errors 2>&1 | tail -3
mix test 2>&1 | tail -3
mix precommit 2>&1 | tail -10
```

Expected: clean compile, all tests green, precommit succeeds.

- [ ] **Step 7.2: Manual browser smoke test**

Open <http://localhost:4001>:

1. On the dashboard, click **+ New Seed** in the controls panel.
2. URL changes to `/editor/new`. The editor page renders:
   - Header with `← Back`, `New Seed`, validation banner, `Cancel`, `Spawn`, `Save` buttons.
   - Three columns: manual pane (left, 380 px, dropdown shows 12 chapters, content shows chapter 2 by default), palette (centre, 36 chips), listing (right, empty).
3. Drag a `push0` chip from the palette into the listing. It appears as the first block. The header validation banner updates (`⚠ too short...`). The `●dirty` indicator appears.
4. Drag enough chips to make the buffer valid (≥ 10 non-nop ops in a buffer length ≥ 5). The validation banner switches to `✓ valid (N ops, M non-nop)` and the **Spawn** + **Save** buttons enable.
5. Click the **◀** in the manual pane header. The manual pane collapses to a 24 px vertical ribbon labelled `▶ Manual`. Reload the page; the collapsed state persists (localStorage).
6. Click the ribbon. The pane expands again.
7. Pick a different chapter from the dropdown. The content area swaps. Reload the page; the picked chapter persists.
8. Click `← Back` to return to the dashboard. The dashboard is unchanged.
9. Click on a species row → inspector opens on the right. Click **Edit**. URL changes to `/editor/edit/<hash>`. The codeome is pre-loaded.
10. Click `← Back`. You return to `/species/<hash>` (the species detail page, not the dashboard) — this is intentional.
11. Spawn and Save flows on `/editor/new`: clicking `Spawn` opens the spawn form; submitting it spawns 1 Lenie and navigates back to `/`. Clicking `Save` opens the save form; submitting it persists a custom seed and navigates back to `/`.

If any step fails, identify the file, fix, recompile, re-test, then re-do the smoke test.

- [ ] **Step 7.3: Push**

```bash
git push origin master
```

---

## Self-review (already performed by the plan author)

1. **Spec coverage:**
   - `Lenies.Manual` Agent + tests → Task 1.
   - Earmark dep → Task 1.
   - `ManualPaneComponent` + tests → Task 2.
   - `RememberManualState` JS hook → Task 2.
   - `ManualLinkInterceptor` JS hook → Task 2.
   - `EditorLive` skeleton → Task 3.
   - Edit machinery ported in → Task 4.
   - `/editor/new` and `/editor/edit/:hash` routes → Task 3.
   - `+ New Seed` and `Edit` navigation rewiring → Task 5.
   - `SpeciesInspectorComponent` reverts to read-only → Task 6.
   - `DashboardLive` strips `editor_mode` → Task 6.
   - CSS migration (drop modal, keep palette/listing reused, add editor page) → Tasks 3 + 6.
   - Test updates → Tasks 5 + 6.
   - Manual smoke test → Task 7.

2. **Placeholder scan:** None. Every step is a concrete file edit, mix command, or commit.

3. **Type / name consistency:**
   - `Lenies.Manual.list_chapters/0` / `get/1` used identically across tasks.
   - Routes `/editor/new` and `/editor/edit/:hash` used consistently in router (Task 3), navigation calls (Task 5), tests (Tasks 3 + 5).
   - `current_chapter` / `manual_collapsed?` assigns used consistently in EditorLive (Task 3), component (Task 2), JS hook (Task 2).
   - Edit handlers and helpers ported in Task 4 retain the names from `SpeciesInspectorComponent` so the JS hooks (which push `edit_insert`, `edit_reorder`, `edit_delete` events) keep working without changes.
