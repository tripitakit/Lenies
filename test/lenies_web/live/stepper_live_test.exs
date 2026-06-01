defmodule LeniesWeb.StepperLiveTest do
  use LeniesWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    :ok = Lenies.Sandboxes.attach(user.id)
    world_id = {:sandbox, user.id}
    {:ok, _handle} = Lenies.Worlds.handle(world_id)
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
    %{world_id: world_id}
  end

  defp populate_buffer(view) do
    view
    |> element("form[phx-submit='submit_opcode_text']")
    |> render_submit(%{"opcodes" => "push1 dup add push0 push1 push0 push1 push0 push1 push0"})
  end

  test "Debug button is visible on the editor", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sandbox/editor/new")
    assert html =~ "🐞 Debug"
  end

  test "clicking Debug opens the stepper modal with all 5 panels", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
    populate_buffer(view)

    html = view |> element("button", "🐞 Debug") |> render_click()

    assert html =~ "Codeome Stepper"
    assert html =~ "Step #0"
    assert html =~ ~s(class="stepper-panel-title")
    assert html =~ "State"
    assert html =~ "Stack"
    assert html =~ "Slots"
    assert html =~ "Call stack"
    assert html =~ "Codeome ("
  end

  test "click Step advances IP", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
    populate_buffer(view)
    view |> element("button", "🐞 Debug") |> render_click()

    html = view |> element("button", "▶ Step") |> render_click()

    assert html =~ "Step #1"
  end

  test "click on codeome row toggles a breakpoint", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
    populate_buffer(view)
    view |> element("button", "🐞 Debug") |> render_click()

    html = view |> element(".stepper-codeome-row[phx-value-ip='3']") |> render_click()

    assert html =~ "stepper-codeome-bp"
  end

  test "click ✕ closes the modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
    populate_buffer(view)
    view |> element("button", "🐞 Debug") |> render_click()

    view |> element("button.stepper-close") |> render_click()
    # The component sends an info message to the parent LiveView; re-render
    # after the message is processed to observe the updated state.
    html = render(view)
    refute html =~ "Codeome Stepper"
  end

  test "selecting a built-in seed enters place-seed mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
    populate_buffer(view)
    view |> element("button", "🐞 Debug") |> render_click()

    html =
      view
      |> element("select[phx-change='select_seed']")
      |> render_change(%{"value" => "builtin:minimal_replicator"})

    assert html =~ "click on the canvas"
  end

  test "selecting (none) exits place-seed mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/editor/new")
    populate_buffer(view)
    view |> element("button", "🐞 Debug") |> render_click()

    view
    |> element("select[phx-change='select_seed']")
    |> render_change(%{"value" => "builtin:minimal_replicator"})

    html =
      view
      |> element("select[phx-change='select_seed']")
      |> render_change(%{"value" => ""})

    refute html =~ "click on the canvas"
  end
end
