defmodule LeniesWeb.StepperRunLoopTest do
  @moduledoc "Regression tests for the stepper RUN loop (single-loop guarantee)."
  use LeniesWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # A flooding regression (concurrent loops) makes the LiveView unresponsive;
  # cap the timeout so it fails fast instead of hanging for the default 60s.
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

  defp sc(view), do: Regex.run(~r/Step #(\d+)/, render(view)) |> Enum.at(1) |> String.to_integer()

  defp set_speed(view, s),
    do: view |> element("form.stepper-speed-form") |> render_change(%{"value" => to_string(s)})

  defp run(view), do: view |> element("button[phx-click='run']") |> render_click()
  defp pause(view), do: view |> element("button[phx-click='pause']") |> render_click()
  defp reset(view), do: view |> element("button[phx-click='reset']") |> render_click()

  defp open_stepper(conn, n_ops) do
    {:ok, view, _} = live(conn, ~p"/sandbox/editor/new")
    ops = List.duplicate("nop_0", n_ops) |> Enum.join(" ")
    view |> element("form[phx-submit='submit_opcode_text']") |> render_submit(%{"opcodes" => ops})
    view |> element("button", "Debug") |> render_click()
    view
  end

  test "the speed slider controls the RUN rate", %{conn: conn} do
    view = open_stepper(conn, 300)

    # 250ms delay
    set_speed(view, 4)
    run(view)
    # let the immediate tick settle
    Process.sleep(60)
    c0 = sc(view)
    Process.sleep(800)
    pause(view)
    slow = sc(view) - c0

    reset(view)

    # 25ms delay
    set_speed(view, 40)
    run(view)
    Process.sleep(60)
    d0 = sc(view)
    Process.sleep(800)
    pause(view)
    fast = sc(view) - d0

    assert slow <= 8, "slow loop ran #{slow} steps in 800ms (~3 expected at 4/s)"
    assert fast >= 20, "fast loop ran only #{fast} steps in 800ms (~32 expected at 40/s)"
    assert fast >= slow * 3, "slider had little effect: slow=#{slow} fast=#{fast}"
  end

  test "pause/run cycling with speed changes does not accumulate loops (stays responsive)",
       %{conn: conn} do
    view = open_stepper(conn, 300)

    # Mixed-cadence provocation: several slow runs leave long-lived timers, then a
    # fast run. Pre-fix this spawned parallel loops that flooded the LiveView and
    # made the trailing pause() time out (test hangs/fails).
    for _ <- 1..3 do
      set_speed(view, 2)
      run(view)
      Process.sleep(60)
      pause(view)
      Process.sleep(30)
    end

    reset(view)
    # 20ms delay
    set_speed(view, 50)
    run(view)
    Process.sleep(700)
    # must return promptly (single loop, not flooded)
    pause(view)
    n = sc(view)

    # A single 50/s loop over ~700ms is ~35 steps; many parallel loops are far more.
    assert n <= 80, "expected one loop (~35 steps), got #{n} — loops are accumulating"
  end
end
