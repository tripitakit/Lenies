defmodule Lenies.StepperRestartTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Stepper}

  defp codeome(ops), do: Codeome.from_list(ops)

  defp seed_map do
    %{codeome: codeome([:eat, :move, :eat, :move, :eat, :move, :eat, :move]), plasmids: []}
  end

  test "restart swaps the codeome and starts :ready at step 0" do
    session =
      Stepper.start_session(codeome([:push0, :add, :push0, :add, :push0, :add, :push0, :add]))

    {:ok, session} = Stepper.step(session)
    session = %{session | status: :running}

    new_ops = [:eat, :eat, :eat, :eat, :eat, :eat, :eat, :eat]
    restarted = Stepper.restart(session, codeome(new_ops), plasmids: [])

    assert restarted.status == :ready
    assert restarted.step_count == 0
    assert restarted.interp.ip == 0
    assert Codeome.to_list(restarted.codeome) == new_ops
  end

  test "restart preserves placed seeds and the resource seed" do
    session =
      Stepper.start_session(codeome([:push0, :add, :push0, :add, :push0, :add, :push0, :add]))

    {:ok, session} = Stepper.place_seed(session, seed_map(), {10, 10})

    restarted = Stepper.restart(session, session.codeome, plasmids: [])

    seeds = Enum.filter(restarted.world.lenies, fn {_id, l} -> l.kind == :seed end)
    assert length(seeds) == 1
    assert {_id, %{pos: {10, 10}}} = hd(seeds)
    assert restarted.resource_seed == session.resource_seed
  end

  test "restart installs the breakpoints passed in (already remapped by the caller)" do
    session =
      Stepper.start_session(codeome([:push0, :add, :push0, :add, :push0, :add, :push0, :add]))

    session = Stepper.toggle_breakpoint(session, 3)

    restarted = Stepper.restart(session, session.codeome, breakpoints: MapSet.new([1]))
    assert restarted.breakpoints == MapSet.new([1])

    # default: no breakpoints survive unless explicitly passed
    restarted2 = Stepper.restart(session, session.codeome, [])
    assert restarted2.breakpoints == MapSet.new()
  end

  test "reset/1 still preserves seeds AND its own breakpoints (delegation intact)" do
    session =
      Stepper.start_session(codeome([:push0, :add, :push0, :add, :push0, :add, :push0, :add]))

    session = Stepper.toggle_breakpoint(session, 2)
    {:ok, session} = Stepper.place_seed(session, seed_map(), {5, 5})
    {:ok, session} = Stepper.step(session)

    reset = Stepper.reset(session)

    assert reset.step_count == 0
    assert reset.breakpoints == MapSet.new([2])
    assert Enum.any?(reset.world.lenies, fn {_id, l} -> l.kind == :seed end)
  end
end
