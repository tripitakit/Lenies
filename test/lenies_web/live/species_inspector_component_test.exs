defmodule LeniesWeb.SpeciesInspectorComponentTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias LeniesWeb.SpeciesInspectorComponent

  setup do
    case Process.whereis(Lenies.Registry) do
      nil -> {:ok, _} = Registry.start_link(keys: :unique, name: Lenies.Registry)
      _ -> :ok
    end

    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id, handle: handle}
  end

  defp base_assigns(handle, overrides \\ %{}) do
    Map.merge(
      %{
        id: "test-inspector",
        selected_hash: "abc12345abc12345",
        species_record: %{hash: "abc12345abc12345", population: 7, avg_generation: 3.5},
        world_handle: handle
      },
      overrides
    )
  end

  describe "header" do
    test "renders the hash truncated with trailing ellipsis", %{handle: handle} do
      html = render_component(SpeciesInspectorComponent, base_assigns(handle))
      assert html =~ "abc12345abc1234"
      assert html =~ "…"
    end

    test "no longer links to the removed standalone species page", %{handle: handle} do
      html = render_component(SpeciesInspectorComponent, base_assigns(handle))
      refute html =~ "/sandbox/species/"
    end

    test "renders a labelled Kill button with no browser data-confirm", %{handle: handle} do
      html = render_component(SpeciesInspectorComponent, base_assigns(handle))
      assert html =~ ~s(phx-click="kill_init")
      assert html =~ "Kill"
      refute html =~ "All its living Lenies will be removed."
    end

    test "renders the close button targeting the selected hash", %{handle: handle} do
      html = render_component(SpeciesInspectorComponent, base_assigns(handle))
      assert html =~ ~s(phx-click="select_species")
      assert html =~ ~s(phx-value-hash="abc12345abc12345")
    end

    test "close × has NO data-confirm attribute (read-only inspector cannot be dirty)",
         %{handle: handle} do
      html = render_component(SpeciesInspectorComponent, base_assigns(handle))
      refute html =~ "Discard codeome edits?"
    end
  end

  describe "stats" do
    test "renders population and avg_generation from species_record", %{handle: handle} do
      record = %{hash: "abc12345abc12345", population: 12, avg_generation: 2.25}

      html =
        render_component(
          SpeciesInspectorComponent,
          base_assigns(handle, %{species_record: record})
        )

      assert html =~ ~r/>\s*12\s*</
      assert html =~ ~r/>\s*2\.25\s*</
    end

    test "handles an extinct species_record (population 0) without crashing",
         %{handle: handle} do
      record = %{hash: "abc12345abc12345", population: 0, avg_generation: 0.0}

      html =
        render_component(
          SpeciesInspectorComponent,
          base_assigns(handle, %{species_record: record})
        )

      assert html =~ ~r/>\s*0\s*</
    end
  end

  describe "fetch behavior" do
    test "no Lenie of the selected species → no-sample notice, zero opcode count",
         %{handle: handle} do
      html = render_component(SpeciesInspectorComponent, base_assigns(handle))
      assert html =~ "No live Lenie"
      assert html =~ ~r/ops.*?>\s*0\s*</s
    end

    test "with a live Lenie of the species, fetches and disassembles its codeome",
         %{world_id: world_id, handle: handle} do
      codeome = Lenies.Codeomes.MinimalReplicator.codeome()
      hash = Lenies.Codeome.hash(codeome)

      {:ok, _pid} =
        Lenies.Lenie.start_link(
          {handle,
           [
             id: "TEST-INSP-L1",
             codeome: codeome,
             energy: 100.0,
             pos: {0, 0},
             dir: :n,
             lineage: {nil, 0}
           ]}
        )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(world_id),
        {"TEST-INSP-L1", %{id: "TEST-INSP-L1", codeome_hash: hash}}
      )

      record = %{hash: hash, population: 1, avg_generation: 0.0}

      html =
        render_component(SpeciesInspectorComponent, %{
          id: "live-inspector",
          selected_hash: hash,
          species_record: record,
          world_handle: handle
        })

      # MinimalReplicator starts with the LOOP_HEAD anchor (four :nop_1)
      assert html =~ "op-template"
      assert html =~ ~r/nop_1/i
      # And it contains :get_size (self-inspect category)
      assert html =~ "op-self_inspect"
      assert html =~ ~r/get_size/i
      refute html =~ "No live Lenie"
    end

    test "renders codeome lines as block tiles with the codeome-blocks container",
         %{world_id: world_id, handle: handle} do
      codeome = Lenies.Codeomes.MinimalReplicator.codeome()
      hash = Lenies.Codeome.hash(codeome)

      {:ok, _pid} =
        Lenies.Lenie.start_link(
          {handle,
           [
             id: "TEST-BLOCK-L1",
             codeome: codeome,
             energy: 100.0,
             pos: {0, 0},
             dir: :n,
             lineage: {nil, 0}
           ]}
        )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(world_id),
        {"TEST-BLOCK-L1", %{id: "TEST-BLOCK-L1", codeome_hash: hash}}
      )

      html =
        render_component(SpeciesInspectorComponent, %{
          id: "block-inspector",
          selected_hash: hash,
          species_record: %{hash: hash, population: 1, avg_generation: 0.0},
          world_handle: handle
        })

      assert html =~ ~s(class="codeome-blocks")
      assert html =~ "codeome-block op op-template"
      assert html =~ ~s(class="codeome-block-idx")
      assert html =~ ~s(class="codeome-block-name")
    end
  end

  describe "edit link" do
    test "Edit link visible in read mode and navigates to /sandbox/editor/edit/:hash",
         %{handle: handle} do
      html = render_component(SpeciesInspectorComponent, base_assigns(handle))
      assert html =~ ~s(href="/sandbox/editor/edit/abc12345abc12345")
      refute html =~ ~s(phx-click="enter_edit")
    end

    test "the toolbar has the Edit link but no Cancel button (no in-place edit mode)",
         %{handle: handle} do
      html = render_component(SpeciesInspectorComponent, base_assigns(handle))
      assert html =~ "Edit"
      refute html =~ ~s(>Cancel<)
    end

    test "in read mode, action buttons (delete, etc.) are absent", %{handle: handle} do
      html = render_component(SpeciesInspectorComponent, base_assigns(handle))
      refute html =~ ~s(phx-click="edit_delete")
      refute html =~ ~s(phx-click="edit_insert")
      refute html =~ ~s(phx-click="edit_reorder")
    end

    test "in read mode, the palette is NOT rendered", %{handle: handle} do
      html = render_component(SpeciesInspectorComponent, base_assigns(handle))
      refute html =~ ~s(id="palette-grid")
      refute html =~ ~s(phx-hook="CodeomePalette")
    end
  end
end
