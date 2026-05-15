defmodule LeniesWeb.SpeciesInspectorComponentTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias LeniesWeb.SpeciesInspectorComponent

  setup do
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

      Lenies.World.Tables.delete_all()
    end)

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
