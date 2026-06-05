defmodule Lenies.Collection.PlasmidTest do
  use ExUnit.Case, async: true

  alias Lenies.Collection.Plasmid

  defp valid?(attrs), do: Plasmid.changeset(%Plasmid{}, attrs).valid?

  test "accepts a valid opcode list" do
    assert valid?(%{opcodes: ["nop_0", "move", "eat"]})
  end

  test "rejects an empty opcode list" do
    refute valid?(%{opcodes: []})
  end

  test "rejects an unknown opcode" do
    refute valid?(%{opcodes: ["nop_0", "not_an_opcode"]})
  end

  test "rejects more than 64 opcodes" do
    refute valid?(%{opcodes: List.duplicate("nop_0", 65)})
  end

  test "accepts exactly 64 opcodes" do
    assert valid?(%{opcodes: List.duplicate("nop_0", 64)})
  end
end
