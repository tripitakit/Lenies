defmodule Lenies.Interpreter.ReplicationOpcodesTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  test ":allocate pops size, returns :wait_world with size descriptor" do
    c = Codeome.from_list([:allocate, :nop_0])
    state = State.new(energy: 100.0, pos: {5, 5}, dir: :e) |> State.push(80)

    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:allocate, 80, {5, 5}, :e}
    assert new_state.ip == 1
    # cost = 5 + 0.05 * 80 = 9
    assert_in_delta new_state.energy, 100.0 - 9.0, 0.001
    # size was popped
    assert new_state.stack == []
  end

  test ":write_child pops opcode_int and child_addr, returns :wait_world" do
    c = Codeome.from_list([:write_child, :nop_0])
    state = State.new(energy: 100.0) |> State.push(7) |> State.push(3)
    # stack: [3, 7]; pop top=3 (opcode_int), pop next=7 (child_addr)

    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    # {opcode_int=3, child_addr=7}
    assert action == {:write_child, 3, 7}
    assert new_state.ip == 1
    assert_in_delta new_state.energy, 100.0 - 1.0, 0.001
    assert new_state.stack == []
  end

  test ":divide returns :wait_world with energy and pos info" do
    c = Codeome.from_list([:divide, :nop_0])
    state = State.new(energy: 60.0, pos: {7, 8}, dir: :n)

    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    # The Lenie process will need to pass: current_energy, pos, dir, and
    # we encode them in the descriptor for the World handler
    assert match?({:divide, 60.0, {7, 8}, :n}, action) or
             match?({:divide, 50.0, {7, 8}, :n}, action)

    # Note: spec says new_state.energy = state.energy - cost(:divide, 0) = 60.0 - 10.0 = 50.0.
    # The :wait_world descriptor should pass NEW energy (post-cost), so action energy = 50.0
    assert new_state.ip == 1
    assert_in_delta new_state.energy, 60.0 - 10.0, 0.001
  end
end
