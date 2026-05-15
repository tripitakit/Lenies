defmodule Lenies.SpeciesColorTest do
  use ExUnit.Case, async: true

  alias Lenies.SpeciesColor

  describe "hue_byte/1" do
    test "is deterministic for the same hash" do
      hash = "abc123"
      assert SpeciesColor.hue_byte(hash) == SpeciesColor.hue_byte(hash)
    end

    test "is always in 1..255 (0 is reserved)" do
      for _n <- 1..200 do
        hash = :crypto.strong_rand_bytes(16)
        byte = SpeciesColor.hue_byte(hash)
        assert byte >= 1 and byte <= 255, "got #{byte} for hash #{inspect(hash)}"
      end
    end

    test "produces a reasonable spread across distinct hashes" do
      hashes = for _n <- 1..50, do: :crypto.strong_rand_bytes(16)
      bytes = Enum.map(hashes, &SpeciesColor.hue_byte/1)
      distinct = bytes |> MapSet.new() |> MapSet.size()
      assert distinct >= 30, "expected at least 30 distinct bytes for 50 hashes, got #{distinct}"
    end
  end

  describe "byte_to_hex/1" do
    test "returns a 7-character #RRGGBB string" do
      hex = SpeciesColor.byte_to_hex(1)
      assert String.length(hex) == 7
      assert String.starts_with?(hex, "#")
      assert hex =~ ~r/^#[0-9A-F]{6}$/
    end

    test "is deterministic" do
      assert SpeciesColor.byte_to_hex(42) == SpeciesColor.byte_to_hex(42)
    end

    test "different bytes produce different colors" do
      assert SpeciesColor.byte_to_hex(1) != SpeciesColor.byte_to_hex(128)
    end
  end

  describe "hex/1" do
    test "matches byte_to_hex(hue_byte(hash))" do
      hash = "any-hash-bytes"
      assert SpeciesColor.hex(hash) == SpeciesColor.byte_to_hex(SpeciesColor.hue_byte(hash))
    end

    test "is deterministic for the same hash" do
      assert SpeciesColor.hex("seed") == SpeciesColor.hex("seed")
    end
  end
end
