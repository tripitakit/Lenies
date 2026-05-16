# Codeome Editor (Phase C2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the species inspector into a working visual editor: enter edit mode, mutate a copy of the codeome via insert/delete/replace/drag-reorder, and spawn N copies of the edited codeome into the world.

**Architecture:** All buffer mutations live in a pure `LeniesWeb.CodeomeBuffer` module. The `SpeciesInspectorComponent` gains edit-state assigns and event handlers that delegate to it. Drag-and-drop uses vendored SortableJS driven by a `CodeomeSortable` JS hook. Discard confirmations on Cancel/close/row-switch use a small `ConfirmAction` JS hook; the component sends a `{:inspector_dirty, bool}` message to the parent LiveView so it can decorate row attributes appropriately.

**Tech Stack:** Elixir 1.19, Phoenix LiveView, ExUnit, Tailwind v4, vanilla JS + SortableJS (vendored).

**Spec:** `docs/superpowers/specs/2026-05-15-codeome-editor.md`

---

## Task 1: Pure `LeniesWeb.CodeomeBuffer` module

**Files:**
- Create: `lib/lenies_web/codeome_buffer.ex`
- Create: `test/lenies_web/codeome_buffer_test.exs`

This is the foundation. Everything else delegates to these functions.

- [ ] **Step 1: Write the failing tests**

`test/lenies_web/codeome_buffer_test.exs`:

```elixir
defmodule LeniesWeb.CodeomeBufferTest do
  use ExUnit.Case, async: false

  alias LeniesWeb.CodeomeBuffer

  describe "insert/3" do
    test "inserts at the given index, shifting later items right" do
      assert CodeomeBuffer.insert([:a, :b, :c], 1, :z) == [:a, :z, :b, :c]
    end

    test "inserts at the start with index 0" do
      assert CodeomeBuffer.insert([:a, :b], 0, :z) == [:z, :a, :b]
    end

    test "inserts at the end when index >= length" do
      assert CodeomeBuffer.insert([:a, :b], 99, :z) == [:a, :b, :z]
    end

    test "inserts into an empty buffer" do
      assert CodeomeBuffer.insert([], 0, :z) == [:z]
    end
  end

  describe "delete/2" do
    test "removes the item at the index" do
      assert CodeomeBuffer.delete([:a, :b, :c], 1) == [:a, :c]
    end

    test "removes the first item" do
      assert CodeomeBuffer.delete([:a, :b], 0) == [:b]
    end

    test "is a no-op when index is past the end" do
      assert CodeomeBuffer.delete([:a, :b], 99) == [:a, :b]
    end

    test "is a no-op on an empty buffer" do
      assert CodeomeBuffer.delete([], 0) == []
    end
  end

  describe "replace/3" do
    test "replaces the item at the index" do
      assert CodeomeBuffer.replace([:a, :b, :c], 1, :z) == [:a, :z, :c]
    end

    test "is a no-op past the end" do
      assert CodeomeBuffer.replace([:a, :b], 99, :z) == [:a, :b]
    end

    test "is a no-op on an empty buffer" do
      assert CodeomeBuffer.replace([], 0, :z) == []
    end
  end

  describe "move/3" do
    test "moves later" do
      assert CodeomeBuffer.move([:a, :b, :c, :d], 0, 2) == [:b, :c, :a, :d]
    end

    test "moves earlier" do
      assert CodeomeBuffer.move([:a, :b, :c, :d], 3, 1) == [:a, :d, :b, :c]
    end

    test "is a no-op when from == to" do
      assert CodeomeBuffer.move([:a, :b, :c], 1, 1) == [:a, :b, :c]
    end

    test "is a no-op when from is out of range" do
      assert CodeomeBuffer.move([:a, :b], 99, 0) == [:a, :b]
    end

    test "clamps to to length when too large" do
      assert CodeomeBuffer.move([:a, :b, :c], 0, 99) == [:b, :c, :a]
    end
  end

  describe "validate/1" do
    setup do
      original_bounds = Application.get_env(:lenies, :codeome_length_bounds)
      original_min_non_nops = Application.get_env(:lenies, :min_viable_codeome_opcodes)

      Application.put_env(:lenies, :codeome_length_bounds, {5, 500})
      Application.put_env(:lenies, :min_viable_codeome_opcodes, 10)

      on_exit(fn ->
        if original_bounds do
          Application.put_env(:lenies, :codeome_length_bounds, original_bounds)
        end

        if original_min_non_nops do
          Application.put_env(:lenies, :min_viable_codeome_opcodes, original_min_non_nops)
        end
      end)

      :ok
    end

    test "ok when length and non_nops both satisfied" do
      buffer = List.duplicate(:nop_0, 5) ++ List.duplicate(:push0, 10)
      assert {:ok, %{len: 15, non_nops: 10}} = CodeomeBuffer.validate(buffer)
    end

    test "errors when too short" do
      assert {:error, errs} = CodeomeBuffer.validate([:push0, :push0])
      assert {:too_short, min: 5, got: 2} in errs
    end

    test "errors when insufficient non-nops" do
      buffer = List.duplicate(:nop_0, 20)
      assert {:error, errs} = CodeomeBuffer.validate(buffer)
      assert {:insufficient_non_nops, min: 10, got: 0} in errs
    end

    test "errors when too long" do
      buffer = List.duplicate(:push0, 501)
      assert {:error, errs} = CodeomeBuffer.validate(buffer)
      assert {:too_long, max: 500, got: 501} in errs
    end

    test "accumulates multiple errors" do
      assert {:error, errs} = CodeomeBuffer.validate([:nop_0, :nop_1])
      assert {:too_short, min: 5, got: 2} in errs
      assert {:insufficient_non_nops, min: 10, got: 0} in errs
    end
  end

  describe "from_codeome / to_codeome roundtrip" do
    test "round-trips" do
      original = Lenies.Codeome.from_list([:push0, :push1, :store])
      buffer = CodeomeBuffer.from_codeome(original)
      assert buffer == [:push0, :push1, :store]
      back = CodeomeBuffer.to_codeome(buffer)
      assert Lenies.Codeome.to_list(back) == [:push0, :push1, :store]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/codeome_buffer_test.exs
```

Expected: module not found.

- [ ] **Step 3: Implement the module**

`lib/lenies_web/codeome_buffer.ex`:

```elixir
defmodule LeniesWeb.CodeomeBuffer do
  @moduledoc """
  Pure operations on a list-of-opcode-atoms buffer used by the codeome editor.

  Each operation returns a new buffer; nothing in-place. The component owns
  the assign; this module owns the transformations.
  """

  @type buffer :: [atom()]

  @type validation_error ::
          {:too_short, [min: pos_integer(), got: non_neg_integer()]}
          | {:too_long, [max: pos_integer(), got: non_neg_integer()]}
          | {:insufficient_non_nops, [min: pos_integer(), got: non_neg_integer()]}

  @spec from_codeome(Lenies.Codeome.t()) :: buffer()
  def from_codeome(codeome), do: Lenies.Codeome.to_list(codeome)

  @spec to_codeome(buffer()) :: Lenies.Codeome.t()
  def to_codeome(buffer), do: Lenies.Codeome.from_list(buffer)

  @spec insert(buffer(), non_neg_integer(), atom()) :: buffer()
  def insert(buffer, index, opcode) when is_atom(opcode) and index >= 0 do
    clamped = min(index, length(buffer))
    {before, rest} = Enum.split(buffer, clamped)
    before ++ [opcode] ++ rest
  end

  @spec delete(buffer(), non_neg_integer()) :: buffer()
  def delete(buffer, index) when index >= 0 do
    case Enum.split(buffer, index) do
      {before, [_removed | rest]} -> before ++ rest
      {_, []} -> buffer
    end
  end

  @spec replace(buffer(), non_neg_integer(), atom()) :: buffer()
  def replace(buffer, index, opcode) when is_atom(opcode) and index >= 0 do
    case Enum.split(buffer, index) do
      {before, [_old | rest]} -> before ++ [opcode] ++ rest
      {_, []} -> buffer
    end
  end

  @spec move(buffer(), non_neg_integer(), non_neg_integer()) :: buffer()
  def move(buffer, from, to) when from >= 0 and to >= 0 do
    cond do
      from == to ->
        buffer

      from >= length(buffer) ->
        buffer

      true ->
        {item, without} = List.pop_at(buffer, from)
        clamped_to = min(to, length(without))
        List.insert_at(without, clamped_to, item)
    end
  end

  @spec validate(buffer()) ::
          {:ok, %{len: non_neg_integer(), non_nops: non_neg_integer()}}
          | {:error, [validation_error()]}
  def validate(buffer) do
    {min_len, max_len} = Application.get_env(:lenies, :codeome_length_bounds, {5, 500})
    min_non_nops = Application.get_env(:lenies, :min_viable_codeome_opcodes, 10)
    len = length(buffer)
    non_nops = Enum.count(buffer, &(&1 not in [:nop_0, :nop_1]))

    errs =
      [
        len < min_len && {:too_short, min: min_len, got: len},
        len > max_len && {:too_long, max: max_len, got: len},
        non_nops < min_non_nops &&
          {:insufficient_non_nops, min: min_non_nops, got: non_nops}
      ]
      |> Enum.filter(& &1)

    if errs == [], do: {:ok, %{len: len, non_nops: non_nops}}, else: {:error, errs}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/codeome_buffer_test.exs
```

Expected: all tests pass (22 cases across 6 describes).

- [ ] **Step 5: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green (modulo the known telemetry flake).

- [ ] **Step 6: Commit**

```bash
git add lib/lenies_web/codeome_buffer.ex test/lenies_web/codeome_buffer_test.exs
git commit -m "feat: LeniesWeb.CodeomeBuffer — pure buffer ops + validation"
```

---

## Task 2: Inspector edit mode toggle + buffer init

**Files:**
- Modify: `lib/lenies_web/live/species_inspector_component.ex`
- Modify: `test/lenies_web/live/species_inspector_component_test.exs`

Add the edit-state assigns and the toggle. No edit operations yet — those land in Task 3.

- [ ] **Step 1: Write the failing tests**

Append to `test/lenies_web/live/species_inspector_component_test.exs`, inside the existing module, after the last `describe` block:

```elixir
  describe "edit mode toggle" do
    test "Edit button visible in read mode" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      assert html =~ ~s(phx-click="enter_edit")
      refute html =~ ~s(phx-click="cancel_edit")
    end

    test "the toolbar in read mode has the Edit button but not Cancel" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      assert html =~ "Edit"
      refute html =~ ~s(>Cancel<)
    end

    test "renders without crashing when buffer is empty and no codeome is cached" do
      # The component must tolerate the initial mount state where no buffer
      # has been populated yet (read mode default).
      html = render_component(SpeciesInspectorComponent, base_assigns())
      refute html =~ "Cancel"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: failures on the `Edit` button assertions because no such button exists yet.

- [ ] **Step 3: Modify `mount/1` and `update/2` to add edit-state assigns**

In `lib/lenies_web/live/species_inspector_component.ex`, replace the `mount/1` function with:

```elixir
  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:codeome_lines, [])
     |> assign(:fetch_status, :ok)
     |> assign(:cached_codeome_hash, nil)
     |> assign(:edit_mode, false)
     |> assign(:buffer, [])
     |> assign(:dirty, false)}
  end
```

In the same file, the existing `update/2` clause that handles a new `selected_hash` must also reset edit state when the hash changes. Replace the entire `update/2` first clause with:

```elixir
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
       |> assign(:cached_codeome_hash, hash)
       |> assign(:edit_mode, false)
       |> assign(:buffer, [])
       |> assign(:dirty, false)
       |> notify_parent_dirty(false)}
    end
  end
```

Add the `notify_parent_dirty/2` helper at the bottom of the module (before the closing `end`):

```elixir
  # Notify the parent LiveView about dirty-state changes so it can decorate
  # interactive elements (e.g. species table rows) with a confirm prompt.
  defp notify_parent_dirty(socket, dirty) do
    send(self(), {:inspector_dirty, dirty})
    socket
  end
```

- [ ] **Step 4: Add `enter_edit` and `cancel_edit` handlers**

Inside the same module, after the existing `update/2` clauses and before `render/1`, add:

```elixir
  @impl true
  def handle_event("enter_edit", _params, socket) do
    buffer = Enum.map(socket.assigns.codeome_lines, & &1.opcode)

    {:noreply,
     socket
     |> assign(:edit_mode, true)
     |> assign(:buffer, buffer)
     |> assign(:dirty, false)
     |> notify_parent_dirty(false)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:edit_mode, false)
     |> assign(:buffer, [])
     |> assign(:dirty, false)
     |> notify_parent_dirty(false)}
  end
```

- [ ] **Step 5: Render the toolbar with Edit / Cancel**

In the same file, the `render/1` template currently has a header with the swatch, the hash, the `↗` link and the `×` button. Add a toolbar row immediately under the header, before the stats grid. Replace the section that currently looks like:

```heex
      <header class="flex items-center gap-2">
        ...existing header content...
      </header>

      <div class="grid grid-cols-3 gap-2 text-[11px]">
```

with:

```heex
      <header class="flex items-center gap-2">
        ...existing header content (unchanged)...
      </header>

      <div class="flex items-center gap-2 text-[10px]">
        <%= if @edit_mode do %>
          <button
            type="button"
            phx-click="cancel_edit"
            phx-target={@myself}
            class="px-2 py-0.5 border border-slate-500 hover:bg-slate-700"
          >
            Cancel
          </button>
        <% else %>
          <button
            type="button"
            phx-click="enter_edit"
            phx-target={@myself}
            class="px-2 py-0.5 border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40"
          >
            Edit
          </button>
        <% end %>

        <%= if @dirty do %>
          <span class="text-amber-300 text-[10px]">●dirty</span>
        <% end %>
      </div>

      <div class="grid grid-cols-3 gap-2 text-[11px]">
```

Do not change the existing content (header, stats grid, codeome blocks listing). Only insert the new toolbar `<div>`.

- [ ] **Step 6: Make blocks render from buffer when in edit mode**

In the same template, the block listing currently iterates `@codeome_lines`. We want it to render from `@buffer` when `@edit_mode` is true. Find this block in the template:

```heex
      <div class="flex-1 min-h-0 overflow-auto">
        <div class="codeome-blocks">
          <%= for line <- @codeome_lines do %>
            <div class={"codeome-block op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
              ...
            </div>
          <% end %>
        </div>
      </div>
```

Replace with:

```heex
      <div class="flex-1 min-h-0 overflow-auto">
        <div class="codeome-blocks">
          <%= if @edit_mode do %>
            <%= for {opcode, idx} <- Enum.with_index(@buffer) do %>
              <div class={"codeome-block op op-" <> Atom.to_string(Disassembler.opcode_class(opcode))}>
                <span class="codeome-block-idx">
                  {String.pad_leading(Integer.to_string(idx), 3, "0")}
                </span>
                <span class="codeome-block-name">
                  {Atom.to_string(opcode) |> String.upcase()}
                </span>
              </div>
            <% end %>
          <% else %>
            <%= for line <- @codeome_lines do %>
              <div class={"codeome-block op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
                <span class="codeome-block-idx">
                  {String.pad_leading(Integer.to_string(line.index), 3, "0")}
                </span>
                <span class="codeome-block-name">
                  {Atom.to_string(line.opcode) |> String.upcase()}
                </span>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
```

Action buttons per block (delete/replace/drag-handle) come in Task 3 and Task 6.

- [ ] **Step 7: Run tests to verify they pass**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: all tests pass, including the three new ones.

- [ ] **Step 8: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green.

- [ ] **Step 9: Commit**

```bash
git add lib/lenies_web/live/species_inspector_component.ex \
        test/lenies_web/live/species_inspector_component_test.exs
git commit -m "feat: inspector edit mode toggle (Edit / Cancel) + buffer state"
```

---

## Task 3: Insert / delete / replace + picker dropdown

**Files:**
- Modify: `lib/lenies_web/live/species_inspector_component.ex`
- Modify: `test/lenies_web/live/species_inspector_component_test.exs`
- Modify: `assets/css/app.css`

In edit mode each block shows action buttons (`⨯` delete, `↺` replace) and between adjacent blocks a hover-only `+ insert` affordance opens a categorized picker dropdown.

- [ ] **Step 1: Write the failing tests**

Append to the existing inspector test module:

```elixir
  describe "edit operations" do
    test "in edit mode, each block has delete and replace buttons" do
      assigns =
        base_assigns(%{species_record: %{hash: "abc", population: 0, avg_generation: 0.0}})

      # We can't easily enter edit mode from render_component, so use a
      # direct render with seeded assigns instead.
      socket = build_socket(assigns, edit_mode: true, buffer: [:push0, :push1, :store])
      html = Phoenix.LiveViewTest.render_component(SpeciesInspectorComponent, socket)

      assert html =~ ~s(phx-click="edit_delete")
      assert html =~ ~s(phx-click="open_picker")
    end

    test "in edit mode, insert affordances exist between blocks" do
      socket = build_socket(base_assigns(), edit_mode: true, buffer: [:push0, :push1, :store])
      html = Phoenix.LiveViewTest.render_component(SpeciesInspectorComponent, socket)
      assert html =~ "codeome-insert-slot"
    end

    test "in read mode, action buttons are absent" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      refute html =~ ~s(phx-click="edit_delete")
      refute html =~ ~s(phx-click="open_picker")
      refute html =~ "codeome-insert-slot"
    end

    test "the picker is hidden by default in edit mode" do
      socket = build_socket(base_assigns(), edit_mode: true, buffer: [:push0, :push1, :store])
      html = Phoenix.LiveViewTest.render_component(SpeciesInspectorComponent, socket)
      refute html =~ "codeome-picker"
    end

    test "the picker is rendered when picker_open is set" do
      socket =
        build_socket(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push1, :store],
          picker_open: %{index: 1, mode: :insert}
        )

      html = Phoenix.LiveViewTest.render_component(SpeciesInspectorComponent, socket)
      assert html =~ "codeome-picker"
      # Picker groups by category — at least the "stack" group must appear
      assert html =~ "stack"
      assert html =~ ~s(phx-click="picker_choose")
    end
  end

  # Helper to build an assigns map that includes the component's internal
  # state. Used because Phoenix.LiveViewTest.render_component/2 does not
  # call mount/update; it renders directly from assigns.
  defp build_socket(base, opts) do
    Map.merge(base, Map.new(opts))
    |> Map.put_new(:codeome_lines, [])
    |> Map.put_new(:fetch_status, :ok)
    |> Map.put_new(:cached_codeome_hash, base[:selected_hash])
    |> Map.put_new(:edit_mode, false)
    |> Map.put_new(:buffer, [])
    |> Map.put_new(:dirty, false)
    |> Map.put_new(:picker_open, nil)
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: failures — none of the new `phx-click` attributes exist yet.

- [ ] **Step 3: Add the `:picker_open` assign to `mount/1`**

In `lib/lenies_web/live/species_inspector_component.ex` `mount/1`, append one more assign:

```elixir
  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:codeome_lines, [])
     |> assign(:fetch_status, :ok)
     |> assign(:cached_codeome_hash, nil)
     |> assign(:edit_mode, false)
     |> assign(:buffer, [])
     |> assign(:dirty, false)
     |> assign(:picker_open, nil)}
  end
```

Also update the `update/2` first clause to reset `:picker_open` when `selected_hash` changes:

```elixir
       |> assign(:edit_mode, false)
       |> assign(:buffer, [])
       |> assign(:dirty, false)
       |> assign(:picker_open, nil)
       |> notify_parent_dirty(false)}
```

And update `cancel_edit` to reset `:picker_open` too:

```elixir
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:edit_mode, false)
     |> assign(:buffer, [])
     |> assign(:dirty, false)
     |> assign(:picker_open, nil)
     |> notify_parent_dirty(false)}
  end
```

- [ ] **Step 4: Add edit-operation handlers and the picker handlers**

After the existing `handle_event` clauses, add:

```elixir
  def handle_event("edit_delete", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    new_buffer = LeniesWeb.CodeomeBuffer.delete(socket.assigns.buffer, index)
    apply_buffer_change(socket, new_buffer)
  end

  def handle_event("open_picker", %{"index" => index_str, "mode" => mode_str}, socket) do
    index = String.to_integer(index_str)
    mode = String.to_existing_atom(mode_str)
    {:noreply, assign(socket, :picker_open, %{index: index, mode: mode})}
  end

  def handle_event("close_picker", _params, socket) do
    {:noreply, assign(socket, :picker_open, nil)}
  end

  def handle_event("picker_choose", %{"opcode" => opcode_str}, socket) do
    opcode = String.to_existing_atom(opcode_str)

    case socket.assigns.picker_open do
      %{index: index, mode: :insert} ->
        new_buffer = LeniesWeb.CodeomeBuffer.insert(socket.assigns.buffer, index, opcode)

        socket
        |> assign(:picker_open, nil)
        |> apply_buffer_change(new_buffer)

      %{index: index, mode: :replace} ->
        new_buffer = LeniesWeb.CodeomeBuffer.replace(socket.assigns.buffer, index, opcode)

        socket
        |> assign(:picker_open, nil)
        |> apply_buffer_change(new_buffer)

      _ ->
        {:noreply, socket}
    end
  end

  # apply_buffer_change: shared logic for any mutation. Computes dirty + notifies parent.
  defp apply_buffer_change(socket, new_buffer) do
    original = Enum.map(socket.assigns.codeome_lines, & &1.opcode)
    dirty = new_buffer != original

    {:noreply,
     socket
     |> assign(:buffer, new_buffer)
     |> assign(:dirty, dirty)
     |> notify_parent_dirty(dirty)}
  end
```

- [ ] **Step 5: Render action buttons on each block in edit mode**

Find the edit-mode block iteration added in Task 2 and replace it with:

```heex
          <%= if @edit_mode do %>
            <%= for {opcode, idx} <- Enum.with_index(@buffer) do %>
              <div class="codeome-insert-slot">
                <button
                  type="button"
                  phx-click="open_picker"
                  phx-value-index={idx}
                  phx-value-mode="insert"
                  phx-target={@myself}
                  class="codeome-insert-btn"
                >
                  +
                </button>
              </div>

              <div class={"codeome-block codeome-block-editable op op-" <> Atom.to_string(Disassembler.opcode_class(opcode))}>
                <span class="codeome-block-idx">
                  {String.pad_leading(Integer.to_string(idx), 3, "0")}
                </span>
                <span class="codeome-block-name">
                  {Atom.to_string(opcode) |> String.upcase()}
                </span>
                <span class="codeome-block-actions">
                  <button
                    type="button"
                    phx-click="open_picker"
                    phx-value-index={idx}
                    phx-value-mode="replace"
                    phx-target={@myself}
                    class="codeome-action-btn"
                    title="Replace"
                  >
                    ↺
                  </button>
                  <button
                    type="button"
                    phx-click="edit_delete"
                    phx-value-index={idx}
                    phx-target={@myself}
                    class="codeome-action-btn"
                    title="Delete"
                  >
                    ⨯
                  </button>
                </span>
              </div>
            <% end %>

            <div class="codeome-insert-slot">
              <button
                type="button"
                phx-click="open_picker"
                phx-value-index={length(@buffer)}
                phx-value-mode="insert"
                phx-target={@myself}
                class="codeome-insert-btn"
              >
                +
              </button>
            </div>
          <% else %>
            ...existing read-mode iteration over @codeome_lines, unchanged...
          <% end %>
```

The read-mode branch is exactly as it was in Task 2 — don't touch it.

- [ ] **Step 6: Render the picker dropdown**

Above the codeome-blocks scroll container in the template (so it floats correctly), add:

```heex
      <%= if @picker_open do %>
        <div class="codeome-picker">
          <div class="codeome-picker-header">
            <span>
              {if @picker_open.mode == :insert, do: "Insert at", else: "Replace at"} #{@picker_open.index}
            </span>
            <button
              type="button"
              phx-click="close_picker"
              phx-target={@myself}
              class="codeome-action-btn"
            >
              ×
            </button>
          </div>
          <%= for {category, ops} <- grouped_opcodes() do %>
            <div class="codeome-picker-group">
              <div class="codeome-picker-group-label">{category}</div>
              <div class="codeome-picker-group-grid">
                <%= for op <- ops do %>
                  <button
                    type="button"
                    phx-click="picker_choose"
                    phx-value-opcode={Atom.to_string(op)}
                    phx-target={@myself}
                    class={"codeome-picker-chip op op-" <> Atom.to_string(Disassembler.opcode_class(op))}
                  >
                    {Atom.to_string(op) |> String.upcase()}
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
```

Add the `grouped_opcodes/0` helper at the bottom of the module (before the final `end`):

```elixir
  # Groups all whitelisted opcodes by Disassembler category, in a stable order.
  defp grouped_opcodes do
    order = [
      :template,
      :stack,
      :arith,
      :control,
      :sense,
      :action,
      :predation,
      :self_inspect,
      :replication,
      :memory
    ]

    by_class =
      Lenies.Codeome.Opcodes.all()
      |> Enum.group_by(&Disassembler.opcode_class/1)

    for cat <- order, ops = by_class[cat], is_list(ops) and ops != [] do
      {cat, Enum.sort(ops)}
    end
  end
```

- [ ] **Step 7: Add CSS for action buttons, insert slots, and the picker**

Append to `assets/css/app.css`, after the existing `.codeome-blocks` rules:

```css
/* ----- Codeome editor (Phase C2) ----- */
.lenies-dashboard .codeome-block-editable {
  position: relative;
  padding-right: 38px;
}

.lenies-dashboard .codeome-block-actions {
  position: absolute;
  right: 4px;
  top: 50%;
  transform: translateY(-50%);
  display: none;
  gap: 2px;
}

.lenies-dashboard .codeome-block-editable:hover .codeome-block-actions {
  display: inline-flex;
}

.lenies-dashboard .codeome-action-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 14px;
  height: 14px;
  font-size: 10px;
  line-height: 1;
  border: 1px solid rgba(34, 211, 238, 0.4);
  background: rgba(2, 6, 23, 0.7);
  color: #e2e8f0;
  cursor: pointer;
}

.lenies-dashboard .codeome-action-btn:hover {
  background: rgba(34, 211, 238, 0.2);
  color: #22d3ee;
}

.lenies-dashboard .codeome-insert-slot {
  height: 0;
  position: relative;
  display: flex;
  justify-content: center;
  align-items: center;
  overflow: visible;
}

.lenies-dashboard .codeome-insert-btn {
  display: none;
  position: relative;
  width: 16px;
  height: 16px;
  border: 1px dashed rgba(34, 211, 238, 0.6);
  background: #050816;
  color: #22d3ee;
  font-size: 12px;
  line-height: 1;
  cursor: pointer;
  z-index: 2;
}

.lenies-dashboard .codeome-insert-slot:hover .codeome-insert-btn {
  display: inline-flex;
}

.lenies-dashboard .codeome-picker {
  position: absolute;
  top: 8rem;
  right: 8px;
  width: 280px;
  max-height: 60vh;
  overflow-y: auto;
  background: rgba(2, 6, 23, 0.96);
  border: 1px solid rgba(34, 211, 238, 0.5);
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.7);
  padding: 6px;
  font-size: 10px;
  z-index: 50;
}

.lenies-dashboard .codeome-picker-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 2px 4px 6px;
  border-bottom: 1px solid rgba(34, 211, 238, 0.2);
  color: #94a3b8;
}

.lenies-dashboard .codeome-picker-group {
  padding: 4px 0;
}

.lenies-dashboard .codeome-picker-group-label {
  opacity: 0.6;
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  margin-bottom: 2px;
}

.lenies-dashboard .codeome-picker-group-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 2px;
}

.lenies-dashboard .codeome-picker-chip {
  padding: 2px 4px;
  border: 1px solid currentColor;
  background: rgba(2, 6, 23, 0.6);
  font-family: ui-monospace, "JetBrains Mono", "Fira Code", monospace;
  font-size: 10px;
  letter-spacing: 0.04em;
  cursor: pointer;
  text-align: left;
}

.lenies-dashboard .codeome-picker-chip:hover {
  background: rgba(34, 211, 238, 0.15);
}
```

- [ ] **Step 8: Run tests to verify they pass**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: all tests pass.

- [ ] **Step 9: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green.

- [ ] **Step 10: Commit**

```bash
git add lib/lenies_web/live/species_inspector_component.ex \
        test/lenies_web/live/species_inspector_component_test.exs \
        assets/css/app.css
git commit -m "feat: codeome editor insert / delete / replace + picker"
```

---

## Task 4: Live validation + status display

**Files:**
- Modify: `lib/lenies_web/live/species_inspector_component.ex`
- Modify: `test/lenies_web/live/species_inspector_component_test.exs`

After every buffer mutation, validate and surface the result in the toolbar.

- [ ] **Step 1: Write the failing tests**

Append to the inspector test module:

```elixir
  describe "live validation" do
    setup do
      Application.put_env(:lenies, :codeome_length_bounds, {5, 500})
      Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)
      :ok
    end

    test "ok validation status in edit mode for a long-enough buffer" do
      socket =
        build_socket(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}}
        )

      html = Phoenix.LiveViewTest.render_component(SpeciesInspectorComponent, socket)
      assert html =~ "valid"
      assert html =~ "6 ops"
    end

    test "error validation status when too short" do
      socket =
        build_socket(base_assigns(),
          edit_mode: true,
          buffer: [:push0],
          validation: {:error, [{:too_short, [min: 5, got: 1]}]}
        )

      html = Phoenix.LiveViewTest.render_component(SpeciesInspectorComponent, socket)
      assert html =~ "too short"
    end
  end
```

Update the `build_socket/2` helper in the same file so it accepts `:validation`:

```elixir
  defp build_socket(base, opts) do
    Map.merge(base, Map.new(opts))
    |> Map.put_new(:codeome_lines, [])
    |> Map.put_new(:fetch_status, :ok)
    |> Map.put_new(:cached_codeome_hash, base[:selected_hash])
    |> Map.put_new(:edit_mode, false)
    |> Map.put_new(:buffer, [])
    |> Map.put_new(:dirty, false)
    |> Map.put_new(:picker_open, nil)
    |> Map.put_new(:validation, {:ok, %{len: 0, non_nops: 0}})
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: failures — no validation text in the rendered output yet.

- [ ] **Step 3: Add the `:validation` assign to mount and recompute on every mutation**

In `lib/lenies_web/live/species_inspector_component.ex` `mount/1`, append:

```elixir
     |> assign(:validation, {:ok, %{len: 0, non_nops: 0}})}
```

In `enter_edit`, after assigning the buffer, recompute validation:

```elixir
  def handle_event("enter_edit", _params, socket) do
    buffer = Enum.map(socket.assigns.codeome_lines, & &1.opcode)

    {:noreply,
     socket
     |> assign(:edit_mode, true)
     |> assign(:buffer, buffer)
     |> assign(:dirty, false)
     |> assign(:validation, LeniesWeb.CodeomeBuffer.validate(buffer))
     |> notify_parent_dirty(false)}
  end
```

Update `apply_buffer_change/2` to also recompute validation:

```elixir
  defp apply_buffer_change(socket, new_buffer) do
    original = Enum.map(socket.assigns.codeome_lines, & &1.opcode)
    dirty = new_buffer != original

    {:noreply,
     socket
     |> assign(:buffer, new_buffer)
     |> assign(:dirty, dirty)
     |> assign(:validation, LeniesWeb.CodeomeBuffer.validate(new_buffer))
     |> notify_parent_dirty(dirty)}
  end
```

- [ ] **Step 4: Render the validation status in the toolbar**

In the template, immediately after the toolbar row (the row containing the Edit/Cancel button + the dirty indicator) and before the stats grid, add a validity row visible only in edit mode:

```heex
      <%= if @edit_mode do %>
        <div class="text-[10px]">
          <%= case @validation do %>
            <% {:ok, info} -> %>
              <span class="text-emerald-300">✓ valid</span>
              <span class="opacity-60">
                ({info.len} ops, {info.non_nops} non-nop)
              </span>
            <% {:error, errors} -> %>
              <span class="text-amber-300">⚠</span>
              <span class="opacity-80">
                {Enum.map_join(errors, ", ", &format_validation_error/1)}
              </span>
          <% end %>
        </div>
      <% end %>
```

Add the formatter helper at the bottom of the module (before the final `end`):

```elixir
  defp format_validation_error({:too_short, opts}),
    do: "too short (#{opts[:got]} ops, min #{opts[:min]})"

  defp format_validation_error({:too_long, opts}),
    do: "too long (#{opts[:got]} ops, max #{opts[:max]})"

  defp format_validation_error({:insufficient_non_nops, opts}),
    do: "too few non-nops (#{opts[:got]}, min #{opts[:min]})"
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green.

- [ ] **Step 7: Commit**

```bash
git add lib/lenies_web/live/species_inspector_component.ex \
        test/lenies_web/live/species_inspector_component_test.exs
git commit -m "feat: live validation status in codeome editor toolbar"
```

---

## Task 5: Spawn flow

**Files:**
- Modify: `lib/lenies_web/live/species_inspector_component.ex`
- Modify: `test/lenies_web/live/species_inspector_component_test.exs`

A `Spawn ▾` button in the toolbar opens a small inline form. Submit calls `Lenies.World.spawn_lenie/2` N times with the buffer's codeome.

- [ ] **Step 1: Write the failing tests**

Append to the inspector test module:

```elixir
  describe "spawn flow" do
    test "Spawn button visible only in edit mode" do
      html_read = render_component(SpeciesInspectorComponent, base_assigns())
      refute html_read =~ ~s(>Spawn<)

      socket =
        build_socket(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}}
        )

      html_edit = Phoenix.LiveViewTest.render_component(SpeciesInspectorComponent, socket)
      assert html_edit =~ ~s(>Spawn<)
    end

    test "Spawn button is disabled when validation fails" do
      socket =
        build_socket(base_assigns(),
          edit_mode: true,
          buffer: [:push0],
          validation: {:error, [{:too_short, [min: 5, got: 1]}]}
        )

      html = Phoenix.LiveViewTest.render_component(SpeciesInspectorComponent, socket)
      assert html =~ ~r/<button[^>]*disabled[^>]*>\s*Spawn\s*</
    end

    test "Spawn form hidden by default and opens when show_spawn_form is true" do
      socket_closed =
        build_socket(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}}
        )

      html_closed = Phoenix.LiveViewTest.render_component(SpeciesInspectorComponent, socket_closed)
      refute html_closed =~ ~s(name="count")

      socket_open =
        build_socket(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}},
          show_spawn_form: true
        )

      html_open = Phoenix.LiveViewTest.render_component(SpeciesInspectorComponent, socket_open)
      assert html_open =~ ~s(name="count")
      assert html_open =~ ~s(name="energy")
    end
  end

  describe "submit_spawn integration" do
    alias Lenies.World.Tables

    setup do
      Tables.create_all()

      case Process.whereis(Lenies.Registry) do
        nil -> {:ok, _} = Registry.start_link(keys: :unique, name: Lenies.Registry)
        _ -> :ok
      end

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

        Tables.delete_all()
      end)

      :ok
    end

    test "spawns N lenies with the buffer's codeome" do
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
        :nop_1,
        :push0,
        :load
      ]

      pop_before = :ets.info(:lenies, :size) || 0

      # Call the handler directly via the well-known module function
      {:noreply, _socket} =
        SpeciesInspectorComponent.handle_event(
          "submit_spawn",
          %{"count" => "3", "energy" => "10000"},
          %Phoenix.LiveView.Socket{
            assigns: %{
              __changed__: %{},
              flash: %{},
              myself: %Phoenix.LiveComponent.CID{cid: 1},
              buffer: buffer,
              validation: {:ok, %{len: length(buffer), non_nops: 10}},
              show_spawn_form: true,
              selected_hash: "test-hash"
            }
          }
        )

      # Spawning is via GenServer.call (synchronous), so the population is
      # immediately observable after submit_spawn returns.
      pop_after = :ets.info(:lenies, :size) || 0
      assert pop_after >= pop_before + 3
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: failures.

- [ ] **Step 3: Add the spawn-form assigns and handlers**

In `lib/lenies_web/live/species_inspector_component.ex` `mount/1`, append:

```elixir
     |> assign(:show_spawn_form, false)}
```

In the `update/2` first clause, add `:show_spawn_form` reset on hash change:

```elixir
       |> assign(:show_spawn_form, false)
       |> notify_parent_dirty(false)}
```

In `cancel_edit`, also reset:

```elixir
     |> assign(:show_spawn_form, false)
```

Add the new handlers after the existing ones:

```elixir
  def handle_event("open_spawn_form", _params, socket) do
    {:noreply, assign(socket, :show_spawn_form, true)}
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
          try do
            Lenies.World.spawn_lenie(codeome, energy: energy * 1.0, dir: Enum.random(dirs))
          catch
            :exit, _ -> :ok
          end
        end)

        {:noreply, assign(socket, :show_spawn_form, false)}

      {:error, _} ->
        # Invalid buffer — do nothing, leave the form open.
        {:noreply, socket}
    end
  end

  defp parse_clamped(s, min, max, fallback) do
    case Integer.parse(s) do
      {n, _} -> n |> max(min) |> min(max)
      :error -> fallback
    end
  end
```

- [ ] **Step 4: Render the Spawn button and the inline form**

In the template toolbar row, add a Spawn button to the right of the dirty indicator (only visible in edit mode):

```heex
      <div class="flex items-center gap-2 text-[10px]">
        <%= if @edit_mode do %>
          <button
            type="button"
            phx-click="cancel_edit"
            phx-target={@myself}
            class="px-2 py-0.5 border border-slate-500 hover:bg-slate-700"
          >
            Cancel
          </button>
        <% else %>
          <button
            type="button"
            phx-click="enter_edit"
            phx-target={@myself}
            class="px-2 py-0.5 border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40"
          >
            Edit
          </button>
        <% end %>

        <%= if @dirty do %>
          <span class="text-amber-300 text-[10px]">●dirty</span>
        <% end %>

        <%= if @edit_mode do %>
          <button
            type="button"
            phx-click="open_spawn_form"
            phx-target={@myself}
            disabled={!match?({:ok, _}, @validation)}
            class="ml-auto px-2 py-0.5 border border-emerald-500/60 text-emerald-200 hover:bg-emerald-900/40 disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Spawn
          </button>
        <% end %>
      </div>
```

After the validation status row, render the spawn form when `@show_spawn_form` is true:

```heex
      <%= if @edit_mode and @show_spawn_form do %>
        <form
          phx-submit="submit_spawn"
          phx-target={@myself}
          class="flex flex-col gap-1.5 border border-emerald-500/30 p-2 text-[11px]"
        >
          <label class="flex items-center gap-2">
            <span class="opacity-70 w-14">count</span>
            <input
              type="number"
              name="count"
              value="1"
              min="1"
              max="50"
              class="w-16 text-xs"
            />
          </label>
          <label class="flex items-center gap-2">
            <span class="opacity-70 w-14">energy</span>
            <input
              type="number"
              name="energy"
              value="10000"
              min="1"
              max="1000000"
              class="w-24 text-xs"
            />
          </label>
          <div class="flex gap-1 justify-end">
            <button
              type="button"
              phx-click="cancel_spawn_form"
              phx-target={@myself}
              class="px-2 py-0.5 border border-slate-500 hover:bg-slate-700"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-2 py-0.5 border border-emerald-500/60 text-emerald-200 hover:bg-emerald-900/40"
            >
              Spawn
            </button>
          </div>
        </form>
      <% end %>
```

- [ ] **Step 5: Run the targeted tests**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: all tests pass, including the spawn integration test.

- [ ] **Step 6: Run the full suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green.

- [ ] **Step 7: Commit**

```bash
git add lib/lenies_web/live/species_inspector_component.ex \
        test/lenies_web/live/species_inspector_component_test.exs
git commit -m "feat: codeome editor — spawn N lenies from buffer"
```

---

## Task 6: SortableJS vendored + drag-and-drop hook

**Files:**
- Create: `assets/vendor/sortable.js`
- Create: `assets/js/hooks/codeome_sortable.js`
- Modify: `assets/js/app.js`
- Modify: `lib/lenies_web/live/species_inspector_component.ex`
- Modify: `assets/css/app.css`

Add drag-and-drop reordering. No automated test for the JS — manual smoke check at the end.

- [ ] **Step 1: Vendor SortableJS**

Download the latest stable UMD bundle of SortableJS into `assets/vendor/sortable.js`:

```bash
curl -L https://cdn.jsdelivr.net/npm/sortablejs@1.15.6/Sortable.min.js \
  -o assets/vendor/sortable.js
```

Verify the file size is ~40–60 KB and that it begins with the SortableJS license header:

```bash
head -1 assets/vendor/sortable.js
wc -c assets/vendor/sortable.js
```

The file is treated like the other vendored scripts (`topbar.js`, `daisyui.js`) — no `npm install`, no `package.json`.

- [ ] **Step 2: Create the JS hook**

`assets/js/hooks/codeome_sortable.js`:

```javascript
// CodeomeSortable hook: enables drag-and-drop reorder of codeome blocks in
// the SpeciesInspectorComponent's edit mode. On drop, emits an
// `edit_reorder` event to the component with the from/to indices.
//
// Driven by vendored SortableJS (assets/vendor/sortable.js). Phoenix
// LiveView re-renders after the event applies the mutation; SortableJS's
// own DOM mutation during drag is replaced by LiveView's morphed DOM, but
// the visible result is the same because the buffer ordering matches the
// dropped position.

import Sortable from "../../vendor/sortable.js";

const CodeomeSortable = {
  mounted() {
    this.attach();
  },

  updated() {
    // Re-attach if the underlying list element was replaced.
    if (!this.sortable || !this.el.isConnected) {
      this.attach();
    }
  },

  destroyed() {
    if (this.sortable) {
      this.sortable.destroy();
      this.sortable = null;
    }
  },

  attach() {
    if (this.sortable) this.sortable.destroy();

    this.sortable = Sortable.create(this.el, {
      animation: 120,
      handle: ".codeome-drag-handle",
      ghostClass: "codeome-block-ghost",
      // Only sort children that have data-idx — skip insert slots.
      filter: ".codeome-insert-slot",
      preventOnFilter: false,
      draggable: ".codeome-block-editable",
      onEnd: (evt) => {
        // SortableJS gives oldDraggableIndex/newDraggableIndex counting only
        // elements matching the `draggable` selector — these correspond
        // exactly to buffer positions because insert slots are filtered out.
        if (
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
    });
  },
};

export default CodeomeSortable;
```

The `oldDraggableIndex` / `newDraggableIndex` properties from SortableJS count only items that match the `draggable` selector (i.e., the blocks themselves, ignoring insert slots), so they correspond exactly to buffer positions.

- [ ] **Step 3: Register the hook**

Modify `assets/js/app.js`. Find:

```javascript
import GridCanvas from "./hooks/grid_canvas"
import ActionFeedback from "./hooks/action_feedback"

const Hooks = {GridCanvas, ActionFeedback, ...colocatedHooks}
```

Replace with:

```javascript
import GridCanvas from "./hooks/grid_canvas"
import ActionFeedback from "./hooks/action_feedback"
import CodeomeSortable from "./hooks/codeome_sortable"

const Hooks = {GridCanvas, ActionFeedback, CodeomeSortable, ...colocatedHooks}
```

- [ ] **Step 4: Add drag-handle to each editable block and the `phx-hook` to the container**

In `lib/lenies_web/live/species_inspector_component.ex`, in the edit-mode block iteration added in Task 3, prepend a drag handle inside the block. Find the block tile:

```heex
              <div class={"codeome-block codeome-block-editable op op-" <> Atom.to_string(Disassembler.opcode_class(opcode))}>
                <span class="codeome-block-idx">
```

Insert a drag handle as the first child:

```heex
              <div
                class={"codeome-block codeome-block-editable op op-" <> Atom.to_string(Disassembler.opcode_class(opcode))}
                data-idx={idx}
              >
                <span class="codeome-drag-handle" title="Drag to reorder">≡</span>
                <span class="codeome-block-idx">
```

Now add `phx-hook="CodeomeSortable"` to the `<div class="codeome-blocks">` that wraps the iteration. Find this line (in the edit-mode branch):

```heex
        <div class="codeome-blocks">
          <%= if @edit_mode do %>
```

Replace with:

```heex
        <div
          class="codeome-blocks"
          id={"codeome-blocks-#{@selected_hash}"}
          phx-hook={@edit_mode && "CodeomeSortable"}
          phx-update={@edit_mode && "ignore" || nil}
        >
          <%= if @edit_mode do %>
```

The `phx-update="ignore"` is needed because SortableJS may have already moved the DOM by the time the LiveView diff arrives; we let SortableJS own the DOM ordering and trust the server-side `:buffer` assign to be consistent on the next re-render via id change. The id includes `@selected_hash` so switching species forces a re-mount.

Wait — `phx-update="ignore"` on the wrapper would also block legitimate re-renders triggered by edit_insert / edit_delete / edit_replace. We do NOT want that. Drop `phx-update="ignore"` and instead let LiveView's morphdom do its job — SortableJS's animations will be brief and morphdom will reconcile. Update the markup to:

```heex
        <div
          class="codeome-blocks"
          id={"codeome-blocks-#{@selected_hash}"}
          phx-hook={@edit_mode && "CodeomeSortable"}
        >
```

If during manual smoke-testing it turns out morphdom + Sortable conflict (e.g., flicker on drop), add `phx-update="ignore"` and accept that insert/delete will need a one-character id-cycle workaround.

- [ ] **Step 5: Add CSS for the drag handle and the ghost class**

Append to `assets/css/app.css`:

```css
.lenies-dashboard .codeome-drag-handle {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 12px;
  height: 12px;
  margin-right: 4px;
  opacity: 0.4;
  cursor: grab;
  user-select: none;
}

.lenies-dashboard .codeome-drag-handle:hover {
  opacity: 1;
  color: #22d3ee;
}

.lenies-dashboard .codeome-block-ghost {
  opacity: 0.35;
  background: rgba(34, 211, 238, 0.2) !important;
}
```

- [ ] **Step 6: Add an `edit_reorder` handler in the component**

After the existing `edit_delete` / `picker_choose` handlers, add:

```elixir
  def handle_event("edit_reorder", %{"from" => from, "to" => to}, socket) do
    new_buffer = LeniesWeb.CodeomeBuffer.move(socket.assigns.buffer, from, to)
    apply_buffer_change(socket, new_buffer)
  end
```

- [ ] **Step 7: Compile clean**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix compile --warnings-as-errors
```

Expected: clean.

- [ ] **Step 8: Run the test suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green. (The JS itself is not tested; existing tests must still pass.)

- [ ] **Step 9: Manual smoke check**

The dev server should be running. Open the dashboard, sterilize, spawn 1 MinimalReplicator, wait for it to populate the species table, click the species row, click Edit, drag a block, verify the order changes and the buffer is updated server-side (you can confirm by clicking ⨯ on the moved block — it should remove the right one).

- [ ] **Step 10: Commit**

```bash
git add assets/vendor/sortable.js \
        assets/js/hooks/codeome_sortable.js \
        assets/js/app.js \
        lib/lenies_web/live/species_inspector_component.ex \
        assets/css/app.css
git commit -m "feat: drag-and-drop reorder via vendored SortableJS"
```

---

## Task 7: ConfirmAction hook + dirty notification + row confirm

**Files:**
- Create: `assets/js/hooks/confirm_action.js`
- Modify: `assets/js/app.js`
- Modify: `lib/lenies_web/live/dashboard_live.ex`
- Modify: `lib/lenies_web/live/species_inspector_component.ex`
- Modify: `test/lenies_web/live/dashboard_live_test.exs`

The component sends `{:inspector_dirty, bool}` to the parent (already wired in Task 2 via `notify_parent_dirty/2`). The dashboard receives it, tracks `:inspector_dirty`, and decorates the species rows + the inspector close button + Cancel with a `data-confirm` attribute that the `ConfirmAction` hook intercepts.

- [ ] **Step 1: Write the failing tests**

Append to `test/lenies_web/live/dashboard_live_test.exs` inside the existing module:

```elixir
  describe "inspector dirty notification" do
    test "dashboard receives :inspector_dirty info messages and assigns it", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      # Send the message directly to the LiveView pid
      send(view.pid, {:inspector_dirty, true})

      # Pull HTML to flush
      html = render(view)
      # When dirty, every species row should carry data-confirm
      # (even if there are no rows yet, we just check the assign is reflected
      # somewhere — easiest: in the body class via @inspector_dirty)
      assert html =~ ~s(data-inspector-dirty="true")

      send(view.pid, {:inspector_dirty, false})
      html2 = render(view)
      refute html2 =~ ~s(data-inspector-dirty="true")
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/dashboard_live_test.exs
```

Expected: failures — the assign isn't tracked yet.

- [ ] **Step 3: Track `:inspector_dirty` on the dashboard**

In `lib/lenies_web/live/dashboard_live.ex` `mount/3`, add to the assign chain:

```elixir
      |> assign(:inspector_dirty, false)
```

After the existing `handle_info/2` clauses, add:

```elixir
  def handle_info({:inspector_dirty, dirty}, socket) do
    {:noreply, assign(socket, :inspector_dirty, dirty)}
  end
```

- [ ] **Step 4: Reflect `:inspector_dirty` in the rendered DOM**

In the dashboard render, find the outer `<div class="lenies-dashboard …">` and add a data attribute:

```heex
    <div
      class="lenies-dashboard h-screen w-screen overflow-hidden flex flex-col p-3 gap-3"
      data-inspector-dirty={if @inspector_dirty, do: "true", else: nil}
    >
```

- [ ] **Step 5: Create the ConfirmAction hook**

`assets/js/hooks/confirm_action.js`:

```javascript
// ConfirmAction hook: when the element is clicked, fires window.confirm
// using the message from `data-confirm`. If the user cancels, stops the
// event so Phoenix LiveView's phx-click does not fire.
//
// The confirm only fires when the conditional source (the ancestor element
// with data-inspector-dirty="true") is dirty. Configure via the
// `data-confirm-when` attribute, which is a CSS selector for the source.
//
// Usage:
//   <tr phx-click="select_species"
//       phx-hook="ConfirmAction"
//       data-confirm="Discard codeome edits?"
//       data-confirm-when="[data-inspector-dirty='true']">
//     ...
//   </tr>

const ConfirmAction = {
  mounted() {
    this.handler = (e) => {
      const message = this.el.dataset.confirm;
      if (!message) return;

      const selector = this.el.dataset.confirmWhen;
      if (selector) {
        const source = document.querySelector(selector);
        if (!source) return; // condition not met — let click through
      }

      if (!window.confirm(message)) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    };

    // Capture phase so we run before Phoenix's listener.
    this.el.addEventListener("click", this.handler, true);
  },

  destroyed() {
    if (this.handler) {
      this.el.removeEventListener("click", this.handler, true);
    }
  },
};

export default ConfirmAction;
```

- [ ] **Step 6: Register the hook in `app.js`**

In `assets/js/app.js`, add the import and the registration:

```javascript
import GridCanvas from "./hooks/grid_canvas"
import ActionFeedback from "./hooks/action_feedback"
import CodeomeSortable from "./hooks/codeome_sortable"
import ConfirmAction from "./hooks/confirm_action"

const Hooks = {GridCanvas, ActionFeedback, CodeomeSortable, ConfirmAction, ...colocatedHooks}
```

- [ ] **Step 7: Wire ConfirmAction on the species table rows**

In `lib/lenies_web/live/dashboard_live.ex`, find the `<tr>` block inside the species table:

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
```

Add the hook and confirm attributes:

```heex
                    <%= for sp <- @species do %>
                      <tr
                        class={[
                          "hover:bg-cyan-500/10 cursor-pointer",
                          @selected_hash == sp.hash && "bg-cyan-500/20 ring-1 ring-cyan-400"
                        ]}
                        id={"species-row-#{sp.hash}"}
                        phx-hook="ConfirmAction"
                        data-confirm="Discard codeome edits?"
                        data-confirm-when="[data-inspector-dirty='true']"
                        phx-click="select_species"
                        phx-value-hash={sp.hash}
                      >
```

The `id` is required because Phoenix LiveView's hooks need a stable id on the element.

- [ ] **Step 8: Wire ConfirmAction on the inspector close `×` and Cancel buttons**

In `lib/lenies_web/live/species_inspector_component.ex`, find the close button in the header:

```heex
        <button
          phx-click="select_species"
          phx-value-hash={@selected_hash}
          class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
        >
          ×
        </button>
```

Replace with:

```heex
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
```

Find the Cancel button in the toolbar (added in Task 2) and replace with:

```heex
          <button
            id={"inspector-cancel-#{@selected_hash}"}
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
```

- [ ] **Step 9: Run the test suite**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test
```

Expected: green. The new dashboard test asserts the `data-inspector-dirty` attribute flips.

- [ ] **Step 10: Manual smoke check**

In the browser:
1. Sterilize, spawn 1 MinimalReplicator, wait, click the row, Edit, delete a block. The toolbar shows `●dirty`.
2. Click another species row → `window.confirm` fires with "Discard codeome edits?".
3. Click Cancel → confirm fires too.
4. Click × → confirm fires.
5. Reload the page, do the same dirty edit, click on the same row again — the row is still selectable but the confirm fires because the dirty bit is set.

Note: the confirm fires on EVERY click while dirty, including re-clicks on the selected row (which is the toggle-to-deselect path). This is acceptable behavior — selecting the same row again does discard the buffer too.

- [ ] **Step 11: Commit**

```bash
git add assets/js/hooks/confirm_action.js \
        assets/js/app.js \
        lib/lenies_web/live/dashboard_live.ex \
        lib/lenies_web/live/species_inspector_component.ex \
        test/lenies_web/live/dashboard_live_test.exs
git commit -m "feat: discard-on-dirty confirm prompts via ConfirmAction hook"
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

- [ ] **Step 3: Manual end-to-end browser walkthrough**

In the dev browser, do the full happy path:
1. Sterilize and spawn 20 MinimalReplicator. Wait for the species table to populate.
2. Click a species row — inspector opens (Phase B).
3. Block view is rendered (Phase C1).
4. Click Edit — toolbar shows Cancel + Spawn buttons; validation status shows valid; blocks now show drag handles and hover-action buttons.
5. Hover between two blocks → `+` appears → click → picker opens → click an opcode of a different category (e.g. an `attack` from predation) → block inserts at that position with the right color. Toolbar shows `●dirty`.
6. Click `↺` on the inserted block → picker opens → click a different opcode → block replaces.
7. Click `⨯` on a block → it removes. Validation status updates.
8. Drag a block via the `≡` handle → list reorders.
9. Delete enough blocks until validation goes red → Spawn button disables.
10. Re-insert blocks until validation goes green → Spawn button enables.
11. Click Spawn → form opens → enter count 5 → click Spawn → 5 lenies appear in the world canvas with the edited codeome's hue (different from the source species since the codeome differs).
12. Click another species row → window.confirm fires. Click OK → inspector switches to the new species, buffer is discarded.
13. Click Edit on the new species → modify → click Cancel → confirm fires → buffer cleared, edit mode off.
14. Modify, click × in inspector header → confirm fires → inspector closes.

If all 14 steps work, C2 is shipped.
