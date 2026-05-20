# Codeome Editor Ergonomics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add block selection + clipboard, a persistent snippet library, and undo/redo to the codeome editor (`LeniesWeb.EditorLive`).

**Architecture:** Server-authoritative. Selection, clipboard, and undo/redo history live in `EditorLive` assigns; all mutation logic lives in pure, ExUnit-testable modules (`LeniesWeb.CodeomeBuffer`, `LeniesWeb.EditorHistory`, `Lenies.Snippets.Store`); a thin JS hook (`EditorKeyboard`) translates clicks and keyboard shortcuts into LiveView events. LiveView tests drive the server events directly via `render_hook`/`render_click`, so the JS hook is built last and needs no unit tests.

**Tech Stack:** Elixir 1.19 / Phoenix LiveView, ExUnit, SortableJS (existing), Jason, esbuild/tailwind (mix profiles named `lenies`).

**Reference spec:** `docs/superpowers/specs/2026-05-20-codeome-editor-ergonomics-design.md`

**Environment note:** `mix` is provided via asdf. Prefix every shell command with `. ~/.asdf/asdf.sh &&`. A dev server may already hold the `_build/dev` lock; run `mix compile` / `mix test` under `MIX_ENV=test` to use the separate test build dir and avoid the lock.

**Deviation from spec (YAGNI):** The spec mentioned both `Lenies.Snippets` and `Lenies.Snippets.Store`. There are no built-in snippets to merge, so a separate facade adds nothing. This plan implements only `Lenies.Snippets.Store` and calls it directly from `EditorLive` (mirroring how `CustomStore` is used directly).

---

## File Structure

**Create:**
- `lib/lenies/slug.ex` — shared `Lenies.Slug.slugify/1` (extracted from `EditorLive`).
- `lib/lenies_web/editor_history.ex` — undo/redo struct + `record/2`, `undo/2`, `redo/2`.
- `lib/lenies/snippets/store.ex` — `Agent`-backed JSON snippet store (`priv/user_snippets.json`).
- `assets/js/hooks/editor_keyboard.js` — click/shift-click selection + keyboard shortcuts.
- `test/lenies/slug_test.exs`, `test/lenies_web/editor_history_test.exs`, `test/lenies/snippets/store_test.exs`.

**Modify:**
- `lib/lenies_web/codeome_buffer.ex` — add `slice/2`, `delete_range/2`, `insert_many/3`.
- `lib/lenies_web/live/editor_live.ex` — new assigns, events, `commit_buffer_change/2`, toolbar, snippet section, selection highlight; use `Lenies.Slug`.
- `lib/lenies/application.ex` — add `Lenies.Snippets.Store` to the supervision tree.
- `assets/js/app.js` — register `EditorKeyboard` hook.
- `assets/css/app.css` — selected-block highlight, toolbar, snippet section styles.
- `test/lenies_web/codeome_buffer_test.exs`, `test/lenies_web/live/editor_live_test.exs`.

---

## Task 1: Extract shared slug helper

**Files:**
- Create: `lib/lenies/slug.ex`
- Create: `test/lenies/slug_test.exs`
- Modify: `lib/lenies_web/live/editor_live.ex` (replace private `slug/1`, lines ~548-553 and call at ~178)

- [ ] **Step 1: Write the failing test**

Create `test/lenies/slug_test.exs`:

```elixir
defmodule Lenies.SlugTest do
  use ExUnit.Case, async: true

  test "lowercases and hyphenates" do
    assert Lenies.Slug.slugify("My Replicator V1") == "my-replicator-v1"
  end

  test "collapses non-alphanumeric runs and trims edge hyphens" do
    assert Lenies.Slug.slugify("  Foo!!__bar  ") == "foo-bar"
  end

  test "empty / all-symbol input yields empty string" do
    assert Lenies.Slug.slugify("***") == ""
    assert Lenies.Slug.slugify("") == ""
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/slug_test.exs`
Expected: FAIL — `Lenies.Slug.slugify/1 is undefined (module Lenies.Slug is not available)`.

- [ ] **Step 3: Create the module**

Create `lib/lenies/slug.ex`:

```elixir
defmodule Lenies.Slug do
  @moduledoc "Turns a human name into a URL/id-safe slug."

  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/slug_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Use it in EditorLive**

In `lib/lenies_web/live/editor_live.ex`, replace the call at the `submit_save_seed` handler:

```elixir
          id: slug(name),
```

with:

```elixir
          id: Lenies.Slug.slugify(name),
```

Then delete the private `slug/1` function:

```elixir
  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
```

- [ ] **Step 6: Compile and verify the editor test still passes**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: compile clean; all editor tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/lenies/slug.ex test/lenies/slug_test.exs lib/lenies_web/live/editor_live.ex
git commit -m "refactor(editor): extract Lenies.Slug shared helper"
```

---

## Task 2: CodeomeBuffer range operations

**Files:**
- Modify: `lib/lenies_web/codeome_buffer.ex`
- Modify: `test/lenies_web/codeome_buffer_test.exs`

These are pure functions. A "range" is an inclusive `{lo, hi}` tuple of 0-based buffer indices with `lo <= hi`.

- [ ] **Step 1: Write the failing tests**

Append to `test/lenies_web/codeome_buffer_test.exs` (inside the existing `defmodule ... do`, before the final `end`):

```elixir
  describe "slice/2" do
    test "returns the inclusive range of opcodes" do
      assert CodeomeBuffer.slice([:a, :b, :c, :d], {1, 2}) == [:b, :c]
    end

    test "single-element range" do
      assert CodeomeBuffer.slice([:a, :b, :c], {0, 0}) == [:a]
    end

    test "clamps hi to the last index" do
      assert CodeomeBuffer.slice([:a, :b], {0, 9}) == [:a, :b]
    end
  end

  describe "delete_range/2" do
    test "removes the inclusive range" do
      assert CodeomeBuffer.delete_range([:a, :b, :c, :d], {1, 2}) == [:a, :d]
    end

    test "deleting the whole buffer yields []" do
      assert CodeomeBuffer.delete_range([:a, :b], {0, 1}) == []
    end

    test "clamps hi beyond the end" do
      assert CodeomeBuffer.delete_range([:a, :b, :c], {1, 9}) == [:a]
    end
  end

  describe "insert_many/3" do
    test "inserts a list at the index" do
      assert CodeomeBuffer.insert_many([:a, :d], 1, [:b, :c]) == [:a, :b, :c, :d]
    end

    test "index 0 prepends" do
      assert CodeomeBuffer.insert_many([:c], 0, [:a, :b]) == [:a, :b, :c]
    end

    test "index past the end appends" do
      assert CodeomeBuffer.insert_many([:a], 9, [:b]) == [:a, :b]
    end

    test "inserting an empty list is a no-op" do
      assert CodeomeBuffer.insert_many([:a, :b], 1, []) == [:a, :b]
    end
  end
```

(The existing test file already has `alias LeniesWeb.CodeomeBuffer` or uses the full name — match whichever it uses. If it uses the full module name, replace `CodeomeBuffer.` with `LeniesWeb.CodeomeBuffer.` in the snippets above.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/codeome_buffer_test.exs`
Expected: FAIL — `slice/2`, `delete_range/2`, `insert_many/3` undefined.

- [ ] **Step 3: Implement the functions**

In `lib/lenies_web/codeome_buffer.ex`, add after `move/3` (before `validate/1`):

```elixir
  @doc "Copy the inclusive `{lo, hi}` range out of the buffer."
  @spec slice(buffer(), {non_neg_integer(), non_neg_integer()}) :: buffer()
  def slice(buffer, {lo, hi}) when lo >= 0 and hi >= lo do
    Enum.slice(buffer, lo..hi)
  end

  @doc "Delete the inclusive `{lo, hi}` range from the buffer."
  @spec delete_range(buffer(), {non_neg_integer(), non_neg_integer()}) :: buffer()
  def delete_range(buffer, {lo, hi}) when lo >= 0 and hi >= lo do
    {before, rest} = Enum.split(buffer, lo)
    before ++ Enum.drop(rest, hi - lo + 1)
  end

  @doc "Insert a list of opcodes at `index` (clamped to the buffer length)."
  @spec insert_many(buffer(), non_neg_integer(), [atom()]) :: buffer()
  def insert_many(buffer, index, opcodes) when index >= 0 and is_list(opcodes) do
    clamped = min(index, length(buffer))
    {before, rest} = Enum.split(buffer, clamped)
    before ++ opcodes ++ rest
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/codeome_buffer_test.exs`
Expected: PASS (all existing + 10 new).

- [ ] **Step 5: Commit**

```bash
git add lib/lenies_web/codeome_buffer.ex test/lenies_web/codeome_buffer_test.exs
git commit -m "feat(editor): CodeomeBuffer slice/delete_range/insert_many"
```

---

## Task 3: EditorHistory undo/redo module

**Files:**
- Create: `lib/lenies_web/editor_history.ex`
- Create: `test/lenies_web/editor_history_test.exs`

`%EditorHistory{past: [buffer], future: [buffer], max: pos_integer}`. `past` is most-recent-first. `record/2` pushes the previous buffer (called *before* applying a change) and clears `future`. `undo/2`/`redo/2` take the *current* buffer so they can move it across the two stacks.

- [ ] **Step 1: Write the failing tests**

Create `test/lenies_web/editor_history_test.exs`:

```elixir
defmodule LeniesWeb.EditorHistoryTest do
  use ExUnit.Case, async: true

  alias LeniesWeb.EditorHistory

  test "new/1 starts empty with the given max" do
    h = EditorHistory.new(50)
    assert h.past == []
    assert h.future == []
    assert h.max == 50
  end

  test "record pushes prev buffer and clears future" do
    h = EditorHistory.new(50) |> Map.put(:future, [[:x]])
    h = EditorHistory.record(h, [:a])
    assert h.past == [[:a]]
    assert h.future == []
  end

  test "undo moves current onto future and returns the last past buffer" do
    h = EditorHistory.new(50) |> EditorHistory.record([:a])
    assert {[:a], h2} = EditorHistory.undo(h, [:b])
    assert h2.past == []
    assert h2.future == [[:b]]
  end

  test "undo on empty past returns :none" do
    assert EditorHistory.undo(EditorHistory.new(50), [:b]) == :none
  end

  test "redo moves current onto past and returns the last future buffer" do
    h = EditorHistory.new(50) |> EditorHistory.record([:a])
    {[:a], h2} = EditorHistory.undo(h, [:b])
    assert {[:b], h3} = EditorHistory.redo(h2, [:a])
    assert h3.past == [[:a]]
    assert h3.future == []
  end

  test "redo on empty future returns :none" do
    assert EditorHistory.redo(EditorHistory.new(50), [:a]) == :none
  end

  test "record drops oldest past beyond max depth" do
    h =
      Enum.reduce(1..5, EditorHistory.new(3), fn n, acc ->
        EditorHistory.record(acc, [n])
      end)

    # max 3: keeps the 3 most-recent pushes (5, 4, 3), drops 2 and 1
    assert h.past == [[5], [4], [3]]
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/editor_history_test.exs`
Expected: FAIL — module `LeniesWeb.EditorHistory` not available.

- [ ] **Step 3: Implement the module**

Create `lib/lenies_web/editor_history.ex`:

```elixir
defmodule LeniesWeb.EditorHistory do
  @moduledoc """
  Undo/redo stacks for the codeome editor buffer.

  `past` and `future` hold whole-buffer snapshots (buffers are small —
  bounded by the codeome length cap — so full snapshots are simpler than
  diffs). `past` is most-recent-first. Bounded by `max`: recording beyond
  `max` discards the oldest snapshot.
  """

  @type buffer :: [atom()]
  @type t :: %__MODULE__{past: [buffer()], future: [buffer()], max: pos_integer()}

  defstruct past: [], future: [], max: 100

  @spec new(pos_integer()) :: t()
  def new(max \\ 100) when is_integer(max) and max > 0 do
    %__MODULE__{past: [], future: [], max: max}
  end

  @doc "Record `prev_buffer` (the buffer before a change) and clear redo."
  @spec record(t(), buffer()) :: t()
  def record(%__MODULE__{} = h, prev_buffer) do
    %{h | past: Enum.take([prev_buffer | h.past], h.max), future: []}
  end

  @doc "Undo: returns `{restored_buffer, history}` or `:none` if nothing to undo."
  @spec undo(t(), buffer()) :: {buffer(), t()} | :none
  def undo(%__MODULE__{past: []}, _current), do: :none

  def undo(%__MODULE__{past: [prev | rest]} = h, current) do
    {prev, %{h | past: rest, future: [current | h.future]}}
  end

  @doc "Redo: returns `{restored_buffer, history}` or `:none` if nothing to redo."
  @spec redo(t(), buffer()) :: {buffer(), t()} | :none
  def redo(%__MODULE__{future: []}, _current), do: :none

  def redo(%__MODULE__{future: [next | rest]} = h, current) do
    {next, %{h | past: [current | h.past], future: rest}}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/editor_history_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/lenies_web/editor_history.ex test/lenies_web/editor_history_test.exs
git commit -m "feat(editor): EditorHistory undo/redo module"
```

---

## Task 4: Snippets store

**Files:**
- Create: `lib/lenies/snippets/store.ex`
- Create: `test/lenies/snippets/store_test.exs`
- Modify: `lib/lenies/application.ex`

Mirrors `Lenies.Seeds.CustomStore` (Agent + JSON at `priv/user_snippets.json`, test override via `:__test_user_snippets_file__`). A snippet is `%{id, name, opcodes}`. `id` = `Lenies.Slug.slugify(name)` (set by the caller). `save/1` upserts by `id`.

- [ ] **Step 1: Write the failing tests**

Create `test/lenies/snippets/store_test.exs`:

```elixir
defmodule Lenies.Snippets.StoreTest do
  use ExUnit.Case, async: false

  alias Lenies.Snippets.Store

  @tmp_file_env :__test_user_snippets_file__

  setup do
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "lenies_user_snippets_#{System.unique_integer([:positive])}.json"
      )

    original_path = Application.get_env(:lenies, @tmp_file_env)
    Application.put_env(:lenies, @tmp_file_env, tmp_path)

    if Process.whereis(Store), do: Agent.stop(Store)
    {:ok, _pid} = Store.start_link([])

    on_exit(fn ->
      if Process.whereis(Store) do
        try do
          Agent.stop(Store)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm(tmp_path)

      if original_path do
        Application.put_env(:lenies, @tmp_file_env, original_path)
      else
        Application.delete_env(:lenies, @tmp_file_env)
      end
    end)

    {:ok, tmp_path: tmp_path}
  end

  defp snippet(overrides \\ %{}) do
    Map.merge(%{id: "loop", name: "Loop", opcodes: [:nop_0, :eat, :move]}, overrides)
  end

  test "starts empty" do
    assert Store.all() == []
  end

  test "save then all returns the snippet" do
    assert :ok = Store.save(snippet())
    assert [%{id: "loop", name: "Loop", opcodes: [:nop_0, :eat, :move]}] = Store.all()
  end

  test "save upserts by id (same id overwrites)" do
    :ok = Store.save(snippet())
    :ok = Store.save(snippet(%{opcodes: [:move]}))
    assert [%{id: "loop", opcodes: [:move]}] = Store.all()
  end

  test "rejects empty name" do
    assert {:error, :invalid_name} = Store.save(snippet(%{name: "  ", id: "x"}))
  end

  test "rejects unknown opcodes" do
    assert {:error, :invalid_opcodes} = Store.save(snippet(%{opcodes: [:not_a_real_op]}))
  end

  test "delete removes by id" do
    :ok = Store.save(snippet())
    :ok = Store.delete("loop")
    assert Store.all() == []
  end

  test "persists across a restart (reload from disk)" do
    :ok = Store.save(snippet())
    Agent.stop(Store)
    {:ok, _} = Store.start_link([])
    assert [%{id: "loop", opcodes: [:nop_0, :eat, :move]}] = Store.all()
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/snippets/store_test.exs`
Expected: FAIL — module `Lenies.Snippets.Store` not available.

- [ ] **Step 3: Implement the store**

Create `lib/lenies/snippets/store.ex`:

```elixir
defmodule Lenies.Snippets.Store do
  @moduledoc """
  Persistent registry of user-saved codeome snippets (reusable opcode
  fragments for the editor).

  Backed by a JSON file at `priv/user_snippets.json` (configurable via the
  `:__test_user_snippets_file__` app env key — used by tests). State lives
  in an `Agent`. Mirrors `Lenies.Seeds.CustomStore`.

  A snippet is `%{id, name, opcodes}`. `id` is the caller-supplied slug;
  `save/1` upserts by `id`. Snippets are fragments — no length validation.
  """

  use Agent, restart: :transient

  @type snippet :: %{id: String.t(), name: String.t(), opcodes: [atom()]}

  def start_link(_opts) do
    Agent.start_link(fn -> load_from_disk() end, name: __MODULE__)
  end

  @spec all() :: [snippet()]
  def all, do: Agent.get(__MODULE__, & &1)

  @spec get(String.t()) :: nil | snippet()
  def get(id) when is_binary(id) do
    Agent.get(__MODULE__, fn snips -> Enum.find(snips, &(&1.id == id)) end)
  end

  @spec save(snippet()) ::
          :ok | {:error, :invalid_name | :invalid_opcodes | :io_error}
  def save(%{} = snippet) do
    with :ok <- validate_name(snippet),
         :ok <- validate_opcodes(snippet) do
      new =
        Agent.get_and_update(__MODULE__, fn snips ->
          ns = [snippet | Enum.reject(snips, &(&1.id == snippet.id))]
          {ns, ns}
        end)

      safe_write(new)
    end
  end

  @spec delete(String.t()) :: :ok | {:error, :io_error}
  def delete(id) when is_binary(id) do
    new =
      Agent.get_and_update(__MODULE__, fn snips ->
        ns = Enum.reject(snips, &(&1.id == id))
        {ns, ns}
      end)

    safe_write(new)
  end

  # ----- validation -----

  defp validate_name(%{name: name, id: id}) when is_binary(name) and is_binary(id) do
    cond do
      String.trim(name) == "" -> {:error, :invalid_name}
      id == "" -> {:error, :invalid_name}
      true -> :ok
    end
  end

  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_opcodes(%{opcodes: ops}) when is_list(ops) and ops != [] do
    whitelist = MapSet.new(Lenies.Codeome.Opcodes.all())

    if Enum.all?(ops, fn op -> is_atom(op) and MapSet.member?(whitelist, op) end) do
      :ok
    else
      {:error, :invalid_opcodes}
    end
  end

  defp validate_opcodes(_), do: {:error, :invalid_opcodes}

  # ----- file I/O -----

  defp safe_write(snips) do
    try do
      write_to_disk(snips)
      :ok
    rescue
      _e in [File.Error] -> {:error, :io_error}
    end
  end

  defp file_path do
    case Application.get_env(:lenies, :__test_user_snippets_file__) do
      path when is_binary(path) -> path
      _ -> Path.join(:code.priv_dir(:lenies), "user_snippets.json")
    end
  end

  defp load_from_disk do
    Code.ensure_loaded!(Lenies.Codeome.Opcodes)
    path = file_path()

    case File.read(path) do
      {:ok, contents} -> parse_contents(contents, path)
      {:error, _} -> []
    end
  end

  defp parse_contents(contents, path) do
    case Jason.decode(contents) do
      {:ok, list} when is_list(list) ->
        list |> Enum.map(&decode_snippet/1) |> Enum.filter(& &1)

      _ ->
        File.rename(path, path <> ".bak")
        []
    end
  end

  defp decode_snippet(%{} = m) do
    try do
      ops = Enum.map(m["opcodes"] || [], &String.to_existing_atom/1)
      %{id: m["id"], name: m["name"], opcodes: ops}
    rescue
      ArgumentError ->
        require Logger
        Logger.warning("Lenies.Snippets.Store: dropping snippet #{inspect(m["id"])} — unknown opcode(s)")
        nil
    end
  end

  defp decode_snippet(_), do: nil

  defp write_to_disk(snips) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))

    json =
      snips
      |> Enum.map(fn s ->
        %{"id" => s.id, "name" => s.name, "opcodes" => Enum.map(s.opcodes, &Atom.to_string/1)}
      end)
      |> Jason.encode!(pretty: true)

    tmp = path <> ".tmp"
    File.write!(tmp, json)
    File.rename!(tmp, path)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/snippets/store_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Add to the supervision tree**

In `lib/lenies/application.ex`, add `Lenies.Snippets.Store` to the `children` list right after `Lenies.Seeds.CustomStore`:

```elixir
    children = [
      LeniesWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:lenies, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Lenies.PubSub},
      Lenies.Registry,
      Lenies.Seeds.CustomStore,
      Lenies.Snippets.Store,
      Lenies.Manual,
      Lenies.LenieSupervisor,
      LeniesWeb.Endpoint
    ]
```

- [ ] **Step 6: Compile and run the store test again (full app boot path)**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test test/lenies/snippets/store_test.exs`
Expected: compile clean; 7 tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/lenies/snippets/store.ex test/lenies/snippets/store_test.exs lib/lenies/application.ex
git commit -m "feat(editor): persistent Snippets.Store"
```

---

## Task 5: EditorLive selection state + highlight

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`
- Modify: `test/lenies_web/live/editor_live_test.exs`

Adds `:selection` (`{lo, hi} | nil`) and `:sel_anchor` (`non_neg_integer | nil`) assigns, the `select_block` and `clear_selection` events, and a `.codeome-block-selected` class on rendered blocks. Tests drive `select_block` via `render_hook` (no JS hook yet).

- [ ] **Step 1: Write the failing tests**

Append inside `test/lenies_web/live/editor_live_test.exs` (before the final `end`). The editor `/editor/new` route starts with an empty buffer, so first append a few opcodes via the existing `submit_opcode_text` event to have blocks to select:

```elixir
  describe "block selection" do
    defp seeded_editor(conn) do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add move eat"})
      view
    end

    test "click selects a single block and highlights it", %{conn: conn} do
      view = seeded_editor(conn)
      html = render_hook(view, "select_block", %{"index" => 2, "shift" => false})
      # the block at idx 2 carries the selected class
      assert html =~ ~r/codeome-block-editable[^"]*codeome-block-selected[^>]*data-idx="2"/ or
               html =~ ~r/data-idx="2"[^>]*codeome-block-selected/
    end

    test "shift-click extends a range from the anchor", %{conn: conn} do
      view = seeded_editor(conn)
      render_hook(view, "select_block", %{"index" => 1, "shift" => false})
      html = render_hook(view, "select_block", %{"index" => 3, "shift" => true})
      # idx 1,2,3 selected; idx 0 and 4 not
      assert html =~ ~s(data-idx="1")
      selected_count =
        Regex.scan(~r/codeome-block-selected/, html) |> length()
      assert selected_count == 3
    end

    test "clear_selection removes all highlights", %{conn: conn} do
      view = seeded_editor(conn)
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      html = render_hook(view, "clear_selection", %{})
      refute html =~ "codeome-block-selected"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: FAIL — no `select_block` handler (raises) / class never present.

- [ ] **Step 3: Add the assigns**

In `mount/3`, add to the assign pipeline (after `:text_input_error`):

```elixir
      |> assign(:selection, nil)
      |> assign(:sel_anchor, nil)
```

- [ ] **Step 4: Add the event handlers**

Add these handlers (e.g. after `submit_opcode_text`):

```elixir
  def handle_event("select_block", %{"index" => index, "shift" => shift}, socket) do
    index = to_int(index)
    len = length(socket.assigns.buffer)

    if index < 0 or index >= len do
      {:noreply, socket}
    else
      {selection, anchor} =
        if shift in [true, "true"] and is_integer(socket.assigns.sel_anchor) do
          a = socket.assigns.sel_anchor
          {{min(a, index), max(a, index)}, a}
        else
          {{index, index}, index}
        end

      {:noreply, assign(socket, selection: selection, sel_anchor: anchor)}
    end
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selection: nil, sel_anchor: nil)}
  end
```

Add this private helper near `parse_clamped/4`:

```elixir
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: String.to_integer(n)
```

- [ ] **Step 5: Render the selected class + a selection helper**

Add a private helper near `apply_buffer_change/2`:

```elixir
  defp selected?(nil, _idx), do: false
  defp selected?({lo, hi}, idx), do: idx >= lo and idx <= hi
```

In `render/1`, change the editable block class (the `<div class={"codeome-block ..."} data-idx={idx}>` element in the `codeome-blocks` listing) to add the selected class. Replace:

```elixir
              <div
                class={"codeome-block codeome-block-editable op op-" <> Atom.to_string(Disassembler.opcode_class(opcode))}
                data-idx={idx}
              >
```

with:

```elixir
              <div
                class={[
                  "codeome-block codeome-block-editable op op-" <>
                    Atom.to_string(Disassembler.opcode_class(opcode)),
                  selected?(@selection, idx) && "codeome-block-selected"
                ]}
                data-idx={idx}
              >
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS (existing + 3 new selection tests).

- [ ] **Step 7: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): block range selection state + highlight"
```

---

## Task 6: EditorLive clipboard, delete, duplicate

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`
- Modify: `test/lenies_web/live/editor_live_test.exs`

Adds `:clipboard` assign and the `copy_selection`, `cut_selection`, `paste_clipboard`, `duplicate_selection`, `delete_selection` events. Uses `commit_buffer_change/2` for the mutating ones — but `commit_buffer_change/2` itself (with history) lands in Task 7; for now route mutations through the existing `apply_buffer_change/2` and switch them to `commit_buffer_change/2` in Task 7. To avoid rework, define `commit_buffer_change/2` here as a thin alias of `apply_buffer_change/2`, and Task 7 adds history inside it.

- [ ] **Step 1: Write the failing tests**

Append inside `test/lenies_web/live/editor_live_test.exs` (before the final `end`):

```elixir
  describe "clipboard and editing" do
    defp seeded_editor2(conn) do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add move eat"})
      view
    end

    defp listing_opcodes(html) do
      Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
      |> Enum.map(fn [_, name] -> name end)
    end

    test "copy then paste duplicates the range after the selection", %{conn: conn} do
      view = seeded_editor2(conn)
      # select idx 0..1 (PUSH0 PUSH1), copy, paste -> inserted after idx 1
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "select_block", %{"index" => 1, "shift" => true})
      render_hook(view, "copy_selection", %{})
      html = render_hook(view, "paste_clipboard", %{})
      assert listing_opcodes(html) ==
               ["PUSH0", "PUSH1", "PUSH0", "PUSH1", "ADD", "MOVE", "EAT"]
    end

    test "cut removes the range and fills the clipboard", %{conn: conn} do
      view = seeded_editor2(conn)
      render_hook(view, "select_block", %{"index" => 1, "shift" => false})
      render_hook(view, "select_block", %{"index" => 2, "shift" => true})
      html = render_hook(view, "cut_selection", %{})
      assert listing_opcodes(html) == ["PUSH0", "MOVE", "EAT"]
      # paste brings them back at the end (no selection after cut)
      html2 = render_hook(view, "paste_clipboard", %{})
      assert listing_opcodes(html2) == ["PUSH0", "MOVE", "EAT", "PUSH1", "ADD"]
    end

    test "delete_selection removes the range", %{conn: conn} do
      view = seeded_editor2(conn)
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "select_block", %{"index" => 2, "shift" => true})
      html = render_hook(view, "delete_selection", %{})
      assert listing_opcodes(html) == ["MOVE", "EAT"]
    end

    test "duplicate_selection inserts a copy right after", %{conn: conn} do
      view = seeded_editor2(conn)
      render_hook(view, "select_block", %{"index" => 3, "shift" => false})
      html = render_hook(view, "duplicate_selection", %{})
      assert listing_opcodes(html) == ["PUSH0", "PUSH1", "ADD", "MOVE", "MOVE", "EAT"]
    end

    test "copy/paste with empty clipboard is a no-op", %{conn: conn} do
      view = seeded_editor2(conn)
      html = render_hook(view, "paste_clipboard", %{})
      assert listing_opcodes(html) == ["PUSH0", "PUSH1", "ADD", "MOVE", "EAT"]
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: FAIL — no `copy_selection`/`paste_clipboard`/etc handlers.

- [ ] **Step 3: Add the `:clipboard` assign**

In `mount/3`, add after `:sel_anchor`:

```elixir
      |> assign(:clipboard, [])
```

- [ ] **Step 4: Add `commit_buffer_change/2` (thin for now)**

Add near `apply_buffer_change/2`:

```elixir
  # Central buffer-mutation entry point. Task 7 adds undo history here;
  # for now it delegates to apply_buffer_change/2.
  defp commit_buffer_change(socket, new_buffer) do
    apply_buffer_change(socket, new_buffer)
  end
```

- [ ] **Step 5: Add the clipboard/edit handlers**

Add after the `clear_selection` handler:

```elixir
  def handle_event("copy_selection", _params, socket) do
    case socket.assigns.selection do
      nil -> {:noreply, socket}
      range -> {:noreply, assign(socket, :clipboard, CodeomeBuffer.slice(socket.assigns.buffer, range))}
    end
  end

  def handle_event("cut_selection", _params, socket) do
    case socket.assigns.selection do
      nil ->
        {:noreply, socket}

      range ->
        clip = CodeomeBuffer.slice(socket.assigns.buffer, range)
        new_buffer = CodeomeBuffer.delete_range(socket.assigns.buffer, range)

        {:noreply,
         socket
         |> assign(:clipboard, clip)
         |> assign(selection: nil, sel_anchor: nil)
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("paste_clipboard", _params, socket) do
    case socket.assigns.clipboard do
      [] ->
        {:noreply, socket}

      clip ->
        at = paste_index(socket.assigns.selection, length(socket.assigns.buffer))
        new_buffer = CodeomeBuffer.insert_many(socket.assigns.buffer, at, clip)
        pasted = {at, at + length(clip) - 1}

        {:noreply,
         socket
         |> assign(selection: pasted, sel_anchor: at)
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("duplicate_selection", _params, socket) do
    case socket.assigns.selection do
      nil ->
        {:noreply, socket}

      {_lo, hi} = range ->
        clip = CodeomeBuffer.slice(socket.assigns.buffer, range)
        at = hi + 1
        new_buffer = CodeomeBuffer.insert_many(socket.assigns.buffer, at, clip)
        dup = {at, at + length(clip) - 1}

        {:noreply,
         socket
         |> assign(selection: dup, sel_anchor: at)
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("delete_selection", _params, socket) do
    case socket.assigns.selection do
      nil ->
        {:noreply, socket}

      range ->
        new_buffer = CodeomeBuffer.delete_range(socket.assigns.buffer, range)

        {:noreply,
         socket
         |> assign(selection: nil, sel_anchor: nil)
         |> commit_buffer_change(new_buffer)}
    end
  end
```

Add the private helper near `to_int/1`:

```elixir
  # Paste lands right after the selection; with no selection, at the end.
  defp paste_index(nil, len), do: len
  defp paste_index({_lo, hi}, _len), do: hi + 1
```

Add the alias at the top of the module (after `alias LeniesWeb.Disassembler`):

```elixir
  alias LeniesWeb.CodeomeBuffer
```

(If `CodeomeBuffer` is currently referenced by its full name elsewhere in the file, leaving those is fine — the alias just lets the new code use the short name.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS (existing + 5 new).

- [ ] **Step 7: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): clipboard copy/cut/paste/duplicate/delete"
```

---

## Task 7: EditorLive undo/redo wired through commit_buffer_change

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`
- Modify: `test/lenies_web/live/editor_live_test.exs`

Adds the `:history` assign, makes `commit_buffer_change/2` record the previous buffer, and adds `undo`/`redo` events. All existing mutations (`edit_delete`, `edit_reorder`, `edit_insert`, `submit_opcode_text`) must route through `commit_buffer_change/2` so they are undoable.

- [ ] **Step 1: Write the failing tests**

Append inside `test/lenies_web/live/editor_live_test.exs` (before the final `end`):

```elixir
  describe "undo / redo" do
    defp seeded_editor3(conn) do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
      view
    end

    defp names(html) do
      Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
      |> Enum.map(fn [_, n] -> n end)
    end

    test "undo reverts the last mutation; redo reapplies it", %{conn: conn} do
      view = seeded_editor3(conn)
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      html_after_delete = render_hook(view, "delete_selection", %{})
      assert names(html_after_delete) == ["PUSH1", "ADD"]

      html_undo = render_hook(view, "undo", %{})
      assert names(html_undo) == ["PUSH0", "PUSH1", "ADD"]

      html_redo = render_hook(view, "redo", %{})
      assert names(html_redo) == ["PUSH1", "ADD"]
    end

    test "undo with empty history is a no-op", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      html = render_hook(view, "undo", %{})
      # empty buffer stays empty, no crash
      assert names(html) == []
    end

    test "a new mutation after undo clears the redo stack", %{conn: conn} do
      view = seeded_editor3(conn)
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "delete_selection", %{})
      render_hook(view, "undo", %{})
      # new mutation: append an opcode
      render_hook(view, "submit_opcode_text", %{"opcodes" => "move"})
      html = render_hook(view, "redo", %{})
      # redo should do nothing (future cleared); MOVE still present
      assert names(html) == ["PUSH0", "PUSH1", "ADD", "MOVE"]
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: FAIL — no `undo`/`redo` handlers.

- [ ] **Step 3: Add the `:history` assign and alias**

Add alias near the others:

```elixir
  alias LeniesWeb.EditorHistory
```

In `mount/3`, add after `:clipboard`:

```elixir
      |> assign(:history, EditorHistory.new(100))
```

- [ ] **Step 4: Make `commit_buffer_change/2` record history**

Replace the thin version from Task 6:

```elixir
  defp commit_buffer_change(socket, new_buffer) do
    apply_buffer_change(socket, new_buffer)
  end
```

with:

```elixir
  defp commit_buffer_change(socket, new_buffer) do
    history = EditorHistory.record(socket.assigns.history, socket.assigns.buffer)

    socket
    |> assign(:history, history)
    |> apply_buffer_change(new_buffer)
  end
```

- [ ] **Step 5: Route existing mutations through commit_buffer_change**

In `edit_delete`, `edit_reorder`, and `edit_insert`, and the `{:ok, opcodes}` branch of `submit_opcode_text`, replace `apply_buffer_change(socket, new_buffer)` with `commit_buffer_change(socket, new_buffer)`. Concretely:

`edit_delete`:
```elixir
    {:noreply, commit_buffer_change(socket, new_buffer)}
```

`edit_reorder`:
```elixir
    {:noreply, commit_buffer_change(socket, new_buffer)}
```

`edit_insert` (the success branch):
```elixir
        new_buffer = LeniesWeb.CodeomeBuffer.insert(socket.assigns.buffer, index, opcode)
        {:noreply, commit_buffer_change(socket, new_buffer)}
```

`submit_opcode_text` (the `{:ok, opcodes}` branch):
```elixir
        {:noreply,
         socket
         |> commit_buffer_change(new_buffer)
         |> assign(text_input_value: "", text_input_error: nil)}
```

These also need to clear the selection (structural mutation). Since `commit_buffer_change/2` is shared with paste/duplicate (which set their own selection *after*), do NOT clear selection inside `commit_buffer_change/2`. Instead clear it in these specific handlers by piping `|> assign(selection: nil, sel_anchor: nil)` before the commit. For `edit_delete` for example:

```elixir
  def handle_event("edit_delete", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    new_buffer = LeniesWeb.CodeomeBuffer.delete(socket.assigns.buffer, index)

    {:noreply,
     socket
     |> assign(selection: nil, sel_anchor: nil)
     |> commit_buffer_change(new_buffer)}
  end
```

Apply the same `assign(selection: nil, sel_anchor: nil)` before `commit_buffer_change` in `edit_reorder`, `edit_insert` (success branch), and `submit_opcode_text` (`{:ok, opcodes}` branch).

- [ ] **Step 6: Add undo/redo handlers**

Add after `delete_selection`:

```elixir
  def handle_event("undo", _params, socket) do
    case EditorHistory.undo(socket.assigns.history, socket.assigns.buffer) do
      :none ->
        {:noreply, socket}

      {prev_buffer, history} ->
        {:noreply,
         socket
         |> assign(:history, history)
         |> assign(selection: nil, sel_anchor: nil)
         |> apply_buffer_change(prev_buffer)}
    end
  end

  def handle_event("redo", _params, socket) do
    case EditorHistory.redo(socket.assigns.history, socket.assigns.buffer) do
      :none ->
        {:noreply, socket}

      {next_buffer, history} ->
        {:noreply,
         socket
         |> assign(:history, history)
         |> assign(selection: nil, sel_anchor: nil)
         |> apply_buffer_change(next_buffer)}
    end
  end
```

Note: undo/redo call `apply_buffer_change/2` directly (NOT `commit_buffer_change/2`) so they don't re-record onto the history — the history movement is already handled by `EditorHistory.undo/redo`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS (existing + 3 new undo/redo tests).

- [ ] **Step 8: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): undo/redo via EditorHistory"
```

---

## Task 8: EditorLive snippet save form, section, insert/delete

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`
- Modify: `test/lenies_web/live/editor_live_test.exs`

Adds `:snippets` and `:show_snippet_form` assigns, the `open_snippet_form`/`cancel_snippet_form`/`submit_snippet`/`insert_snippet`/`delete_snippet` events, and a Snippets section in the palette pane.

- [ ] **Step 1: Write the failing tests**

Append inside `test/lenies_web/live/editor_live_test.exs` (before the final `end`). These rely on the live `Lenies.Snippets.Store`; isolate it with a temp file in a `setup` for this describe block:

```elixir
  describe "snippet library" do
    @snip_env :__test_user_snippets_file__

    setup do
      tmp = Path.join(System.tmp_dir!(), "lenies_snips_live_#{System.unique_integer([:positive])}.json")
      orig = Application.get_env(:lenies, @snip_env)
      Application.put_env(:lenies, @snip_env, tmp)
      if Process.whereis(Lenies.Snippets.Store), do: Agent.stop(Lenies.Snippets.Store)
      {:ok, _} = Lenies.Snippets.Store.start_link([])

      on_exit(fn ->
        if Process.whereis(Lenies.Snippets.Store) do
          try do
            Agent.stop(Lenies.Snippets.Store)
          catch
            :exit, _ -> :ok
          end
        end

        File.rm(tmp)
        if orig, do: Application.put_env(:lenies, @snip_env, orig), else: Application.delete_env(:lenies, @snip_env)
      end)

      :ok
    end

    defp names4(html) do
      Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
      |> Enum.map(fn [_, n] -> n end)
    end

    test "save selection as snippet, then insert it", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      render_hook(view, "select_block", %{"index" => 1, "shift" => true})

      html = render_hook(view, "submit_snippet", %{"snippet_name" => "Pair"})
      # snippet now listed in the palette snippets section
      assert html =~ "Pair"
      assert [%{name: "Pair", opcodes: [:push0, :push1]}] = Lenies.Snippets.Store.all()

      # insert it (no selection -> appends at end)
      render_hook(view, "clear_selection", %{})
      html2 = render_hook(view, "insert_snippet", %{"id" => "pair"})
      assert names4(html2) == ["PUSH0", "PUSH1", "ADD", "PUSH0", "PUSH1"]
    end

    test "delete a snippet removes it from the section", %{conn: conn} do
      Lenies.Snippets.Store.save(%{id: "loop", name: "Loop", opcodes: [:move, :eat]})
      {:ok, view, _} = live(conn, "/editor/new")
      assert render(view) =~ "Loop"
      html = render_hook(view, "delete_snippet", %{"id" => "loop"})
      refute html =~ "Loop"
    end

    test "submit_snippet with no selection is a no-op", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0"})
      render_hook(view, "submit_snippet", %{"snippet_name" => "X"})
      assert Lenies.Snippets.Store.all() == []
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: FAIL — no snippet handlers / section.

- [ ] **Step 3: Add assigns**

In `mount/3`, add after `:history`:

```elixir
      |> assign(:snippets, Lenies.Snippets.Store.all())
      |> assign(:show_snippet_form, false)
```

- [ ] **Step 4: Add snippet handlers**

Add after the `redo` handler:

```elixir
  def handle_event("open_snippet_form", _params, socket) do
    {:noreply, assign(socket, show_snippet_form: true)}
  end

  def handle_event("cancel_snippet_form", _params, socket) do
    {:noreply, assign(socket, show_snippet_form: false)}
  end

  def handle_event("submit_snippet", %{"snippet_name" => name}, socket) do
    with range when not is_nil(range) <- socket.assigns.selection,
         opcodes <- CodeomeBuffer.slice(socket.assigns.buffer, range),
         id <- Lenies.Slug.slugify(name),
         :ok <- Lenies.Snippets.Store.save(%{id: id, name: name, opcodes: opcodes}) do
      {:noreply,
       socket
       |> assign(:snippets, Lenies.Snippets.Store.all())
       |> assign(:show_snippet_form, false)}
    else
      _ -> {:noreply, assign(socket, :show_snippet_form, false)}
    end
  end

  def handle_event("insert_snippet", %{"id" => id}, socket) do
    case Lenies.Snippets.Store.get(id) do
      %{opcodes: ops} when ops != [] ->
        at = paste_index(socket.assigns.selection, length(socket.assigns.buffer))
        new_buffer = CodeomeBuffer.insert_many(socket.assigns.buffer, at, ops)
        inserted = {at, at + length(ops) - 1}

        {:noreply,
         socket
         |> assign(selection: inserted, sel_anchor: at)
         |> commit_buffer_change(new_buffer)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_snippet", %{"id" => id}, socket) do
    Lenies.Snippets.Store.delete(id)
    {:noreply, assign(socket, :snippets, Lenies.Snippets.Store.all())}
  end
```

- [ ] **Step 5: Render the Snippets section + save form**

In `render/1`, inside the `codeome-palette-pane` `<section>`, after the `codeome-palette` div (before the closing `</section>`), add the Snippets section:

```elixir
          <div class="codeome-snippets" id="codeome-snippets">
            <div class="codeome-snippets-title">Snippets</div>
            <%= if @show_snippet_form do %>
              <form phx-submit="submit_snippet" class="codeome-snippet-form">
                <input
                  type="text"
                  name="snippet_name"
                  required
                  minlength="1"
                  maxlength="40"
                  placeholder="snippet name"
                  autocomplete="off"
                  class="palette-text-input"
                />
                <button type="submit" class="palette-text-input-submit" title="Save snippet">✓</button>
                <button type="button" phx-click="cancel_snippet_form" class="palette-text-input-submit" title="Cancel">⨯</button>
              </form>
            <% end %>
            <%= if @snippets == [] do %>
              <p class="codeome-snippets-empty">no snippets — select blocks and press Save as snippet</p>
            <% else %>
              <div class="codeome-snippets-list">
                <%= for s <- @snippets do %>
                  <div class="codeome-snippet-row">
                    <button
                      type="button"
                      phx-click="insert_snippet"
                      phx-value-id={s.id}
                      class="codeome-snippet-insert"
                      title={"Insert (#{length(s.opcodes)} ops)"}
                    >
                      {s.name}
                    </button>
                    <button
                      type="button"
                      phx-click="delete_snippet"
                      phx-value-id={s.id}
                      class="codeome-snippet-del"
                      title="Delete snippet"
                    >
                      ⨯
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS (existing + 3 new snippet tests).

- [ ] **Step 7: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): snippet library save/insert/delete"
```

---

## Task 9: Toolbar (buttons) in the listing pane

**Files:**
- Modify: `lib/lenies_web/live/editor_live.ex`
- Modify: `test/lenies_web/live/editor_live_test.exs`

Adds a toolbar above the codeome listing with buttons for Copy/Cut/Paste/Duplicate/Delete/Undo/Redo/Save-as-snippet, each firing the events from Tasks 6-8, with disabled states.

- [ ] **Step 1: Write the failing tests**

Append inside `test/lenies_web/live/editor_live_test.exs` (before the final `end`):

```elixir
  describe "editor toolbar" do
    test "paste button is disabled with an empty clipboard", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      html = render(view)
      assert html =~ ~r/phx-click="paste_clipboard"[^>]*disabled/
    end

    test "copy button enables once a block is selected", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1"})
      html = render_hook(view, "select_block", %{"index" => 0, "shift" => false})
      # the copy button no longer carries the disabled attribute
      refute html =~ ~r/phx-click="copy_selection"[^>]*disabled/
    end

    test "clicking the Delete toolbar button removes the selection", %{conn: conn} do
      {:ok, view, _} = live(conn, "/editor/new")
      render_hook(view, "submit_opcode_text", %{"opcodes" => "push0 push1 add"})
      render_hook(view, "select_block", %{"index" => 0, "shift" => false})

      html =
        view
        |> element("button[phx-click='delete_selection']")
        |> render_click()

      names =
        Regex.scan(~r/codeome-block-name">([A-Z0-9_]+)</, html)
        |> Enum.map(fn [_, n] -> n end)

      assert names == ["PUSH1", "ADD"]
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: FAIL — toolbar buttons not present.

- [ ] **Step 3: Add toolbar helpers**

Add private helpers near `selected?/2`:

```elixir
  defp has_selection?(nil), do: false
  defp has_selection?({_lo, _hi}), do: true
```

- [ ] **Step 4: Render the toolbar**

In `render/1`, inside `codeome-listing-pane`, immediately before the `codeome-listing-pane-title` div, add:

```elixir
          <div class="codeome-toolbar">
            <button type="button" phx-click="copy_selection" disabled={!has_selection?(@selection)} class="codeome-tool-btn" title="Copy (Ctrl/Cmd+C)">Copy</button>
            <button type="button" phx-click="cut_selection" disabled={!has_selection?(@selection)} class="codeome-tool-btn" title="Cut (Ctrl/Cmd+X)">Cut</button>
            <button type="button" phx-click="paste_clipboard" disabled={@clipboard == []} class="codeome-tool-btn" title="Paste (Ctrl/Cmd+V)">Paste</button>
            <button type="button" phx-click="duplicate_selection" disabled={!has_selection?(@selection)} class="codeome-tool-btn" title="Duplicate (Ctrl/Cmd+D)">Duplicate</button>
            <button type="button" phx-click="delete_selection" disabled={!has_selection?(@selection)} class="codeome-tool-btn" title="Delete (Del)">Delete</button>
            <span class="codeome-toolbar-sep"></span>
            <button type="button" phx-click="undo" disabled={@history.past == []} class="codeome-tool-btn" title="Undo (Ctrl/Cmd+Z)">Undo</button>
            <button type="button" phx-click="redo" disabled={@history.future == []} class="codeome-tool-btn" title="Redo (Ctrl/Cmd+Shift+Z)">Redo</button>
            <span class="codeome-toolbar-sep"></span>
            <button type="button" phx-click="open_snippet_form" disabled={!has_selection?(@selection)} class="codeome-tool-btn" title="Save selection as snippet">Save as snippet</button>
          </div>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies_web/live/editor_live_test.exs`
Expected: PASS (existing + 3 new toolbar tests).

- [ ] **Step 6: Commit**

```bash
git add lib/lenies_web/live/editor_live.ex test/lenies_web/live/editor_live_test.exs
git commit -m "feat(editor): listing-pane toolbar"
```

---

## Task 10: EditorKeyboard JS hook + CSS + manual verification

**Files:**
- Create: `assets/js/hooks/editor_keyboard.js`
- Modify: `assets/js/app.js`
- Modify: `assets/css/app.css`
- Modify: `lib/lenies_web/live/editor_live.ex` (attach the hook to the editor root)

The hook attaches the `phx-hook="EditorKeyboard"` to a wrapper around the editor and: (a) on click of a `.codeome-block-editable` body (not the `≡` handle), pushes `select_block {index, shift}`; (b) on global keydown, pushes the matching command event — unless focus is in a text field. There are no unit tests for the hook (consistent with existing hooks); its server events are already covered.

- [ ] **Step 1: Create the hook**

Create `assets/js/hooks/editor_keyboard.js`:

```javascript
// EditorKeyboard hook: turns clicks and keyboard shortcuts in the codeome
// editor into LiveView events. Click/shift-click on a block body selects;
// global shortcuts drive clipboard/undo/redo/delete/duplicate. Shortcuts are
// suppressed while the user is typing in a text field so native editing works.

const isTextTarget = (el) =>
  !!el &&
  (el.tagName === "INPUT" ||
    el.tagName === "TEXTAREA" ||
    el.isContentEditable);

const EditorKeyboard = {
  mounted() {
    this.onClick = (e) => {
      // Ignore clicks that start on the drag handle (reorder, not select).
      if (e.target.closest(".codeome-drag-handle")) return;
      const block = e.target.closest(".codeome-block-editable");
      if (!block || !this.el.contains(block)) return;
      const idx = parseInt(block.dataset.idx, 10);
      if (Number.isNaN(idx)) return;
      this.pushEvent("select_block", { index: idx, shift: e.shiftKey === true });
    };

    this.onKeydown = (e) => {
      if (isTextTarget(e.target)) return;
      const mod = e.metaKey || e.ctrlKey;
      const key = e.key.toLowerCase();

      let event = null;
      if (mod && key === "c") event = "copy_selection";
      else if (mod && key === "x") event = "cut_selection";
      else if (mod && key === "v") event = "paste_clipboard";
      else if (mod && key === "d") event = "duplicate_selection";
      else if (mod && key === "z" && e.shiftKey) event = "redo";
      else if (mod && key === "z") event = "undo";
      else if (mod && key === "y") event = "redo";
      else if (key === "delete" || key === "backspace") event = "delete_selection";
      else if (key === "escape") event = "clear_selection";

      if (event) {
        e.preventDefault();
        this.pushEvent(event, {});
      }
    };

    this.el.addEventListener("click", this.onClick);
    document.addEventListener("keydown", this.onKeydown);
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick);
    if (this.onKeydown) document.removeEventListener("keydown", this.onKeydown);
    this.onClick = null;
    this.onKeydown = null;
  },
};

export default EditorKeyboard;
```

- [ ] **Step 2: Register the hook**

In `assets/js/app.js`, add the import after the other hook imports (line ~38):

```javascript
import EditorKeyboard from "./hooks/editor_keyboard"
```

And add it to the `Hooks` object (line ~40):

```javascript
const Hooks = {GridCanvas, ActionFeedback, CodeomeSortable, ConfirmAction, CodeomePalette, RememberManualState, ManualLinkInterceptor, EditorKeyboard, ...colocatedHooks}
```

- [ ] **Step 3: Attach the hook in the editor template**

In `lib/lenies_web/live/editor_live.ex` `render/1`, the root element already has `phx-hook="RememberManualState"`. A DOM node can only have one hook, so attach `EditorKeyboard` to the `editor-grid` wrapper instead. Change:

```elixir
      <div class={["editor-grid", @manual_collapsed? && "manual-collapsed"]}>
```

to:

```elixir
      <div
        id="editor-grid"
        phx-hook="EditorKeyboard"
        class={["editor-grid", @manual_collapsed? && "manual-collapsed"]}
      >
```

- [ ] **Step 4: Add CSS**

In `assets/css/app.css`, add near the other `.codeome-*` editor rules (after the `.codeome-listing-pane-title` rule around line 596):

```css
.lenies-dashboard .codeome-block-selected {
  outline: 1px solid #67e8f9;
  background: rgba(103, 232, 249, 0.12);
}

.lenies-dashboard .codeome-toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px;
  margin-bottom: 6px;
}

.lenies-dashboard .codeome-tool-btn {
  font-size: 10px;
  padding: 2px 6px;
  border: 1px solid rgba(148, 163, 184, 0.4);
  color: #cbd5e1;
}

.lenies-dashboard .codeome-tool-btn:hover:not(:disabled) {
  border-color: #67e8f9;
  color: #a5f3fc;
}

.lenies-dashboard .codeome-tool-btn:disabled {
  opacity: 0.35;
  cursor: default;
}

.lenies-dashboard .codeome-toolbar-sep {
  width: 1px;
  align-self: stretch;
  background: rgba(148, 163, 184, 0.25);
  margin: 0 2px;
}

.lenies-dashboard .codeome-snippets {
  margin-top: 8px;
  border-top: 1px solid rgba(148, 163, 184, 0.2);
  padding-top: 6px;
}

.lenies-dashboard .codeome-snippets-title {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: #94a3b8;
  margin-bottom: 4px;
}

.lenies-dashboard .codeome-snippets-empty {
  font-size: 10px;
  opacity: 0.6;
}

.lenies-dashboard .codeome-snippet-form {
  display: flex;
  gap: 4px;
  margin-bottom: 6px;
}

.lenies-dashboard .codeome-snippets-list {
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.lenies-dashboard .codeome-snippet-row {
  display: flex;
  align-items: center;
  gap: 4px;
}

.lenies-dashboard .codeome-snippet-insert {
  flex: 1;
  text-align: left;
  font-size: 11px;
  padding: 2px 6px;
  border: 1px solid rgba(167, 139, 250, 0.4);
  color: #ddd6fe;
}

.lenies-dashboard .codeome-snippet-insert:hover {
  border-color: #a78bfa;
  background: rgba(167, 139, 250, 0.12);
}

.lenies-dashboard .codeome-snippet-del {
  font-size: 11px;
  padding: 2px 6px;
  border: 1px solid rgba(148, 163, 184, 0.3);
  color: #94a3b8;
}

.lenies-dashboard .codeome-snippet-del:hover {
  border-color: #f87171;
  color: #fca5a5;
}
```

- [ ] **Step 5: Build assets and compile**

Run: `. ~/.asdf/asdf.sh && mix esbuild lenies && mix tailwind lenies && MIX_ENV=test mix compile --warnings-as-errors`
Expected: esbuild prints the bundle size; tailwind prints "Done"; compile is clean.

- [ ] **Step 6: Manual verification in the browser**

Open `http://localhost:4000/editor/new` (start a dev server with `. ~/.asdf/asdf.sh && mix phx.server` if none is running). Verify:
- Type `push0 push1 add move eat` in the append box; 5 blocks appear.
- Click a block → it highlights; shift-click another → contiguous range highlights.
- Ctrl/Cmd+C then Ctrl/Cmd+V → range duplicated after the selection.
- Select + Ctrl/Cmd+X → range removed; Ctrl/Cmd+V → pasted at end.
- Del removes the selection; Ctrl/Cmd+Z undoes; Ctrl/Cmd+Shift+Z redoes.
- Esc clears the selection.
- Typing in the append box: Ctrl+C copies the text (shortcut NOT hijacked).
- Select a range → "Save as snippet" → name it → it appears in the Snippets section; click it to insert; `⨯` deletes it.
- Toolbar buttons mirror all the above and disable correctly.

If a behavior is wrong, fix it before committing and note what you couldn't verify.

- [ ] **Step 7: Run the full suite**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test`
Expected: all tests pass (pre-existing flaky `Lenies.TelemetryTest` "ring buffer" may intermittently fail — re-run that file alone to confirm it is unrelated).

- [ ] **Step 8: Commit**

```bash
git add assets/js/hooks/editor_keyboard.js assets/js/app.js assets/css/app.css lib/lenies_web/live/editor_live.ex
git commit -m "feat(editor): EditorKeyboard hook, toolbar/snippet styles, selection highlight"
```

---

## Task 11: Documentation

**Files:**
- Modify: `docs/manual/` (the editor chapter) and/or `README.md`

- [ ] **Step 1: Find the editor documentation**

Run: `. ~/.asdf/asdf.sh && grep -rln "editor\|palette\|drag" docs/manual/ README.md`
Identify the chapter that documents the codeome editor (drag/dblclick/type interactions).

- [ ] **Step 2: Add a short subsection**

In the editor chapter, add a subsection describing the new capabilities (keep it concise, match the existing prose style):
- Selecting blocks: click selects one, shift-click extends a contiguous range, Esc clears.
- Clipboard: Copy/Cut/Paste/Duplicate/Delete via toolbar or Ctrl/Cmd+C/X/V/D and Del; clipboard is per editor session.
- Undo/Redo: Ctrl/Cmd+Z and Ctrl/Cmd+Shift+Z (or Ctrl+Y), or the toolbar buttons.
- Snippets: select a range, Save as snippet, reuse it from the Snippets section; snippets persist across sessions.

- [ ] **Step 3: Run the manual validation test (if the manual is tested)**

Run: `. ~/.asdf/asdf.sh && MIX_ENV=test mix test test/lenies/manual_test.exs`
Expected: PASS. (If you only edited prose within an existing chapter, the chapter count is unchanged and the test stays green.)

- [ ] **Step 4: Commit**

```bash
git add docs/ README.md
git commit -m "docs(editor): document selection, clipboard, undo/redo, snippets"
```

---

## Self-Review (completed during planning)

**Spec coverage:**
- Selection (range, click+shift) → Task 5. Clipboard session-only → Task 6 (`:clipboard` assign, no persistence). Paste-position rule → Task 6 `paste_index/2`. Duplicate → Task 6. Undo/redo + central commit → Tasks 6-7. Keyboard + input guard → Task 10. Toolbar + disabled states → Task 9. Snippet store (mirror CustomStore, test env key, `Code.ensure_loaded!`) → Task 4. Snippet save/insert/delete + section + refresh → Task 8. Slug extraction → Task 1. Selection highlight class → Task 5. Selection-cleared-after-structural-mutation → Task 7 (existing mutations) and Tasks 6-7 (cut/delete clear; paste/duplicate set). Edge cases (empty selection/clipboard/stacks, over-length allowed, missing file) → covered by handler guards (Tasks 6-8) and store (Task 4). Testing split → pure (Tasks 1-4), LiveView (Tasks 5-9), JS untested (Task 10).
- Deviation: `Lenies.Snippets` facade dropped (YAGNI) — documented in header.

**Type/name consistency:** `EditorHistory` struct fields `past`/`future`/`max` consistent across Tasks 3 and 7. `slice/2`, `delete_range/2`, `insert_many/3` signatures consistent between Task 2 and their callers (Tasks 6, 8). `:selection` is always `{lo, hi} | nil`; `paste_index/2` and `selected?/2` and `has_selection?/1` all match that shape. Event names (`select_block`, `clear_selection`, `copy_selection`, `cut_selection`, `paste_clipboard`, `duplicate_selection`, `delete_selection`, `undo`, `redo`, `open_snippet_form`, `cancel_snippet_form`, `submit_snippet`, `insert_snippet`, `delete_snippet`) match between the JS hook (Task 10), templates (Tasks 8-9), and handlers (Tasks 6-8).

**Placeholders:** none — every code step shows full code.
