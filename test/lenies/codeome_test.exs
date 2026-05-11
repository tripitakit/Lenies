defmodule Lenies.CodeomeTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeome

  test "from_list/1 builds a tuple-backed Codeome" do
    c = Codeome.from_list([:nop_0, :nop_1, :push0])
    assert Codeome.size(c) == 3
  end

  test "at/2 returns the opcode at the given position" do
    c = Codeome.from_list([:nop_0, :push1, :add])
    assert Codeome.at(c, 0) == :nop_0
    assert Codeome.at(c, 1) == :push1
    assert Codeome.at(c, 2) == :add
  end

  test "at/2 wraps around (Codeome is treated as circular for template search)" do
    c = Codeome.from_list([:nop_0, :nop_1])
    assert Codeome.at(c, 2) == :nop_0
    assert Codeome.at(c, -1) == :nop_1
  end

  test "to_list/1 returns the opcodes as a list" do
    c = Codeome.from_list([:nop_0, :push1])
    assert Codeome.to_list(c) == [:nop_0, :push1]
  end

  test "hash/1 is stable for identical Codeome" do
    c1 = Codeome.from_list([:nop_0, :push1, :add])
    c2 = Codeome.from_list([:nop_0, :push1, :add])
    assert Codeome.hash(c1) == Codeome.hash(c2)
  end

  test "hash/1 differs for distinct Codeome" do
    c1 = Codeome.from_list([:nop_0, :push1])
    c2 = Codeome.from_list([:nop_1, :push1])
    refute Codeome.hash(c1) == Codeome.hash(c2)
  end
end
