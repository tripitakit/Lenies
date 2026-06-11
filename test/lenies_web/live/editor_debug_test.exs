defmodule LeniesWeb.EditorDebugTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    :ok = Lenies.Sandboxes.attach(user.id)
    world_id = {:sandbox, user.id}
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    :ok = Lenies.Worlds.pause(world_id)

    case Process.whereis(Lenies.Manual) do
      nil -> {:ok, _} = Lenies.Manual.start_link([])
      _ -> :ok
    end

    case Process.whereis(Lenies.Snippets.Store) do
      nil -> {:ok, _} = Lenies.Snippets.Store.start_link([])
      _ -> :ok
    end

    on_exit(fn -> Lenies.Worlds.stop_world(world_id) end)
    %{world_id: world_id, handle: handle}
  end

  # >= 10 non-nop opcodes so the genome validates (test config sets
  # min_viable_codeome_opcodes: 10); each op advances ip by 1 per step.
  defp seed_valid_buffer(view) do
    render_submit(view, "submit_opcode_text", %{
      "opcodes" => "eat move eat move eat move eat move push0 push1"
    })
  end

  describe "transport & session lifecycle" do
    test "step creates a session lazily and advances ip", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      seed_valid_buffer(view)

      render_click(view, "stepper_step", %{})
      html = render(view)
      assert html =~ "Step #1"
      # Debug tab auto-activated, inspector visible
      assert html =~ "Slots"
    end

    test "transport is disabled while the genome is invalid", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      assert has_element?(view, "button[phx-click='stepper_step'][disabled]")
    end

    test "stop clears the session", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      seed_valid_buffer(view)
      render_click(view, "stepper_step", %{})
      render_click(view, "stepper_stop", %{})

      assert render(view) =~ "No active debug session"
    end

    test "reset returns to step 0 keeping the session", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      seed_valid_buffer(view)
      render_click(view, "stepper_step", %{})
      render_click(view, "stepper_step", %{})
      render_click(view, "stepper_reset", %{})

      assert render(view) =~ "Step #0"
    end

    test "run loop ticks via handle_info and pauses", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      seed_valid_buffer(view)

      render_click(view, "stepper_run", %{})
      assert render(view) =~ "Pause"

      render_click(view, "stepper_pause", %{})
      assert render(view) =~ "Run"
    end
  end

  describe "listing overlay & hot-restart" do
    test "the IP row is highlighted in the central listing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      seed_valid_buffer(view)
      render_click(view, "stepper_step", %{})

      assert has_element?(view, "#codeome-blocks-chromosome [data-flat='1'].codeome-block-ip")
      assert has_element?(view, "[data-current='true']")
    end

    test "breakpoint toggles on a listing row (flat ip)", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      seed_valid_buffer(view)
      # session needed so the listing rows carry the bp affordance / overlay
      render_click(view, "stepper_step", %{})
      render_click(view, "stepper_toggle_bp", %{"ip" => "2"})

      assert has_element?(view, "[data-flat='2'].codeome-block-bp")
    end

    test "editing the buffer hot-restarts: step 0, paused, breakpoints remapped", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      seed_valid_buffer(view)
      render_click(view, "stepper_step", %{})
      render_click(view, "stepper_step", %{})
      render_click(view, "stepper_toggle_bp", %{"ip" => "3"})

      # Insert one opcode at the chromosome head. GenomeBuffer.remap_breakpoints/3
      # anchors a breakpoint to its {section, index} ADDRESS (Task 2 contract),
      # so the chromosome bp at idx 3 stays at idx 3 = flat 3 (offset 0 is
      # unchanged by a chromosome-head insert; only displaced *sections* shift).
      render_click(view, "place_caret", %{"section" => "chromosome", "gap" => 0})
      render_submit(view, "submit_opcode_text", %{"opcodes" => "push0"})

      html = render(view)
      # hot-restart: paused at step 0, never resumed RUN
      assert html =~ "Step #0"
      refute html =~ "Pause"
      # the breakpoint survived the remap, still anchored at its address (flat 3)
      assert has_element?(view, "[data-flat='3'].codeome-block-bp")
    end

    test "an edit that makes the genome invalid tears the session down with a notice", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      seed_valid_buffer(view)
      render_click(view, "stepper_step", %{})

      # select the whole 10-op chromosome and delete -> invalid (too short)
      render_click(view, "place_caret", %{"section" => "chromosome", "gap" => 0})

      render_click(view, "place_caret", %{"section" => "chromosome", "gap" => 10, "shift" => true})

      render_click(view, "delete_selection", %{})

      html = render(view)
      assert html =~ "Debug session ended: the genome is no longer valid"
      assert html =~ "No active debug session"
    end

    test "breakpoint banner shows when RUN hits a breakpoint", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
      seed_valid_buffer(view)

      # step once to create the session (ip -> 1), then arm a bp at ip 2
      render_click(view, "stepper_step", %{})
      render_click(view, "stepper_toggle_bp", %{"ip" => "2"})
      render_click(view, "stepper_run", %{})

      # stepper_run sends {:stepper_tick, gen} to self(); render/1 is a call,
      # queued AFTER that message, so the first tick (ip 1 -> 2, bp hit) has
      # been processed by the time render returns. Deterministic, no sleep.
      assert render(view) =~ "Stopped at breakpoint @ ip 2"
    end

    test "{:tail, extra} path: make_plasmid grows exec_codeome, runtime-tail divider appears",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

      # Chromosome: push0 (start_addr=0), push1 (length=1), make_plasmid,
      # then 8 more non-nop ops to hit the 10 non-nop minimum for validation.
      # After step 3 (ip 0→1→2→3) make_plasmid fires: it copies 1 opcode
      # (push0 at addr 0) into a new plasmid and appends it to interp.plasmids.
      # rebuilt_exec then rebuilds exec_codeome = chromosome(11) + plasmid(1),
      # which is strictly longer than the authored exec list (11 ops, no
      # authored plasmids), so debug_overlay/1 returns {:tail, extra} and the
      # runtime-plasmids divider is rendered.
      render_submit(view, "submit_opcode_text", %{
        "opcodes" => "push0 push1 make_plasmid eat move eat move eat move eat move"
      })

      # Three steps bring ip to 3 (make_plasmid has executed at ip=2).
      render_click(view, "stepper_step", %{})
      render_click(view, "stepper_step", %{})
      render_click(view, "stepper_step", %{})

      html = render(view)
      assert html =~ "runtime plasmids (read-only)"
    end
  end
end
