defmodule Lenies.Interpreter.StackArithTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  defp run_step(opcodes, state \\ State.new(energy: 100.0)) do
    c = Codeome.from_list(opcodes)

    case Interpreter.step(state, c) do
      {:cont, s} -> {:cont, s}
      {:wait_world, p, s} -> {:wait_world, p, s}
      {:halt, r, s} -> {:halt, r, s}
    end
  end

  test ":push0 pushes 0 on the stack and advances IP" do
    {:cont, s} = run_step([:push0])
    assert s.stack == [0]
    assert s.ip == 0
  end

  test ":push1 pushes 1" do
    {:cont, s} = run_step([:push1])
    assert s.stack == [1]
  end

  test ":pushN pushes a random integer in 0..255" do
    {:cont, s} = run_step([:pushN])
    assert is_integer(hd(s.stack))
    assert hd(s.stack) in 0..255
  end

  test ":dup duplicates top of stack" do
    state = State.new(energy: 100.0) |> State.push(42)
    {:cont, s} = run_step([:dup], state)
    assert s.stack == [42, 42]
  end

  test ":dup on empty stack pushes 0 twice (defensive)" do
    {:cont, s} = run_step([:dup])
    assert s.stack == [0, 0]
  end

  test ":drop removes top of stack" do
    state = State.new(energy: 100.0) |> State.push(1) |> State.push(2)
    {:cont, s} = run_step([:drop], state)
    assert s.stack == [1]
  end

  test ":swap swaps top two" do
    state = State.new(energy: 100.0) |> State.push(1) |> State.push(2)
    {:cont, s} = run_step([:swap], state)
    assert s.stack == [1, 2]
  end

  test ":add pops two and pushes sum" do
    state = State.new(energy: 100.0) |> State.push(3) |> State.push(5)
    {:cont, s} = run_step([:add], state)
    assert s.stack == [8]
  end

  test ":sub subtracts top from second" do
    state = State.new(energy: 100.0) |> State.push(10) |> State.push(3)
    # stack: [3, 10], pop 3 then 10 → 10 - 3 = 7
    {:cont, s} = run_step([:sub], state)
    assert s.stack == [7]
  end

  test ":mul multiplies" do
    state = State.new(energy: 100.0) |> State.push(4) |> State.push(6)
    {:cont, s} = run_step([:mul], state)
    assert s.stack == [24]
  end

  test ":mod modulo (avoids divide by zero)" do
    state = State.new(energy: 100.0) |> State.push(7) |> State.push(3)
    {:cont, s} = run_step([:mod], state)
    assert s.stack == [1]

    state = State.new(energy: 100.0) |> State.push(7) |> State.push(0)
    {:cont, s} = run_step([:mod], state)
    assert s.stack == [0]
  end

  test "each opcode subtracts its cost" do
    {:cont, s} = run_step([:push0])
    assert s.energy == 100.0 - 0.1

    state = State.new(energy: 100.0) |> State.push(3) |> State.push(5)
    {:cont, s2} = run_step([:add], state)
    assert s2.energy == 100.0 - 0.2
  end

  test "Lenie dies when energy goes to <= 0 after opcode execution" do
    state = State.new(energy: 0.05)
    assert {:halt, :starvation, s} = run_step([:push0], state)
    assert s.energy <= 0
  end
end
