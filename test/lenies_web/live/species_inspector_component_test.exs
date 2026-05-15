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

  # Render the component with a seeded assigns map directly via the
  # component's render/1 function, bypassing render_component/2 (which
  # would invoke mount/1 and update/2 and reset the edit-mode state).
  # Used by edit-mode tests that need to inject pre-edit state without
  # going through enter_edit.
  defp render_seeded(base, opts) do
    assigns =
      Map.merge(base, Map.new(opts))
      |> Map.put_new(:codeome_lines, [])
      |> Map.put_new(:fetch_status, :ok)
      |> Map.put_new(:cached_codeome_hash, base[:selected_hash])
      |> Map.put_new(:edit_mode, false)
      |> Map.put_new(:buffer, [])
      |> Map.put_new(:dirty, false)
      |> Map.put_new(:picker_open, nil)
      |> Map.put_new(:validation, {:ok, %{len: 0, non_nops: 0}})
      |> Map.put_new(:show_spawn_form, false)
      # render/1 also needs the LiveComponent target marker
      |> Map.put_new(:myself, %Phoenix.LiveComponent.CID{cid: 0})

    SpeciesInspectorComponent.render(assigns)
    |> Phoenix.LiveViewTest.rendered_to_string()
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
      assert html =~ ~r/nop_1/i
      # And it contains :get_size (self-inspect category)
      assert html =~ "op-self_inspect"
      assert html =~ ~r/get_size/i
      refute html =~ "Nessun Lenie vivo"
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

      :ets.insert(:lenies, {"TEST-BLOCK-L1", %{id: "TEST-BLOCK-L1", codeome_hash: hash}})

      html =
        render_component(SpeciesInspectorComponent, %{
          id: "block-inspector",
          selected_hash: hash,
          species_record: %{hash: hash, population: 1, avg_generation: 0.0}
        })

      assert html =~ ~s(class="codeome-blocks")
      assert html =~ "codeome-block op op-template"
      assert html =~ ~s(class="codeome-block-idx")
      assert html =~ ~s(class="codeome-block-name")
    end
  end

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

    test "enter_edit populates the buffer with the current codeome opcodes" do
      codeome_lines = [
        %{index: 0, opcode: :nop_1, is_current: false},
        %{index: 1, opcode: :push0, is_current: false}
      ]

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          codeome_lines: codeome_lines,
          edit_mode: false,
          buffer: [],
          dirty: false
        }
      }

      {:noreply, new_socket} =
        SpeciesInspectorComponent.handle_event("enter_edit", %{}, socket)

      assert new_socket.assigns.edit_mode == true
      assert new_socket.assigns.buffer == [:nop_1, :push0]
      assert new_socket.assigns.dirty == false
    end
  end

  describe "edit operations" do
    test "in edit mode, each block has delete and replace buttons" do
      html = render_seeded(base_assigns(), edit_mode: true, buffer: [:push0, :push1, :store])

      assert html =~ ~s(phx-click="edit_delete")
      assert html =~ ~s(phx-click="open_picker")
    end

    test "in edit mode, insert affordances exist between blocks" do
      html = render_seeded(base_assigns(), edit_mode: true, buffer: [:push0, :push1, :store])
      assert html =~ "codeome-insert-slot"
    end

    test "in read mode, action buttons are absent" do
      html = render_component(SpeciesInspectorComponent, base_assigns())
      refute html =~ ~s(phx-click="edit_delete")
      refute html =~ ~s(phx-click="open_picker")
      refute html =~ "codeome-insert-slot"
    end

    test "the picker is hidden by default in edit mode" do
      html = render_seeded(base_assigns(), edit_mode: true, buffer: [:push0, :push1, :store])
      refute html =~ "codeome-picker"
    end

    test "the picker is rendered when picker_open is set" do
      html =
        render_seeded(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push1, :store],
          picker_open: %{index: 1, mode: :insert}
        )

      assert html =~ "codeome-picker"
      assert html =~ "stack"
      assert html =~ ~s(phx-click="picker_choose")
    end
  end

  describe "live validation" do
    setup do
      original_bounds = Application.get_env(:lenies, :codeome_length_bounds)
      original_min_non_nops = Application.get_env(:lenies, :min_viable_codeome_opcodes)

      Application.put_env(:lenies, :codeome_length_bounds, {5, 500})
      Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)

      on_exit(fn ->
        if original_bounds do
          Application.put_env(:lenies, :codeome_length_bounds, original_bounds)
        else
          Application.delete_env(:lenies, :codeome_length_bounds)
        end

        if original_min_non_nops do
          Application.put_env(:lenies, :min_viable_codeome_opcodes, original_min_non_nops)
        else
          Application.delete_env(:lenies, :min_viable_codeome_opcodes)
        end
      end)

      :ok
    end

    test "ok validation status in edit mode for a long-enough buffer" do
      html =
        render_seeded(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}}
        )

      assert html =~ "valid"
      assert html =~ "6 ops"
    end

    test "error validation status when too short" do
      html =
        render_seeded(base_assigns(),
          edit_mode: true,
          buffer: [:push0],
          validation: {:error, [{:too_short, [min: 5, got: 1]}]}
        )

      assert html =~ "too short"
    end
  end

  describe "spawn flow" do
    test "Spawn button visible only in edit mode" do
      html_read = render_component(SpeciesInspectorComponent, base_assigns())
      refute html_read =~ ~s(>Spawn<)

      html_edit =
        render_seeded(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}}
        )

      assert html_edit =~ ~s(>Spawn<)
    end

    test "Spawn button is disabled when validation fails" do
      html =
        render_seeded(base_assigns(),
          edit_mode: true,
          buffer: [:push0],
          validation: {:error, [{:too_short, [min: 5, got: 1]}]}
        )

      assert html =~ ~r/<button[^>]*disabled[^>]*>\s*Spawn\s*</
    end

    test "Spawn form hidden by default and opens when show_spawn_form is true" do
      html_closed =
        render_seeded(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}}
        )

      refute html_closed =~ ~s(name="count")

      html_open =
        render_seeded(base_assigns(),
          edit_mode: true,
          buffer: [:push0, :push0, :push0, :push0, :push0, :store],
          validation: {:ok, %{len: 6, non_nops: 6}},
          show_spawn_form: true
        )

      assert html_open =~ ~s(name="count")
      assert html_open =~ ~s(name="energy")
    end
  end

  describe "edit_reorder handler" do
    test "moves a buffer item via CodeomeBuffer.move/3" do
      buffer = [:a, :b, :c, :d]

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          myself: %Phoenix.LiveComponent.CID{cid: 1},
          buffer: buffer,
          codeome_lines: [
            %{index: 0, opcode: :a, is_current: false},
            %{index: 1, opcode: :b, is_current: false},
            %{index: 2, opcode: :c, is_current: false},
            %{index: 3, opcode: :d, is_current: false}
          ],
          dirty: false,
          validation: {:ok, %{len: 4, non_nops: 4}}
        }
      }

      {:noreply, new_socket} =
        SpeciesInspectorComponent.handle_event(
          "edit_reorder",
          %{"from" => 0, "to" => 2},
          socket
        )

      assert new_socket.assigns.buffer == [:b, :c, :a, :d]
      assert new_socket.assigns.dirty == true
    end
  end

  describe "submit_spawn integration" do
    alias Lenies.World.Tables

    setup do
      # Tables may already exist if the outer setup created Lenies.World first.
      try do
        Tables.create_all()
      rescue
        ArgumentError -> :ok
      end

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

    test "submit_spawn calls Lenies.World.spawn_lenie/2 N times" do
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

      socket = %Phoenix.LiveView.Socket{
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

      {:noreply, _} =
        SpeciesInspectorComponent.handle_event(
          "submit_spawn",
          %{"count" => "3", "energy" => "10000"},
          socket
        )

      pop_after = :ets.info(:lenies, :size) || 0
      assert pop_after >= pop_before + 3
    end
  end
end
