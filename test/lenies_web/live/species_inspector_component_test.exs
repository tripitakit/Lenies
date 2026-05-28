defmodule LeniesWeb.SpeciesInspectorComponentTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias LeniesWeb.SpeciesInspectorComponent

  setup do
    case Process.whereis(Lenies.Registry) do
      nil -> {:ok, _} = Registry.start_link(keys: :unique, name: Lenies.Registry)
      _ -> :ok
    end

    {:ok, _} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})
    on_exit(fn -> Lenies.WorldTestHelpers.stop_primary() end)
    :ok
  end

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        id: "test-inspector",
        selected_hash: "abc12345abc12345",
        species_record: %{hash: "abc12345abc12345", population: 7, avg_generation: 3.5},
        world_handle: Lenies.Worlds.primary_handle()
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

    test "close × has NO data-confirm attribute (read-only inspector cannot be dirty)" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      refute html =~ "Discard codeome edits?"
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
      assert html =~ "No live Lenie"
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

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"TEST-INSP-L1", %{id: "TEST-INSP-L1", codeome_hash: hash}}
      )

      record = %{hash: hash, population: 1, avg_generation: 0.0}

      html =
        render_component(SpeciesInspectorComponent, %{
          id: "live-inspector",
          selected_hash: hash,
          species_record: record,
          world_handle: Lenies.Worlds.primary_handle()
        })

      # MinimalReplicator starts with the LOOP_HEAD anchor (four :nop_1)
      assert html =~ "op-template"
      assert html =~ ~r/nop_1/i
      # And it contains :get_size (self-inspect category)
      assert html =~ "op-self_inspect"
      assert html =~ ~r/get_size/i
      refute html =~ "No live Lenie"
    end

    test "renders codeome lines as block tiles with the codeome-blocks container" do
      codeome = Lenies.Codeomes.MinimalReplicator.codeome()
      hash = Lenies.Codeome.hash(codeome)

      {:ok, _pid} =
        Lenies.Lenie.start_link(
          id: "TEST-BLOCK-L1",
          codeome: codeome,
          energy: 100.0,
          pos: {0, 0},
          dir: :n,
          lineage: {nil, 0}
        )

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"TEST-BLOCK-L1", %{id: "TEST-BLOCK-L1", codeome_hash: hash}}
      )

      html =
        render_component(SpeciesInspectorComponent, %{
          id: "block-inspector",
          selected_hash: hash,
          species_record: %{hash: hash, population: 1, avg_generation: 0.0},
          world_handle: Lenies.Worlds.primary_handle()
        })

      assert html =~ ~s(class="codeome-blocks")
      assert html =~ "codeome-block op op-template"
      assert html =~ ~s(class="codeome-block-idx")
      assert html =~ ~s(class="codeome-block-name")
    end
  end

  describe "edit link" do
    test "Edit link visible in read mode and navigates to /editor/edit/:hash" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      assert html =~ ~s(href="/editor/edit/abc12345abc12345")
      refute html =~ ~s(phx-click="enter_edit")
    end

    test "the toolbar has the Edit link but no Cancel button (no in-place edit mode)" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      assert html =~ "Edit"
      refute html =~ ~s(>Cancel<)
    end

    test "in read mode, action buttons (delete, etc.) are absent" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      refute html =~ ~s(phx-click="edit_delete")
      refute html =~ ~s(phx-click="edit_insert")
      refute html =~ ~s(phx-click="edit_reorder")
    end

    test "in read mode, the palette is NOT rendered" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      refute html =~ ~s(id="palette-grid")
      refute html =~ ~s(phx-hook="CodeomePalette")
    end
  end
end
