defmodule Lenies.Codeome.OpcodesTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeome.Opcodes

  test "all/0 returns the full whitelist" do
    all = Opcodes.all()
    assert :nop_0 in all
    assert :nop_1 in all
    assert :push0 in all
    assert :move in all
    assert :get_ip in all
  end

  test "predation opcodes are in the whitelist" do
    assert :attack in Opcodes.all()
    assert :defend in Opcodes.all()
  end

  test "replication opcodes are in the whitelist" do
    assert :allocate in Opcodes.all()
    assert :write_child in Opcodes.all()
    assert :divide in Opcodes.all()
  end

  test "encode/1 returns an integer for known opcodes" do
    assert is_integer(Opcodes.encode(:nop_0))
    assert is_integer(Opcodes.encode(:move))
  end

  test "encode/1 returns unique integers per opcode" do
    encoded = Enum.map(Opcodes.all(), &Opcodes.encode/1)
    assert length(encoded) == length(Enum.uniq(encoded))
  end

  test "decode/1 round-trips with encode/1" do
    for op <- Opcodes.all() do
      assert Opcodes.decode(Opcodes.encode(op)) == op
    end
  end

  test "decode/1 of unknown integer returns :nop_0 (tolerance to mutations)" do
    assert Opcodes.decode(999_999) == :nop_0
  end

  test "known?/1 distinguishes whitelisted opcodes from others" do
    assert Opcodes.known?(:nop_0)
    assert Opcodes.known?(:allocate)
    refute Opcodes.known?(:foo_bar)
  end
end
