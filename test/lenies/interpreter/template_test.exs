defmodule Lenies.Interpreter.TemplateTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeome
  alias Lenies.Interpreter.Template

  test "extract/3 reads the template right after the jump opcode" do
    # Codeome: [:jmp_t, :nop_0, :nop_1, :nop_0, :push0]
    # extract from position 0 (the :jmp_t itself) — but extract is called by interpreter
    # after :jmp_t already consumed, so position is 1 (first :nop)
    c = Codeome.from_list([:jmp_t, :nop_0, :nop_1, :nop_0, :push0])
    assert Template.extract(c, 1, 8) == {[:nop_0, :nop_1, :nop_0], 3}
  end

  test "extract/3 stops at first non-nop opcode" do
    c = Codeome.from_list([:push0, :nop_0, :nop_1, :add, :nop_0])
    assert Template.extract(c, 1, 8) == {[:nop_0, :nop_1], 2}
  end

  test "extract/3 truncates at template_max_len" do
    c = Codeome.from_list(List.duplicate(:nop_0, 20))
    assert Template.extract(c, 0, 5) == {List.duplicate(:nop_0, 5), 5}
  end

  test "extract/3 returns empty template if first opcode is not a nop" do
    c = Codeome.from_list([:push0, :add])
    assert Template.extract(c, 0, 8) == {[], 0}
  end

  test "complement/1 flips :nop_0 ↔ :nop_1" do
    assert Template.complement([:nop_0, :nop_1, :nop_0]) == [:nop_1, :nop_0, :nop_1]
  end

  test "find_complement/4 finds the complement forward from search start" do
    # template = [:nop_0]; complement = [:nop_1]
    # find :nop_1 starting from position 1
    c = Codeome.from_list([:nop_0, :push0, :nop_1, :add])
    assert Template.find_complement(c, [:nop_0], 1, 10) == {:ok, 2}
  end

  test "find_complement/4 finds it backward when forward search fails" do
    # template = [:nop_0]; complement = [:nop_1]
    # at position 3 the :nop_1 is BEHIND
    c = Codeome.from_list([:nop_1, :push0, :add, :sub, :mul])
    # forward search from 3 fails; backward from 3 finds :nop_1 at position 0
    assert Template.find_complement(c, [:nop_0], 3, 10) == {:ok, 0}
  end

  test "find_complement/4 returns :not_found when no match within radius" do
    c = Codeome.from_list([:nop_0, :push0, :add])
    assert Template.find_complement(c, [:nop_0], 0, 10) == :not_found
  end

  test "find_complement/4 matches a multi-bit template" do
    # template = [:nop_0, :nop_1]; complement = [:nop_1, :nop_0]
    c = Codeome.from_list([:nop_0, :nop_1, :push0, :nop_1, :nop_0, :add])
    # complement [:nop_1, :nop_0] is at positions 3..4 → result points to 3
    assert Template.find_complement(c, [:nop_0, :nop_1], 2, 10) == {:ok, 3}
  end

  test "find_complement/4 with empty template returns :not_found" do
    c = Codeome.from_list([:nop_0, :nop_1])
    assert Template.find_complement(c, [], 0, 10) == :not_found
  end
end
