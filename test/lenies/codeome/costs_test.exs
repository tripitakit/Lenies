defmodule Lenies.Codeome.CostsTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeome.Costs

  test "cost/2 returns the configured cost for cheap stack ops" do
    assert Costs.cost(:nop_0, 0) == 0.1
    assert Costs.cost(:push0, 0) == 0.1
    assert Costs.cost(:dup, 0) == 0.1
  end

  test "cost/2 returns the configured cost for arithmetic" do
    assert Costs.cost(:add, 0) == 0.2
  end

  test "cost/2 returns the configured cost for sense ops" do
    assert Costs.cost(:sense_front, 0) == 0.5
  end

  test "cost/2 returns the configured cost for world actions" do
    assert Costs.cost(:move, 0) == 2.0
    assert Costs.cost(:eat, 0) == 2.0
  end

  test "cost/2 for jumps scales with template length" do
    # base 0.2 + 0.05 * template_length
    assert Costs.cost(:jmp_t, 0) == 0.2
    assert Costs.cost(:jmp_t, 4) == 0.4
    assert Costs.cost(:jmp_t, 8) == 0.6
  end

  test "cost/2 for unknown opcode returns 0.1 (treated as nop_0)" do
    assert Costs.cost(:foo_bar, 0) == 0.1
  end

  test "cost/2 for replication opcodes" do
    # :allocate is 5 + 0.05 * size; size passed as template_len convention re-used
    assert Costs.cost(:allocate, 0) == 5.0
    # 5 + 5
    assert Costs.cost(:allocate, 100) == 10.0

    assert Costs.cost(:write_child, 0) == 1.0
    assert Costs.cost(:divide, 0) == 10.0
  end
end
