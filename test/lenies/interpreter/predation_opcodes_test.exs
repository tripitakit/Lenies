defmodule Lenies.Interpreter.PredationOpcodesTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  test ":attack returns :wait_world with pos and dir" do
    c = Codeome.from_list([:attack, :nop_0])
    state = State.new(energy: 100.0, pos: {5, 5}, dir: :e)

    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:attack, {5, 5}, :e}
    assert new_state.ip == 1
    # cost = 5.0
    assert_in_delta new_state.energy, 100.0 - 5.0, 0.001
  end

  test ":defend returns :wait_world (no descriptor args needed)" do
    c = Codeome.from_list([:defend, :nop_0])
    state = State.new(energy: 100.0, pos: {7, 7}, dir: :n)

    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == :defend
    assert new_state.ip == 1
    # cost = 2.0
    assert_in_delta new_state.energy, 100.0 - 2.0, 0.001
  end

  test ":attack halts on starvation when cost exceeds remaining energy" do
    c = Codeome.from_list([:attack])
    state = State.new(energy: 2.0)

    assert {:halt, :starvation, _new_state} = Interpreter.step(state, c)
  end
end
