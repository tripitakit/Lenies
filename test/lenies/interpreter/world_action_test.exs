defmodule Lenies.Interpreter.WorldActionTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  test ":sense_front returns :wait_world with action descriptor" do
    c = Codeome.from_list([:sense_front, :push0])
    state = State.new(energy: 100.0, pos: {10, 10}, dir: :e)
    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:sense_front, {10, 10}, :e}
    # IP advanced and cost paid even though world hasn't replied yet
    assert new_state.ip == 1
    assert_in_delta new_state.energy, 100.0 - 0.5, 0.0001
  end

  test ":move returns :wait_world with destination" do
    c = Codeome.from_list([:move, :push0])
    state = State.new(energy: 100.0, pos: {5, 5}, dir: :n)
    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:move, {5, 5}, :n}
    assert new_state.ip == 1
    assert_in_delta new_state.energy, 100.0 - 2.0, 0.0001
  end

  test ":eat returns :wait_world with cell coordinate (current cell)" do
    c = Codeome.from_list([:eat, :push0])
    state = State.new(energy: 100.0, pos: {7, 7})
    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:eat, {7, 7}}
    assert new_state.ip == 1
  end
end
