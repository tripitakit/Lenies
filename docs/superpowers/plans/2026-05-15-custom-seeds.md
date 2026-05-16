# Custom Seeds + Blocks Palette (Phase D) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user create a codeome from a blank canvas via a Scratch-like blocks palette, save it as a named seed with an optional manual color, and spawn it into the world from the existing Spawn dropdown. Seeds persist to disk.

**Architecture:** New `Lenies.Seeds.CustomStore` Agent backed by `priv/user_seeds.json`. New ETS-backed override layer in `Lenies.SpeciesColor`. `DashboardLive` gains an `:editor_mode` assign so the inspector can open with a blank buffer. The inspector grows a Save form and a blocks-palette sub-panel below the codeome listing; SortableJS connects the two lists via shared group config so chips can be dragged from palette into the codeome.

**Tech Stack:** Elixir 1.19, Phoenix LiveView, ExUnit, Jason, ETS, SortableJS (already vendored), Tailwind v4.

**Spec:** `docs/superpowers/specs/2026-05-15-custom-seeds.md`

---

## Task 1: `SpeciesColor` override layer

**Files:**
- Modify: `lib/lenies/species_color.ex`
- Modify: `lib/lenies/application.ex`
- Modify: `test/lenies/species_color_test.exs`

Adds `set_override/2`, `clear_override/1`, `override/1` backed by a named ETS table created in `Lenies.Application.start/2`. `hex/1` consults the override before falling back to the hash-derived value.

- [ ] **Step 1: Write the failing tests**

Append to `test/lenies/species_color_test.exs` (inside the existing module, after the last describe block):

```elixir
  describe "color overrides" do
    setup do
      # The override table is created in Lenies.Application — make sure it
      # exists for these tests even when the app isn't fully started.
      case :ets.info(:species_color_overrides) do
        :undefined ->
          :ets.new(:species_color_overrides, [:set, :named_table, :public, read_concurrency: true])

        _ ->
          :ok
      end

      on_exit(fn ->
        try do
          :ets.delete_all_objects(:species_color_overrides)
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    test "set_override/2 then override/1 returns the hex" do
      SpeciesColor.set_override("hash-x", "#abcdef")
      assert SpeciesColor.override("hash-x") == "#abcdef"
    end

    test "override/1 returns nil when no override is set" do
      assert SpeciesColor.override("never-set") == nil
    end

    test "hex/1 returns the override when set" do
      SpeciesColor.set_override("hash-y", "#112233")
      assert SpeciesColor.hex("hash-y") == "#112233"
    end

    test "hex/1 falls back to hash-derived when no override" do
      derived = SpeciesColor.hex("hash-z")
      SpeciesColor.set_override("hash-z", "#ff0000")
      assert SpeciesColor.hex("hash-z") == "#ff0000"
      SpeciesColor.clear_override("hash-z")
      assert SpeciesColor.hex("hash-z") == derived
    end

    test "set_override/2 replaces an existing override for the same hash" do
      SpeciesColor.set_override("hash-w", "#aaaaaa")
      SpeciesColor.set_override("hash-w", "#bbbbbb")
      assert SpeciesColor.override("hash-w") == "#bbbbbb"
    end

    test "multiple hashes have independent overrides" do
      SpeciesColor.set_override("hash-a", "#111111")
      SpeciesColor.set_override("hash-b", "#222222")
      assert SpeciesColor.override("hash-a") == "#111111"
      assert SpeciesColor.override("hash-b") == "#222222"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies/species_color_test.exs
```

Expected: failures — `set_override/2`, `clear_override/1`, `override/1` are undefined.

- [ ] **Step 3: Extend `Lenies.SpeciesColor`**

Open `lib/lenies/species_color.ex`. Add three new public functions and adjust `hex/1`.

After the existing `byte_to_hex/1` function (and before the private helpers), add:

```elixir
  @doc """
  Register a hex color override for a species hash. Overrides survive sterilize
  but not app restart. The ETS table is created in `Lenies.Application.start/2`.
  """
  @spec set_override(binary(), String.t()) :: :ok
  def set_override(hash, hex) when is_binary(hash) and is_binary(hex) do
    if :ets.info(:species_color_overrides) != :undefined do
      :ets.insert(:species_color_overrides, {hash, hex})
    end

    :ok
  end

  @doc "Remove a hex color override for a species hash."
  @spec clear_override(binary()) :: :ok
  def clear_override(hash) when is_binary(hash) do
    if :ets.info(:species_color_overrides) != :undefined do
      :ets.delete(:species_color_overrides, hash)
    end

    :ok
  end

  @doc "Read the hex color override for a hash, or `nil` if none is set."
  @spec override(binary()) :: nil | String.t()
  def override(hash) when is_binary(hash) do
    case :ets.info(:species_color_overrides) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(:species_color_overrides, hash) do
          [{^hash, hex}] -> hex
          [] -> nil
        end
    end
  end
```

Replace the existing `hex/1` function with:

```elixir
  @doc "CSS hex color (#RRGGBB) for a species hash. Honors per-hash overrides."
  @spec hex(binary()) :: String.t()
  def hex(hash) when is_binary(hash) do
    case override(hash) do
      nil -> hash |> hue_byte() |> byte_to_hex()
      explicit when is_binary(explicit) -> explicit
    end
  end
```

- [ ] **Step 4: Create the ETS table in `Lenies.Application.start/2`**

Open `lib/lenies/application.ex`. At the very top of `start/2`, before the `children` list, add the table creation:

```elixir
  @impl true
  def start(_type, _args) do
    # Session-scoped color overrides; survives sterilize but not restart.
    if :ets.info(:species_color_overrides) == :undefined do
      :ets.new(:species_color_overrides, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])
    end

    children = [
      ...existing list, unchanged...
    ]

    ...
  end
```

Keep the existing children list unchanged; only the table creation is new.

- [ ] **Step 5: Run tests to verify they pass**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies/species_color_test.exs
```

Expected: 6 new tests pass, plus all existing SpeciesColor tests still pass.

- [ ] **Step 6: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green (modulo the known intermittent telemetry flake).

- [ ] **Step 7: Commit**

```bash
cd /home/patrick/projects/playground/Lenies
git add lib/lenies/species_color.ex \
        lib/lenies/application.ex \
        test/lenies/species_color_test.exs
git commit -m "feat: Lenies.SpeciesColor — ETS-backed per-hash override layer"
```

---

## Task 2: `Lenies.Seeds.CustomStore` Agent + JSON persistence

**Files:**
- Create: `lib/lenies/seeds/custom_store.ex`
- Create: `test/lenies/seeds/custom_store_test.exs`
- Modify: `lib/lenies/application.ex`

In-memory Agent that mirrors `priv/user_seeds.json`. API: `all/0`, `get/1`, `save/1`, `delete/1`.

- [ ] **Step 1: Write the failing tests**

`test/lenies/seeds/custom_store_test.exs`:

```elixir
defmodule Lenies.Seeds.CustomStoreTest do
  use ExUnit.Case, async: false

  alias Lenies.Seeds.CustomStore

  @tmp_file_env :__test_user_seeds_file__

  setup do
    tmp_path = Path.join(System.tmp_dir!(), "lenies_user_seeds_#{System.unique_integer([:positive])}.json")

    original_path = Application.get_env(:lenies, @tmp_file_env)
    Application.put_env(:lenies, @tmp_file_env, tmp_path)

    # Restart the store so it picks up the new path.
    if Process.whereis(CustomStore) do
      Agent.stop(CustomStore)
    end

    {:ok, _pid} = CustomStore.start_link([])

    on_exit(fn ->
      if Process.whereis(CustomStore) do
        try do
          Agent.stop(CustomStore)
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

  defp valid_seed(overrides \\ %{}) do
    Map.merge(
      %{
        id: "my-seed",
        name: "My Seed",
        color_hex: "#ff8800",
        energy_default: 10_000.0,
        opcodes: [:nop_1, :get_size, :push0, :store, :push0, :load, :allocate, :push0, :push1, :store, :nop_1]
      },
      overrides
    )
  end

  describe "save/1 and get/1" do
    test "round-trips a record" do
      :ok = CustomStore.save(valid_seed())
      assert %{name: "My Seed", color_hex: "#ff8800"} = CustomStore.get("my-seed")
    end

    test "overwrites an existing record with the same id" do
      :ok = CustomStore.save(valid_seed(%{name: "first"}))
      :ok = CustomStore.save(valid_seed(%{name: "second"}))
      assert %{name: "second"} = CustomStore.get("my-seed")
    end

    test "get/1 returns nil for unknown id" do
      assert CustomStore.get("does-not-exist") == nil
    end
  end

  describe "all/0" do
    test "returns an empty list initially" do
      assert CustomStore.all() == []
    end

    test "returns all saved records" do
      :ok = CustomStore.save(valid_seed(%{id: "a", name: "A"}))
      :ok = CustomStore.save(valid_seed(%{id: "b", name: "B"}))
      ids = CustomStore.all() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["a", "b"]
    end
  end

  describe "delete/1" do
    test "removes a record" do
      :ok = CustomStore.save(valid_seed())
      assert :ok = CustomStore.delete("my-seed")
      assert CustomStore.get("my-seed") == nil
    end

    test "is idempotent on a missing id" do
      assert :ok = CustomStore.delete("never-there")
    end
  end

  describe "validation" do
    test "rejects an empty name" do
      assert {:error, :invalid_name} = CustomStore.save(valid_seed(%{name: ""}))
    end

    test "rejects a whitespace-only name" do
      assert {:error, :invalid_name} = CustomStore.save(valid_seed(%{name: "   "}))
    end

    test "rejects a malformed color_hex" do
      assert {:error, :invalid_color} = CustomStore.save(valid_seed(%{color_hex: "red"}))
    end

    test "rejects an opcode that isn't in the whitelist" do
      assert {:error, :invalid_opcodes} =
               CustomStore.save(valid_seed(%{opcodes: [:nop_1, :nonexistent, :store]}))
    end
  end

  describe "persistence across restart" do
    test "save then restart-agent then get retains the record", %{tmp_path: tmp_path} do
      :ok = CustomStore.save(valid_seed())
      assert File.exists?(tmp_path)

      Agent.stop(CustomStore)
      {:ok, _pid} = CustomStore.start_link([])

      assert %{name: "My Seed"} = CustomStore.get("my-seed")
    end

    test "load survives a corrupt JSON file by starting empty", %{tmp_path: tmp_path} do
      File.write!(tmp_path, "{not valid json")

      Agent.stop(CustomStore)
      {:ok, _pid} = CustomStore.start_link([])

      assert CustomStore.all() == []
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies/seeds/custom_store_test.exs
```

Expected: module not found.

- [ ] **Step 3: Implement `Lenies.Seeds.CustomStore`**

`lib/lenies/seeds/custom_store.ex`:

```elixir
defmodule Lenies.Seeds.CustomStore do
  @moduledoc """
  Persistent registry of user-created seed Codeomes.

  Backed by a JSON file at `priv/user_seeds.json` (configurable via the
  `:__test_user_seeds_file__` app env key — used by tests). State lives in
  an `Agent` so reads (which happen on every dropdown render) are cheap.

  Validation rules (`save/1`):
  - `name` must be a non-empty string after trimming
  - `color_hex` must match `^#[0-9a-fA-F]{6}$`
  - every `opcode` must be in `Lenies.Codeome.Opcodes.all/0`
  """

  use Agent

  @type seed :: %{
          id: String.t(),
          name: String.t(),
          color_hex: String.t(),
          energy_default: float(),
          opcodes: [atom()]
        }

  @hex_re ~r/^#[0-9a-fA-F]{6}$/

  def start_link(_opts) do
    Agent.start_link(fn -> load_from_disk() end, name: __MODULE__)
  end

  @spec all() :: [seed()]
  def all do
    Agent.get(__MODULE__, & &1)
  end

  @spec get(String.t()) :: nil | seed()
  def get(id) when is_binary(id) do
    Agent.get(__MODULE__, fn seeds -> Enum.find(seeds, &(&1.id == id)) end)
  end

  @spec save(seed()) :: :ok | {:error, :invalid_name | :invalid_color | :invalid_opcodes}
  def save(%{} = seed) do
    with :ok <- validate_name(seed),
         :ok <- validate_color(seed),
         :ok <- validate_opcodes(seed) do
      Agent.update(__MODULE__, fn seeds ->
        new_seeds = [seed | Enum.reject(seeds, &(&1.id == seed.id))]
        write_to_disk(new_seeds)
        new_seeds
      end)
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    Agent.update(__MODULE__, fn seeds ->
      new_seeds = Enum.reject(seeds, &(&1.id == id))
      write_to_disk(new_seeds)
      new_seeds
    end)
  end

  # ----- validation -----

  defp validate_name(%{name: name}) when is_binary(name) do
    if String.trim(name) == "", do: {:error, :invalid_name}, else: :ok
  end

  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_color(%{color_hex: hex}) when is_binary(hex) do
    if Regex.match?(@hex_re, hex), do: :ok, else: {:error, :invalid_color}
  end

  defp validate_color(_), do: {:error, :invalid_color}

  defp validate_opcodes(%{opcodes: ops}) when is_list(ops) do
    whitelist = MapSet.new(Lenies.Codeome.Opcodes.all())

    if Enum.all?(ops, fn op -> is_atom(op) and MapSet.member?(whitelist, op) end) do
      :ok
    else
      {:error, :invalid_opcodes}
    end
  end

  defp validate_opcodes(_), do: {:error, :invalid_opcodes}

  # ----- file I/O -----

  defp file_path do
    case Application.get_env(:lenies, :__test_user_seeds_file__) do
      path when is_binary(path) -> path
      _ -> Path.join(:code.priv_dir(:lenies), "user_seeds.json")
    end
  end

  defp load_from_disk do
    path = file_path()

    case File.read(path) do
      {:ok, contents} -> parse_contents(contents, path)
      {:error, _} -> []
    end
  end

  defp parse_contents(contents, path) do
    case Jason.decode(contents) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.map(&decode_seed/1)
        |> Enum.filter(& &1)

      _ ->
        # Corrupt JSON. Rename for forensics and start fresh.
        backup = path <> ".bak"
        File.rename(path, backup)
        []
    end
  end

  defp decode_seed(%{} = m) do
    try do
      ops = Enum.map(m["opcodes"] || [], &String.to_existing_atom/1)

      %{
        id: m["id"],
        name: m["name"],
        color_hex: m["color_hex"],
        energy_default: m["energy_default"] || 10_000.0,
        opcodes: ops
      }
    rescue
      ArgumentError -> nil
    end
  end

  defp decode_seed(_), do: nil

  defp write_to_disk(seeds) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))

    json =
      seeds
      |> Enum.map(&encode_seed/1)
      |> Jason.encode!(pretty: true)

    tmp = path <> ".tmp"
    File.write!(tmp, json)
    File.rename!(tmp, path)
  end

  defp encode_seed(s) do
    %{
      "id" => s.id,
      "name" => s.name,
      "color_hex" => s.color_hex,
      "energy_default" => s.energy_default,
      "opcodes" => Enum.map(s.opcodes, &Atom.to_string/1)
    }
  end
end
```

- [ ] **Step 4: Add `CustomStore` to the supervision tree**

Open `lib/lenies/application.ex`. Add `Lenies.Seeds.CustomStore` to the `children` list, after `Lenies.Registry` and before `Lenies.LenieSupervisor`:

```elixir
    children = [
      LeniesWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:lenies, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Lenies.PubSub},
      Lenies.Registry,
      Lenies.Seeds.CustomStore,
      Lenies.LenieSupervisor,
      LeniesWeb.Endpoint
    ]
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies/seeds/custom_store_test.exs
```

Expected: all 13 new tests pass.

- [ ] **Step 6: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green. The Agent now starts as part of the supervision tree; existing tests should not be affected.

- [ ] **Step 7: Commit**

```bash
cd /home/patrick/projects/playground/Lenies
git add lib/lenies/seeds/custom_store.ex \
        lib/lenies/application.ex \
        test/lenies/seeds/custom_store_test.exs
git commit -m "feat: Lenies.Seeds.CustomStore — Agent-backed JSON store for user seeds"
```

---

## Task 3: DashboardLive `:editor_mode` flow

**Files:**
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Modify: `test/lenies_web/live/dashboard_live_test.exs`

Adds the `:editor_mode` assign + two `handle_info` clauses. The inspector is rendered whenever `@selected_hash` is non-nil OR `@editor_mode == :new_seed`. The inspector receives `editor_mode` as an assign so it can adapt its rendering (Task 4).

- [ ] **Step 1: Write the failing tests**

Append to `test/lenies_web/live/dashboard_live_test.exs`:

```elixir
  describe "editor_mode :new_seed flow" do
    test "open_codeome_editor info opens the inspector with empty selection", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      refute render(view) =~ ~s(id="species-inspector")

      send(view.pid, :open_codeome_editor)

      html = render(view)
      assert html =~ ~s(id="species-inspector")
    end

    test "editor_mode info nil closes the inspector when no species is selected", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      send(view.pid, :open_codeome_editor)
      assert render(view) =~ ~s(id="species-inspector")

      send(view.pid, {:editor_mode, nil})
      refute render(view) =~ ~s(id="species-inspector")
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: failures — `:open_codeome_editor` info goes to the catch-all and the assign is never set.

- [ ] **Step 3: Add the `:editor_mode` assign and handlers**

In `lib/lenies_web/live/dashboard_live.ex` `mount/3`, append one more assign at the end of the chain (after `:inspector_dirty`):

```elixir
      |> assign(:inspector_dirty, false)
      |> assign(:editor_mode, nil)
```

Just before any catch-all `handle_info(_msg, socket)` clause, add:

```elixir
  def handle_info(:open_codeome_editor, socket) do
    {:noreply, assign(socket, :editor_mode, :new_seed)}
  end

  def handle_info({:editor_mode, mode}, socket) when mode in [nil, :new_seed] do
    {:noreply, assign(socket, :editor_mode, mode)}
  end
```

- [ ] **Step 4: Make the inspector render conditional include `:editor_mode == :new_seed`**

Find the line in the template where the inspector is rendered conditionally. It currently looks like:

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

Replace with:

```heex
        <%= if @selected_hash || @editor_mode == :new_seed do %>
          <.live_component
            module={LeniesWeb.SpeciesInspectorComponent}
            id="species-inspector"
            selected_hash={@selected_hash}
            species_record={@selected_species_record}
            editor_mode={@editor_mode}
          />
        <% end %>
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: all dashboard tests pass, including the 2 new ones. NOTE: the inspector component now receives an `editor_mode` assign it doesn't yet handle — Phoenix will accept the extra assign via `update/2`'s catch-all clause, but the component's render template doesn't read it yet, so behavior is unchanged for the existing flow.

- [ ] **Step 6: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green (modulo known flake).

- [ ] **Step 7: Commit**

```bash
cd /home/patrick/projects/playground/Lenies
git add lib/lenies_web/live/dashboard_live.ex \
        test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat: DashboardLive :editor_mode :new_seed opens inspector with blank canvas"
```

---

## Task 4: Inspector `:new_seed` mode + auto-edit + Cancel/close flow

**Files:**
- Modify: `lib/lenies_web/live/species_inspector_component.ex`
- Modify: `test/lenies_web/live/species_inspector_component_test.exs`

Inspector adapts when `editor_mode == :new_seed`: header shows "New Seed", stats grid omitted, edit mode auto-engaged, buffer starts empty, Cancel button closes the inspector entirely by notifying the parent.

- [ ] **Step 1: Write the failing tests**

Append to `test/lenies_web/live/species_inspector_component_test.exs`:

```elixir
  describe "editor_mode :new_seed" do
    test "renders 'New Seed' header instead of a hash" do
      html =
        render_seeded(%{id: "test-inspector", selected_hash: nil, species_record: nil},
          editor_mode: :new_seed,
          edit_mode: true,
          buffer: [],
          validation: {:error, [{:too_short, [min: 5, got: 0]}]}
        )

      assert html =~ "New Seed"
      refute html =~ ~s(href="/species/)
    end

    test "omits the stats grid in :new_seed mode" do
      html =
        render_seeded(%{id: "test-inspector", selected_hash: nil, species_record: nil},
          editor_mode: :new_seed,
          edit_mode: true,
          buffer: [],
          validation: {:error, [{:too_short, [min: 5, got: 0]}]}
        )

      refute html =~ ~r/>\s*pop\.\s*</
      refute html =~ ~r/>\s*gen\.\s*</
    end

    test "does NOT show the Edit button (edit mode is auto-on)" do
      html =
        render_seeded(%{id: "test-inspector", selected_hash: nil, species_record: nil},
          editor_mode: :new_seed,
          edit_mode: true,
          buffer: [],
          validation: {:error, [{:too_short, [min: 5, got: 0]}]}
        )

      refute html =~ ~s(>Edit<)
      assert html =~ ~s(>Cancel<)
    end
  end
```

Update `render_seeded/2` so it accepts `nil` for `selected_hash` and `species_record` and tolerates the omission of those keys from the markup. The current helper hardcodes `Map.put_new(:cached_codeome_hash, base[:selected_hash])` — when `base[:selected_hash]` is `nil` this works fine because `cached_codeome_hash` is allowed to be nil.

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: failures — the component renders the hash header / stats grid unconditionally and crashes on `nil` `selected_hash`.

- [ ] **Step 3: Adapt `mount/1` and `update/2` for `:new_seed`**

In `lib/lenies_web/live/species_inspector_component.ex` `mount/1`, append `:editor_mode` to the assign chain:

```elixir
     |> assign(:show_spawn_form, false)
     |> assign(:editor_mode, nil)}
```

Add a new `update/2` clause BEFORE the existing first clause (the one matching `selected_hash` binary), so it matches when `editor_mode == :new_seed`:

```elixir
  @impl true
  def update(%{editor_mode: :new_seed} = assigns, socket) do
    cleared =
      socket
      |> assign(assigns)
      |> assign(:codeome_lines, [])
      |> assign(:fetch_status, :ok)
      |> assign(:cached_codeome_hash, nil)
      |> assign(:edit_mode, true)
      |> assign(:buffer, [])
      |> assign(:dirty, false)
      |> assign(:picker_open, nil)
      |> assign(:validation, LeniesWeb.CodeomeBuffer.validate([]))
      |> assign(:show_spawn_form, false)

    {:ok, cleared}
  end

  @impl true
  def update(%{selected_hash: hash} = assigns, socket)
      when is_binary(hash) and hash != "" do
    ...existing body unchanged...
  end
```

The catch-all `update(assigns, socket)` at the bottom stays.

- [ ] **Step 4: Override `cancel_edit` behavior in `:new_seed` mode**

Replace the existing `cancel_edit` handler with a version that branches on `editor_mode`:

```elixir
  def handle_event("cancel_edit", _params, socket) do
    socket =
      socket
      |> assign(:edit_mode, false)
      |> assign(:buffer, [])
      |> assign(:dirty, false)
      |> assign(:picker_open, nil)
      |> assign(:validation, {:ok, %{len: 0, non_nops: 0}})
      |> assign(:show_spawn_form, false)
      |> notify_parent_dirty(false)

    if socket.assigns[:editor_mode] == :new_seed do
      send(self(), {:editor_mode, nil})
      {:noreply, assign(socket, :editor_mode, nil)}
    else
      {:noreply, socket}
    end
  end
```

- [ ] **Step 5: Adapt the template — header + stats grid in `:new_seed` mode**

Find the `<header>` block. Wrap the current swatch + hash + ↗ link in an `if @editor_mode != :new_seed do` branch. Add a `:new_seed` alternative:

```heex
      <header class="flex items-center gap-2">
        <%= if @editor_mode == :new_seed do %>
          <span class="inline-block w-3 h-3 shrink-0 bg-slate-500"></span>
          <h2 class="text-xs flex-1 truncate">New Seed</h2>
        <% else %>
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
        <% end %>

        <%= if @editor_mode == :new_seed do %>
          <button
            type="button"
            phx-click="cancel_edit"
            phx-target={@myself}
            class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
            title="Close editor"
          >
            ×
          </button>
        <% else %>
          <button
            id={"inspector-close-#{@selected_hash}"}
            phx-hook="ConfirmAction"
            data-confirm="Discard codeome edits?"
            data-confirm-when="[data-inspector-dirty='true']"
            phx-click="select_species"
            phx-value-hash={@selected_hash}
            class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
          >
            ×
          </button>
        <% end %>
      </header>
```

Find the toolbar `<div class="flex items-center gap-2 text-[10px]">` block. Hide the Edit button entirely in `:new_seed` mode (it's auto-on so the choice is irrelevant):

```heex
      <div class="flex items-center gap-2 text-[10px]">
        <%= if @editor_mode != :new_seed and not @edit_mode do %>
          <button
            type="button"
            phx-click="enter_edit"
            phx-target={@myself}
            class="px-2 py-0.5 border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40"
          >
            Edit
          </button>
        <% end %>

        <%= if @edit_mode do %>
          <button
            id={"inspector-cancel-#{@selected_hash || "new_seed"}"}
            type="button"
            phx-hook="ConfirmAction"
            data-confirm="Discard codeome edits?"
            data-confirm-when="[data-inspector-dirty='true']"
            phx-click="cancel_edit"
            phx-target={@myself}
            class="px-2 py-0.5 border border-slate-500 hover:bg-slate-700"
          >
            Cancel
          </button>
        <% end %>

        ...rest of toolbar (dirty indicator, spawn button) unchanged...
      </div>
```

Find the stats grid `<div class="grid grid-cols-3 gap-2 text-[11px]">`. Wrap it in a conditional so it doesn't render in `:new_seed`:

```heex
      <%= if @editor_mode != :new_seed do %>
        <div class="grid grid-cols-3 gap-2 text-[11px]">
          ...existing stats content...
        </div>
      <% end %>
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: all tests pass including the 3 new `:new_seed` cases.

- [ ] **Step 7: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green.

- [ ] **Step 8: Commit**

```bash
cd /home/patrick/projects/playground/Lenies
git add lib/lenies_web/live/species_inspector_component.ex \
        test/lenies_web/live/species_inspector_component_test.exs
git commit -m "feat: inspector :new_seed mode — blank canvas, auto-edit, cancel closes"
```

---

## Task 5: Inspector Save form + submit_save_seed handler

**Files:**
- Modify: `lib/lenies_web/live/species_inspector_component.ex`
- Modify: `test/lenies_web/live/species_inspector_component_test.exs`

The inspector gains a Save button (only in `:new_seed` mode) and a form (name + color + energy default). Submit validates, calls `CustomStore.save/1`, sends `{:editor_mode, nil}` to parent on success.

- [ ] **Step 1: Write the failing tests**

Append to `test/lenies_web/live/species_inspector_component_test.exs`:

```elixir
  describe "save flow" do
    setup do
      tmp_path =
        Path.join(System.tmp_dir!(), "lenies_save_test_#{System.unique_integer([:positive])}.json")

      Application.put_env(:lenies, :__test_user_seeds_file__, tmp_path)

      if Process.whereis(Lenies.Seeds.CustomStore) do
        Agent.stop(Lenies.Seeds.CustomStore)
      end

      {:ok, _} = Lenies.Seeds.CustomStore.start_link([])

      on_exit(fn ->
        File.rm(tmp_path)
        Application.delete_env(:lenies, :__test_user_seeds_file__)
      end)

      :ok
    end

    test "Save button visible only in :new_seed edit mode" do
      html_normal =
        render_seeded(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}}
        )

      refute html_normal =~ ~s(>Save<)

      html_new =
        render_seeded(%{id: "test-inspector", selected_hash: nil, species_record: nil},
          editor_mode: :new_seed,
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}}
        )

      assert html_new =~ ~s(>Save<)
    end

    test "Save form hidden by default and opens on show_save_form: true" do
      html_closed =
        render_seeded(%{id: "test-inspector", selected_hash: nil, species_record: nil},
          editor_mode: :new_seed,
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}}
        )

      refute html_closed =~ ~s(name="seed_name")

      html_open =
        render_seeded(%{id: "test-inspector", selected_hash: nil, species_record: nil},
          editor_mode: :new_seed,
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}},
          show_save_form: true
        )

      assert html_open =~ ~s(name="seed_name")
      assert html_open =~ ~s(name="color_hex")
      assert html_open =~ ~s(name="energy_default")
    end

    test "submit_save_seed creates a custom seed" do
      buffer = [
        :nop_1,
        :get_size,
        :push0,
        :store,
        :push0,
        :load,
        :allocate,
        :push0,
        :push1,
        :store,
        :nop_1
      ]

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          myself: %Phoenix.LiveComponent.CID{cid: 1},
          buffer: buffer,
          validation: {:ok, %{len: length(buffer), non_nops: 9}},
          editor_mode: :new_seed,
          show_save_form: true,
          selected_hash: nil
        }
      }

      {:noreply, _} =
        LeniesWeb.SpeciesInspectorComponent.handle_event(
          "submit_save_seed",
          %{
            "seed_name" => "My Test Seed",
            "color_hex" => "#abcdef",
            "energy_default" => "5000"
          },
          socket
        )

      saved = Lenies.Seeds.CustomStore.get("my-test-seed")
      assert saved.name == "My Test Seed"
      assert saved.color_hex == "#abcdef"
      assert saved.energy_default == 5000.0
      assert saved.opcodes == buffer
    end
  end
```

Update `render_seeded/2` to also accept `:show_save_form` via `Map.put_new(:show_save_form, false)`.

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: failures — no Save button, no form, no `submit_save_seed` handler.

- [ ] **Step 3: Add the `:show_save_form` assign and the slug helper**

In `lib/lenies_web/live/species_inspector_component.ex` `mount/1`, append:

```elixir
     |> assign(:editor_mode, nil)
     |> assign(:show_save_form, false)}
```

Add the slug helper at the bottom of the module (near `parse_clamped/4`):

```elixir
  defp slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
```

- [ ] **Step 4: Add the save-form handlers**

After the spawn handlers (after `submit_spawn`), add:

```elixir
  def handle_event("open_save_form", _params, socket) do
    {:noreply, assign(socket, :show_save_form, true)}
  end

  def handle_event("cancel_save_form", _params, socket) do
    {:noreply, assign(socket, :show_save_form, false)}
  end

  def handle_event(
        "submit_save_seed",
        %{
          "seed_name" => name,
          "color_hex" => color,
          "energy_default" => energy_str
        },
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
            send(self(), {:editor_mode, nil})

            {:noreply,
             socket
             |> assign(:editor_mode, nil)
             |> assign(:show_save_form, false)
             |> assign(:edit_mode, false)
             |> assign(:buffer, [])
             |> assign(:dirty, false)
             |> notify_parent_dirty(false)}

          {:error, _reason} ->
            {:noreply, socket}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end
```

- [ ] **Step 5: Render the Save button in the toolbar**

Find the toolbar `<div class="flex items-center gap-2 text-[10px]">`. After the Spawn button (the existing `<%= if @edit_mode do %>` block with the Spawn button), add a Save button visible only in `:new_seed`:

```heex
        <%= if @editor_mode == :new_seed and @edit_mode do %>
          <button
            type="button"
            phx-click="open_save_form"
            phx-target={@myself}
            disabled={!match?({:ok, _}, @validation)}
            class="px-2 py-0.5 border border-violet-500/60 text-violet-200 hover:bg-violet-900/40 disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Save
          </button>
        <% end %>
```

- [ ] **Step 6: Render the Save form**

Below the spawn-form block (which is conditional on `@edit_mode and @show_spawn_form`), add a parallel block for the save form:

```heex
      <%= if @edit_mode and @show_save_form do %>
        <form
          phx-submit="submit_save_seed"
          phx-target={@myself}
          class="flex flex-col gap-1.5 border border-violet-500/30 p-2 text-[11px]"
        >
          <label class="flex items-center gap-2">
            <span class="opacity-70 w-14">name</span>
            <input
              type="text"
              name="seed_name"
              required
              minlength="1"
              maxlength="40"
              placeholder="my replicator v1"
              class="flex-1 text-xs"
            />
          </label>
          <label class="flex items-center gap-2">
            <span class="opacity-70 w-14">color</span>
            <input
              type="color"
              name="color_hex"
              value={suggested_color(@buffer)}
              class="w-12 h-6 cursor-pointer border border-violet-500/30"
            />
          </label>
          <label class="flex items-center gap-2">
            <span class="opacity-70 w-14">energy</span>
            <input
              type="number"
              name="energy_default"
              value="10000"
              min="1"
              max="1000000"
              class="w-24 text-xs"
            />
          </label>
          <div class="flex gap-1 justify-end">
            <button
              type="button"
              phx-click="cancel_save_form"
              phx-target={@myself}
              class="px-2 py-0.5 border border-slate-500 hover:bg-slate-700"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-2 py-0.5 border border-violet-500/60 text-violet-200 hover:bg-violet-900/40"
            >
              Save
            </button>
          </div>
        </form>
      <% end %>
```

Add the `suggested_color/1` private helper at the bottom of the module:

```elixir
  defp suggested_color([]), do: "#888888"

  defp suggested_color(buffer) when is_list(buffer) do
    buffer
    |> Lenies.Codeome.from_list()
    |> Lenies.Codeome.hash()
    |> Lenies.SpeciesColor.hex()
  end
```

- [ ] **Step 7: Run targeted tests**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: all new save-flow tests pass.

- [ ] **Step 8: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green.

- [ ] **Step 9: Commit**

```bash
cd /home/patrick/projects/playground/Lenies
git add lib/lenies_web/live/species_inspector_component.ex \
        test/lenies_web/live/species_inspector_component_test.exs
git commit -m "feat: inspector save form — persist custom seed via CustomStore"
```

---

## Task 6: Controls panel — entry point + custom-seed catalog + spawn-from-custom

**Files:**
- Modify: `lib/lenies_web/live/controls_panel_component.ex`
- Modify: `test/lenies_web/live/dashboard_live_test.exs`

The controls panel gets the "+ New Seed" button, a manage drawer for custom seeds with delete, and the spawn handler branches on `"custom:"` prefix to spawn from `CustomStore`.

- [ ] **Step 1: Write the failing tests**

Append to `test/lenies_web/live/dashboard_live_test.exs`:

```elixir
  describe "controls panel — new seed entry point" do
    test "renders the + New Seed button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "+ New Seed"
    end

    test "clicking + New Seed sends :open_codeome_editor to dashboard", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      view
      |> element("button", "+ New Seed")
      |> render_click()

      assert render(view) =~ ~s(id="species-inspector")
    end
  end

  describe "controls panel — custom seed catalog" do
    setup do
      tmp_path =
        Path.join(System.tmp_dir!(), "lenies_catalog_#{System.unique_integer([:positive])}.json")

      Application.put_env(:lenies, :__test_user_seeds_file__, tmp_path)

      if Process.whereis(Lenies.Seeds.CustomStore) do
        Agent.stop(Lenies.Seeds.CustomStore)
      end

      {:ok, _} = Lenies.Seeds.CustomStore.start_link([])

      on_exit(fn ->
        File.rm(tmp_path)
        Application.delete_env(:lenies, :__test_user_seeds_file__)
      end)

      :ok
    end

    test "custom seeds appear in the dropdown with a star prefix", %{conn: conn} do
      :ok =
        Lenies.Seeds.CustomStore.save(%{
          id: "my-test",
          name: "My Test",
          color_hex: "#abcdef",
          energy_default: 7000.0,
          opcodes: [:nop_1, :nop_1, :get_size, :push0, :store, :nop_1, :nop_1, :nop_1, :nop_1, :nop_1, :nop_1]
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "★ My Test"
      assert html =~ ~s(value="custom:my-test")
    end

    test "spawning a custom seed grows the population AND sets the color override", %{conn: conn} do
      buffer = [
        :nop_1,
        :get_size,
        :push0,
        :store,
        :push0,
        :load,
        :allocate,
        :push0,
        :push1,
        :store,
        :nop_1
      ]

      :ok =
        Lenies.Seeds.CustomStore.save(%{
          id: "spawn-test",
          name: "Spawn Test",
          color_hex: "#deadbe",
          energy_default: 3000.0,
          opcodes: buffer
        })

      {:ok, view, _} = live(conn, "/")

      pop_before = :ets.info(:lenies, :size) || 0

      view
      |> form("form[phx-submit='spawn_seed']", %{seed_id: "custom:spawn-test", count: "2"})
      |> render_submit()

      Process.sleep(100)

      pop_after = :ets.info(:lenies, :size) || 0
      assert pop_after >= pop_before + 2

      # The color override is keyed on the codeome hash
      hash = buffer |> Lenies.Codeome.from_list() |> Lenies.Codeome.hash()
      assert Lenies.SpeciesColor.override(hash) == "#deadbe"
    end

    test "deleting a custom seed removes it from the dropdown", %{conn: conn} do
      :ok =
        Lenies.Seeds.CustomStore.save(%{
          id: "delete-me",
          name: "Delete Me",
          color_hex: "#abcdef",
          energy_default: 1000.0,
          opcodes: [:nop_1, :nop_1, :get_size, :push0, :store, :nop_1, :nop_1, :nop_1, :nop_1, :nop_1, :nop_1]
        })

      {:ok, view, _} = live(conn, "/")
      assert render(view) =~ "★ Delete Me"

      view
      |> element("button", "Manage")
      |> render_click()

      view
      |> element("button[phx-value-id='delete-me']")
      |> render_click()

      refute render(view) =~ "★ Delete Me"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: failures — no `+ New Seed` button, no `★` in dropdown, no `Manage` button.

- [ ] **Step 3: Add the `:show_custom_manage` assign + handlers**

In `lib/lenies_web/live/controls_panel_component.ex` `mount/1`, add `:show_custom_manage` to the assign chain (after the existing assigns):

```elixir
  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:sterilize_confirming, false)
     |> assign(:paused?, false)
     |> assign(:snapshot_status, nil)
     |> assign(:show_custom_manage, false)}
  end
```

After the existing event handlers, add:

```elixir
  def handle_event("open_codeome_editor", _params, socket) do
    send(self(), :open_codeome_editor)
    {:noreply, socket}
  end

  def handle_event("toggle_custom_manage", _params, socket) do
    {:noreply, assign(socket, :show_custom_manage, !socket.assigns.show_custom_manage)}
  end

  def handle_event("delete_custom_seed", %{"id" => id}, socket) do
    :ok = Lenies.Seeds.CustomStore.delete(id)
    {:noreply, socket}
  end
```

Modify the existing `spawn_seed` handler to branch on the `"custom:"` prefix. Replace the entire handler with:

```elixir
  def handle_event("spawn_seed", %{"seed_id" => "custom:" <> id, "count" => count_str}, socket) do
    case Lenies.Seeds.CustomStore.get(id) do
      %{} = seed ->
        codeome = Lenies.Codeome.from_list(seed.opcodes)
        hash = Lenies.Codeome.hash(codeome)
        Lenies.SpeciesColor.set_override(hash, seed.color_hex)

        count = String.to_integer(count_str) |> max(1) |> min(50)
        dirs = [:n, :s, :e, :w]

        for _ <- 1..count do
          Lenies.World.spawn_lenie(codeome,
            energy: seed.energy_default,
            dir: Enum.random(dirs)
          )
        end

      nil ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_event("spawn_seed", %{"seed_id" => seed_id_str, "count" => count_str}, socket) do
    seed_id = String.to_existing_atom(seed_id_str)
    count = String.to_integer(count_str) |> max(1) |> min(50)

    case Lenies.Seeds.get(seed_id) do
      %{codeome: codeome, default_options: opts} ->
        energy = Map.get(opts, :energy, 500.0)
        dirs = [:n, :s, :e, :w]

        for _ <- 1..count do
          Lenies.World.spawn_lenie(codeome, energy: energy, dir: Enum.random(dirs))
        end

      nil ->
        :ok
    end

    {:noreply, socket}
  end
```

The two clauses pattern-match on whether the `seed_id` starts with `"custom:"` (the first clause) or not (the second clause). The first clause is the new behavior; the second is the existing seed-spawn flow unchanged.

- [ ] **Step 4: Modify the template — add the + New Seed button**

Find the seed form (the `<form phx-submit="spawn_seed"...>`). Immediately ABOVE it, add:

```heex
        <div class="flex items-center gap-2 text-xs">
          <button
            type="button"
            phx-click="open_codeome_editor"
            phx-target={@myself}
            class="px-2 py-0.5 border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40"
          >
            + New Seed
          </button>

          <button
            type="button"
            phx-click="toggle_custom_manage"
            phx-target={@myself}
            class="px-2 py-0.5 border border-cyan-500/30 hover:bg-cyan-500/10"
          >
            Manage
          </button>
        </div>
```

- [ ] **Step 5: Modify the seed dropdown to include custom seeds**

Find the `<select name="seed_id">` block. Replace its body with:

```heex
            <select name="seed_id">
              <%= for s <- Lenies.Seeds.all() do %>
                <option value={Atom.to_string(s.id)}>{s.name}</option>
              <% end %>
              <%= for s <- Lenies.Seeds.CustomStore.all() do %>
                <option value={"custom:#{s.id}"}>★ {s.name}</option>
              <% end %>
            </select>
```

- [ ] **Step 6: Add the manage drawer**

Below the seed form (after the `</form>` tag for spawn_seed), add:

```heex
        <%= if @show_custom_manage do %>
          <div class="text-[10px] border border-cyan-500/20 p-2 mt-1 flex flex-col gap-1">
            <%= for s <- Lenies.Seeds.CustomStore.all() do %>
              <div class="flex items-center gap-2">
                <span class="inline-block w-2 h-2" style={"background:#{s.color_hex}"}></span>
                <span class="flex-1 truncate">{s.name}</span>
                <button
                  type="button"
                  phx-click="delete_custom_seed"
                  phx-value-id={s.id}
                  phx-target={@myself}
                  class="px-1 hover:text-rose-300"
                  title="Delete"
                >
                  ⨯
                </button>
              </div>
            <% end %>
            <%= if Lenies.Seeds.CustomStore.all() == [] do %>
              <div class="opacity-50">No custom seeds yet.</div>
            <% end %>
          </div>
        <% end %>
```

- [ ] **Step 7: Run targeted tests**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: all new tests pass.

- [ ] **Step 8: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green.

- [ ] **Step 9: Commit**

```bash
cd /home/patrick/projects/playground/Lenies
git add lib/lenies_web/live/controls_panel_component.ex \
        test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat: controls panel — +New Seed entry, custom catalog, spawn-from-custom"
```

---

## Task 7: Blocks palette + cross-list drag-and-drop

**Files:**
- Create: `assets/js/hooks/codeome_palette.js`
- Modify: `assets/js/app.js`
- Modify: `assets/js/hooks/codeome_sortable.js`
- Modify: `lib/lenies_web/live/species_inspector_component.ex`
- Modify: `assets/css/app.css`
- Modify: `test/lenies_web/live/species_inspector_component_test.exs`

The palette renders below the codeome listing in edit mode, sized to fit all opcodes without scroll. SortableJS connects the two lists via shared group config; drop from palette fires `edit_insert`.

- [ ] **Step 1: Write the failing test**

Append to `test/lenies_web/live/species_inspector_component_test.exs`:

```elixir
  describe "blocks palette" do
    test "renders the palette in edit mode" do
      html =
        render_seeded(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}}
        )

      assert html =~ ~s(id="palette-grid")
      assert html =~ ~s(phx-hook="CodeomePalette")
      # Spot-check a few opcodes from different categories
      assert html =~ ~s(data-opcode="push0")
      assert html =~ ~s(data-opcode="divide")
      assert html =~ ~s(data-opcode="sense_front")
    end

    test "does NOT render the palette in read mode" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      refute html =~ ~s(id="palette-grid")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: failures — no palette-grid id, no CodeomePalette hook.

- [ ] **Step 3: Create the `CodeomePalette` JS hook**

`assets/js/hooks/codeome_palette.js`:

```javascript
// CodeomePalette hook: enables drag of opcode chips from the palette into
// the codeome listing in the SpeciesInspectorComponent's edit mode. Uses
// SortableJS with `pull: "clone"` so the source palette is unaffected by
// the drag. Drops are received by the CodeomeSortable hook on the
// codeome listing, which fires `edit_insert` via pushEventTo.

import Sortable from "../../vendor/sortable.js";

const CodeomePalette = {
  mounted() {
    this.sortable = Sortable.create(this.el, {
      group: { name: "codeome", pull: "clone", put: false },
      draggable: ".palette-chip",
      sort: false,
      animation: 120,
    });
  },

  destroyed() {
    if (this.sortable) {
      this.sortable.destroy();
      this.sortable = null;
    }
  },
};

export default CodeomePalette;
```

- [ ] **Step 4: Register the hook in `app.js`**

In `assets/js/app.js`, find the existing import block:

```javascript
import GridCanvas from "./hooks/grid_canvas"
import ActionFeedback from "./hooks/action_feedback"
import CodeomeSortable from "./hooks/codeome_sortable"
import ConfirmAction from "./hooks/confirm_action"

const Hooks = {GridCanvas, ActionFeedback, CodeomeSortable, ConfirmAction, ...colocatedHooks}
```

Add the new import and registration:

```javascript
import GridCanvas from "./hooks/grid_canvas"
import ActionFeedback from "./hooks/action_feedback"
import CodeomeSortable from "./hooks/codeome_sortable"
import ConfirmAction from "./hooks/confirm_action"
import CodeomePalette from "./hooks/codeome_palette"

const Hooks = {GridCanvas, ActionFeedback, CodeomeSortable, ConfirmAction, CodeomePalette, ...colocatedHooks}
```

- [ ] **Step 5: Extend `CodeomeSortable` to handle cross-list drops**

Open `assets/js/hooks/codeome_sortable.js`. Find the `Sortable.create(this.el, { ... })` config and add `group` + `onAdd`:

```javascript
    this.sortable = Sortable.create(this.el, {
      animation: 120,
      handle: ".codeome-drag-handle",
      ghostClass: "codeome-block-ghost",
      draggable: ".codeome-block-editable",
      group: { name: "codeome", pull: true, put: true },
      onEnd: (evt) => {
        // Intra-list reorder only — cross-list drops are handled by onAdd.
        if (
          evt.from === evt.to &&
          typeof evt.oldDraggableIndex === "number" &&
          typeof evt.newDraggableIndex === "number" &&
          evt.oldDraggableIndex !== evt.newDraggableIndex
        ) {
          this.pushEventTo(this.el, "edit_reorder", {
            from: evt.oldDraggableIndex,
            to: evt.newDraggableIndex,
          });
        }
      },
      onAdd: (evt) => {
        // Block dropped from palette — extract opcode and request insert.
        const opcode = evt.item?.dataset?.opcode;

        if (opcode && typeof evt.newDraggableIndex === "number") {
          this.pushEventTo(this.el, "edit_insert", {
            index: evt.newDraggableIndex,
            opcode: opcode,
          });
        }

        // Remove the cloned chip; the server will re-render the listing.
        evt.item.remove();
      },
    });
```

The key changes are the new `group: { name: "codeome", pull: true, put: true }` config and the new `onAdd` callback. The existing `onEnd` is gated on `evt.from === evt.to` so intra-list reorder is unchanged.

- [ ] **Step 6: Add the palette template to the inspector**

Open `lib/lenies_web/live/species_inspector_component.ex`. Find the codeome listing scroll container (`<div class="flex-1 min-h-0 overflow-auto">`). AFTER its closing `</div>` and BEFORE any subsequent block (such as the spawn-form / save-form blocks), add the palette block:

```heex
      <%= if @edit_mode do %>
        <div
          class="codeome-palette"
          id="palette-grid"
          phx-hook="CodeomePalette"
        >
          <%= for {category, ops} <- grouped_opcodes() do %>
            <div class="palette-category">
              <div class="palette-category-label">{category}</div>
              <div class="palette-category-chips">
                <%= for op <- ops do %>
                  <div
                    class={"palette-chip op op-" <> Atom.to_string(Disassembler.opcode_class(op))}
                    data-opcode={Atom.to_string(op)}
                  >
                    {Atom.to_string(op) |> String.upcase()}
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
```

The palette is positioned BELOW the codeome listing scroll container. The codeome listing has `flex-1` and `overflow-auto`, so it shrinks to make room for the palette while still allowing internal scroll.

- [ ] **Step 7: Add CSS for the palette**

Append to `assets/css/app.css` (at the end, after the existing `.codeome-block-ghost` rule from Phase C2):

```css
.lenies-dashboard .codeome-palette {
  flex-shrink: 0;
  border-top: 1px solid rgba(34, 211, 238, 0.2);
  padding-top: 6px;
  display: flex;
  flex-direction: column;
  gap: 4px;
  font-size: 9px;
}

.lenies-dashboard .palette-category-label {
  opacity: 0.55;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  font-size: 9px;
  margin-bottom: 1px;
}

.lenies-dashboard .palette-category-chips {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 2px;
}

.lenies-dashboard .palette-chip {
  padding: 1px 4px;
  border: 1px solid currentColor;
  background: rgba(2, 6, 23, 0.6);
  font-family: ui-monospace, "JetBrains Mono", "Fira Code", monospace;
  font-size: 9px;
  letter-spacing: 0.04em;
  cursor: grab;
  text-align: center;
  user-select: none;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.lenies-dashboard .palette-chip:hover {
  background: rgba(34, 211, 238, 0.15);
}

.lenies-dashboard .palette-chip.sortable-chosen {
  cursor: grabbing;
}
```

The `grid-template-columns: repeat(3, 1fr)` gives 3 chips per row; with ~30 opcodes across 10 categories (average ~3 chips per category), most categories fit in one row and total height is bounded around 240px.

- [ ] **Step 8: Compile clean**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix compile --warnings-as-errors
```

Expected: clean.

- [ ] **Step 9: Run targeted tests**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: all tests pass including the two palette tests.

- [ ] **Step 10: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green.

- [ ] **Step 11: Manual smoke check in the browser**

Open the dashboard. Click `+ New Seed`. Verify:

1. Inspector opens on the right with "New Seed" header and no stats grid.
2. Codeome listing is empty.
3. Palette is visible below the listing, all 10 categories present, no internal scroll on the palette itself.
4. Validation banner is amber (too short, too few non-nops — both errors shown).
5. Drag an opcode chip from the palette (e.g. `PUSH0`) to the codeome listing area → the chip drops at the position you released → server inserts the opcode → the listing shows a new block. The palette is intact.
6. Drag a few more opcodes to build a valid codeome → validation turns green → Spawn button enables → Save button enables.
7. Click Save → form opens → enter a name (e.g. "Smoke Test"), keep the default color, keep energy=10000 → click Save → inspector closes.
8. In the Seed dropdown, "★ Smoke Test" appears.
9. Select it, count=3, click Spawn → 3 lenies appear in the world with the chosen color.
10. Click `Manage` next to + New Seed → drawer opens listing the custom seed → click ⨯ → seed disappears from dropdown.
11. Open inspector on an existing species in the table → click Edit → palette appears below the existing listing → drag-drop from palette into the existing list also works.

- [ ] **Step 12: Commit**

```bash
cd /home/patrick/projects/playground/Lenies
git add assets/js/hooks/codeome_palette.js \
        assets/js/app.js \
        assets/js/hooks/codeome_sortable.js \
        lib/lenies_web/live/species_inspector_component.ex \
        assets/css/app.css \
        test/lenies_web/live/species_inspector_component_test.exs
git commit -m "feat: blocks palette + drag-drop from palette into codeome listing"
```

---

## Final sweep

- [ ] **Step 1: Run the full test suite one last time**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green except the known intermittent `Lenies.TelemetryTest` ring-buffer flake.

- [ ] **Step 2: Compile clean with warnings as errors**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix compile --warnings-as-errors
```

Expected: clean.

- [ ] **Step 3: End-to-end manual walkthrough**

Repeat the 11-step browser smoke check from Task 7 Step 11. If all 11 succeed, Phase D is shipped.
