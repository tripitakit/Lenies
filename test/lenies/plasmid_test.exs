defmodule Lenies.PlasmidTest do
  use ExUnit.Case, async: true
  alias Lenies.Plasmid

  test "new/1 builds a struct from a list of opcodes" do
    p = Plasmid.new([:eat, :move, :turn_left])
    assert %Plasmid{opcodes: [:eat, :move, :turn_left]} = p
  end

  test "size/1 returns the opcode count for a populated plasmid" do
    assert Plasmid.size(Plasmid.new([:eat, :move])) == 2
  end

  test "size/1 returns 0 for an empty plasmid" do
    assert Plasmid.size(Plasmid.new([])) == 0
  end

  test "valid_length?/1 enforces [1, 64]" do
    refute Plasmid.valid_length?(0)
    assert Plasmid.valid_length?(1)
    assert Plasmid.valid_length?(64)
    refute Plasmid.valid_length?(65)
    refute Plasmid.valid_length?(-1)
  end

  test "valid_length?/1 returns false for non-integer inputs" do
    refute Plasmid.valid_length?(:not_an_int)
    refute Plasmid.valid_length?("64")
    refute Plasmid.valid_length?(64.0)
    refute Plasmid.valid_length?(nil)
  end
end
