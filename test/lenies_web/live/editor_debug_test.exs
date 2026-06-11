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
end
