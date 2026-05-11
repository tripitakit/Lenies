defmodule Lenies.Interpreter.LocalSenseTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  defp run_step(opcodes, state) do
    c = Codeome.from_list(opcodes)
    Interpreter.step(state, c)
  end

  test ":sense_self pushes 1 (placeholder: alive)" do
    {:cont, s} = run_step([:sense_self], State.new(energy: 100.0))
    assert s.stack == [1]
  end

  test ":sense_energy pushes current energy as integer" do
    {:cont, s} = run_step([:sense_energy], State.new(energy: 42.5))
    assert s.stack == [42]
  end

  test ":sense_age pushes current age" do
    state = State.new(energy: 100.0, age: 17)
    {:cont, s} = run_step([:sense_age], state)
    assert s.stack == [17]
  end

  test ":sense_size pushes Codeome size" do
    c = Codeome.from_list([:sense_size, :nop_0, :nop_1])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.stack == [3]
  end
end
