defmodule Lenies.Interpreter.CallStackCapTest do
  use ExUnit.Case, async: true

  alias Lenies.Interpreter.State

  test "push_call/2 caps at @call_stack_max (default 32)" do
    s =
      Enum.reduce(1..32, State.new(energy: 100.0), fn i, acc ->
        State.push_call(acc, i)
      end)

    assert length(s.call_stack) == 32
    assert hd(s.call_stack) == 32

    s = State.push_call(s, 99)
    assert length(s.call_stack) == 32
    assert hd(s.call_stack) == 99
    refute 1 in s.call_stack
  end

  test "pop_call/1 returns {value, state}; empty returns {nil, state}" do
    s = State.new(energy: 100.0) |> State.push_call(7) |> State.push_call(9)
    assert {9, s} = State.pop_call(s)
    assert {7, s} = State.pop_call(s)
    assert {nil, _} = State.pop_call(s)
  end
end
