defmodule Lenies.Interpreter.SelfInspectTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Codeome.Opcodes
  alias Lenies.Interpreter.State

  test ":get_ip pushes current IP" do
    c = Codeome.from_list([:nop_0, :get_ip, :add])
    state = State.new(energy: 100.0, ip: 1)
    {:cont, s} = Interpreter.step(state, c)
    assert s.stack == [1]
  end

  test ":get_size pushes Codeome size" do
    c = Codeome.from_list([:get_size, :nop_0, :nop_1, :add, :sub])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.stack == [5]
  end

  test ":read_self pops addr and pushes opcode-as-integer at that address" do
    c = Codeome.from_list([:read_self, :push1, :move])
    state = State.new(energy: 100.0) |> State.push(2)
    {:cont, s} = Interpreter.step(state, c)
    assert hd(s.stack) == Opcodes.encode(:move)
  end

  test ":read_self with addr beyond Codeome wraps modulo size" do
    c = Codeome.from_list([:read_self, :push1])
    state = State.new(energy: 100.0) |> State.push(5)
    # 5 mod 2 = 1 → :push1
    {:cont, s} = Interpreter.step(state, c)
    assert hd(s.stack) == Opcodes.encode(:push1)
  end
end
