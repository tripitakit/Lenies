defmodule LeniesWeb.StepperExecCodeomeTest do
  use LeniesWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @moduletag timeout: 20_000

  # Re-covered by editor_debug_test.exs in the unification plan (Task 8); file deleted in Task 10.
  @moduletag :skip

  setup :register_and_log_in_user

  setup %{user: user} do
    :ok = Lenies.Sandboxes.attach(user.id)
    world_id = {:sandbox, user.id}
    {:ok, _h} = Lenies.Worlds.handle(world_id)
    :ok = Lenies.Worlds.pause(world_id)

    for mod <- [Lenies.Manual, Lenies.Snippets.Store] do
      if Process.whereis(mod) == nil, do: {:ok, _} = mod.start_link([])
    end

    on_exit(fn -> Lenies.Worlds.stop_world(world_id) end)
    :ok
  end

  test "a self-made plasmid renders a separator row in the disassembly", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")

    ops = "push0 push1 push1 add make_plasmid nop_0"
    view |> element("form[phx-submit='submit_opcode_text']") |> render_submit(%{"opcodes" => ops})
    view |> element("button", "Debug") |> render_click()

    refute render(view) =~ "stepper-codeome-divider"

    for _ <- 1..5, do: view |> element("button[phx-click='step']") |> render_click()

    html = render(view)
    assert html =~ "stepper-codeome-divider"
    assert html =~ "plasmid"
  end
end
