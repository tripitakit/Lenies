defmodule Lenies.Interpreter.MemoryOrientTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  defp run_step(opcodes, state) do
    c = Codeome.from_list(opcodes)
    Interpreter.step(state, c)
  end

  test ":store pops slot_idx and value, stores in slots" do
    state = State.new(energy: 100.0) |> State.push(42) |> State.push(2)
    # stack top is 2 (slot idx), under is 42 (value)
    # :store pops slot_idx first, then value
    {:cont, s} = run_step([:store], state)
    assert State.load(s, 2) == 42
    assert s.stack == []
  end

  test ":load pops slot_idx and pushes value" do
    state = State.new(energy: 100.0) |> State.store(1, 99) |> State.push(1)
    {:cont, s} = run_step([:load], state)
    assert s.stack == [99]
  end

  test ":turn_left rotates direction N→W→S→E→N" do
    for {from, expected} <- [{:n, :w}, {:w, :s}, {:s, :e}, {:e, :n}] do
      state = State.new(energy: 100.0, dir: from)
      {:cont, s} = run_step([:turn_left], state)
      assert s.dir == expected
    end
  end

  test ":turn_right rotates direction N→E→S→W→N" do
    for {from, expected} <- [{:n, :e}, {:e, :s}, {:s, :w}, {:w, :n}] do
      state = State.new(energy: 100.0, dir: from)
      {:cont, s} = run_step([:turn_right], state)
      assert s.dir == expected
    end
  end
end
