defmodule LeniesWeb.DisassemblerTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeome
  alias LeniesWeb.Disassembler

  test "disassemble/2 returns a list of position/opcode maps" do
    codeome = Codeome.from_list([:nop_0, :push1, :move])

    result = Disassembler.disassemble(codeome, 0)

    assert length(result) == 3
    assert Enum.at(result, 0) == %{index: 0, opcode: :nop_0, is_current: true, comment: nil}
    assert Enum.at(result, 1) == %{index: 1, opcode: :push1, is_current: false, comment: nil}
    assert Enum.at(result, 2) == %{index: 2, opcode: :move, is_current: false, comment: nil}
  end

  test "disassemble/3 attaches comments by flat index" do
    codeome = Codeome.from_list([:nop_0, :push1, :move])

    result = Disassembler.disassemble(codeome, nil, %{0 => "head", 2 => "step"})

    assert Enum.at(result, 0).comment == "head"
    assert Enum.at(result, 1).comment == nil
    assert Enum.at(result, 2).comment == "step"
  end

  test "disassemble/2 with no current IP marks none as current" do
    codeome = Codeome.from_list([:nop_0, :push1])

    result = Disassembler.disassemble(codeome, nil)

    refute Enum.any?(result, & &1.is_current)
  end

  test "disassemble/2 marks the right line as current" do
    codeome = Codeome.from_list([:nop_0, :push1, :move, :add])

    result = Disassembler.disassemble(codeome, 2)

    assert Enum.at(result, 2).is_current
    refute Enum.at(result, 0).is_current
    refute Enum.at(result, 1).is_current
    refute Enum.at(result, 3).is_current
  end

  test "opcode_class/1 categorizes opcodes for syntax highlighting" do
    assert Disassembler.opcode_class(:nop_0) == :template
    assert Disassembler.opcode_class(:nop_1) == :template
    assert Disassembler.opcode_class(:push0) == :stack
    assert Disassembler.opcode_class(:add) == :arith
    assert Disassembler.opcode_class(:jmp_t) == :control
    assert Disassembler.opcode_class(:jlt_t) == :control
    assert Disassembler.opcode_class(:jgt_t) == :control
    assert Disassembler.opcode_class(:move) == :action
    assert Disassembler.opcode_class(:allocate) == :replication
    assert Disassembler.opcode_class(:store) == :memory
    assert Disassembler.opcode_class(:get_ip) == :self_inspect
    assert Disassembler.opcode_class(:sense_front) == :sense
    assert Disassembler.opcode_class(:attack) == :predation
    assert Disassembler.opcode_class(:unknown_xyz) == :unknown
  end
end
