defmodule Lenies.Interpreter.StateTest do
  use ExUnit.Case, async: true

  alias Lenies.Interpreter.State

  test "new/1 builds a default state with seeded fields" do
    s = State.new(energy: 100, pos: {10, 20}, dir: :e)
    assert s.ip == 0
    assert s.stack == []
    assert s.slots == %{0 => 0, 1 => 0, 2 => 0, 3 => 0}
    assert s.energy == 100
    assert s.pos == {10, 20}
    assert s.dir == :e
    assert s.age == 0
    assert s.call_stack == []
  end

  test "push/2 puts value on top of stack" do
    s = State.new(energy: 100) |> State.push(42)
    assert s.stack == [42]
    s = State.push(s, 7)
    assert s.stack == [7, 42]
  end

  test "push/2 enforces 16-element stack limit (drops bottom when full)" do
    s =
      Enum.reduce(1..16, State.new(energy: 100), fn i, acc ->
        State.push(acc, i)
      end)

    assert length(s.stack) == 16

    s = State.push(s, 99)
    assert length(s.stack) == 16
    assert hd(s.stack) == 99
    refute 1 in s.stack
  end

  test "pop/1 removes and returns top of stack" do
    s = State.new(energy: 100) |> State.push(1) |> State.push(2)
    assert {2, s} = State.pop(s)
    assert s.stack == [1]
  end

  test "pop/1 on empty stack returns {0, state} (defensive — opcode evolution may pop too much)" do
    s = State.new(energy: 100)
    assert {0, s2} = State.pop(s)
    assert s2.stack == []
  end

  test "store/3 and load/2 work on the 4 slots" do
    s = State.new(energy: 100) |> State.store(2, 42)
    assert State.load(s, 2) == 42
    assert State.load(s, 0) == 0
  end

  test "store/3 ignores out-of-range slot indices (modulo 4)" do
    s = State.new(energy: 100) |> State.store(7, 99)
    assert State.load(s, 7) == 99
    assert State.load(s, 3) == 99
  end

  test "apply_cost/2 subtracts energy" do
    s = State.new(energy: 100) |> State.apply_cost(2.5)
    assert s.energy == 97.5
  end

  test "advance_ip/2 modulo Codeome size" do
    s = State.new(energy: 100, ip: 5)
    assert State.advance_ip(s, 10, 1).ip == 6
    # wrap at size
    assert State.advance_ip(s, 10, 5).ip == 0
    # wrap multiple times
    assert State.advance_ip(s, 10, 12).ip == 7
  end
end
