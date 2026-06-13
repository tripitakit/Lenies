defmodule LeniesWeb.EditorLive.HelpersTest do
  use ExUnit.Case, async: true

  alias LeniesWeb.EditorLive.Helpers
  alias LeniesWeb.GenomeBuffer

  describe "decode_section/1" do
    test "chromosome token" do
      assert Helpers.decode_section("chromosome") == :chromosome
    end

    test "plasmid tokens" do
      assert Helpers.decode_section("p0") == {:plasmid, 0}
      assert Helpers.decode_section("p3") == {:plasmid, 3}
    end

    test "unknown token falls back to chromosome" do
      assert Helpers.decode_section("garbage") == :chromosome
    end
  end

  describe "to_int/1" do
    test "passes integers through" do
      assert Helpers.to_int(7) == 7
    end

    test "parses fully-numeric strings" do
      assert Helpers.to_int("42") == 42
    end

    test "returns -1 for unparseable / trailing-garbage strings" do
      assert Helpers.to_int("12x") == -1
      assert Helpers.to_int("nope") == -1
    end
  end

  describe "parse_clamped/4" do
    test "clamps within bounds" do
      assert Helpers.parse_clamped("5", 1, 10, 99) == 5
      assert Helpers.parse_clamped("0", 1, 10, 99) == 1
      assert Helpers.parse_clamped("1000", 1, 10, 99) == 10
    end

    test "returns default for non-binary or unparseable input" do
      assert Helpers.parse_clamped("abc", 1, 10, 99) == 99
      assert Helpers.parse_clamped(nil, 1, 10, 99) == 99
    end
  end

  describe "parse_flat_key/1 and decode_saved_comments/1" do
    test "parse_flat_key handles ints, numeric strings, and junk" do
      assert Helpers.parse_flat_key(3) == 3
      assert Helpers.parse_flat_key("3") == 3
      assert Helpers.parse_flat_key("3x") == nil
      assert Helpers.parse_flat_key(:other) == nil
    end

    test "decode_saved_comments keeps only int-keyed string values" do
      assert Helpers.decode_saved_comments(%{"3" => "hi", "bad" => "x", "5" => 7}) == %{3 => "hi"}
    end

    test "decode_saved_comments tolerates non-maps" do
      assert Helpers.decode_saved_comments(nil) == %{}
    end
  end

  describe "to_known_opcode/1" do
    test "resolves a known opcode" do
      assert {:ok, :nop_0} = Helpers.to_known_opcode("nop_0")
    end

    test "rejects an unknown but existing atom" do
      # :error for a real atom that isn't an opcode
      assert :error = Helpers.to_known_opcode("noreply")
    end

    test "rejects a never-seen token without raising" do
      assert :error = Helpers.to_known_opcode("definitely_not_an_opcode_zzz")
    end
  end

  describe "parse_opcode_text/1" do
    test "parses a valid whitespace/comma list, lowercasing" do
      assert {:ok, [:nop_0, :nop_1]} = Helpers.parse_opcode_text("NOP_0, nop_1")
    end

    test "empty input yields an empty list" do
      assert {:ok, []} = Helpers.parse_opcode_text("   ")
    end

    test "returns the unknown tokens on failure" do
      assert {:error, ["bogus"]} = Helpers.parse_opcode_text("nop_0 bogus")
    end
  end

  describe "plasmid_structs/1" do
    test "drops empty plasmid buffers and wraps the rest" do
      genome = GenomeBuffer.new([:nop_0], [[:nop_1, :nop_2], []])
      structs = Helpers.plasmid_structs(genome)
      assert [%Lenies.Plasmid{opcodes: [:nop_1, :nop_2]}] = structs
    end
  end

  describe "current_economics/1" do
    test "returns the genome economics map" do
      econ = Helpers.current_economics(GenomeBuffer.new([:nop_0, :eat]))
      assert is_map(econ)
      assert Map.has_key?(econ, :cost)
    end
  end
end
