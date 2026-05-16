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

  describe "color overrides" do
    setup do
      # The override table is created in Lenies.Application — make sure it
      # exists for these tests even when the app isn't fully started.
      case :ets.info(:species_color_overrides) do
        :undefined ->
          :ets.new(:species_color_overrides, [:set, :named_table, :public, read_concurrency: true])

        _ ->
          :ok
      end

      on_exit(fn ->
        try do
          :ets.delete_all_objects(:species_color_overrides)
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    test "set_override/2 then override/1 returns the hex" do
      SpeciesColor.set_override("hash-x", "#abcdef")
      assert SpeciesColor.override("hash-x") == "#abcdef"
    end

    test "override/1 returns nil when no override is set" do
      assert SpeciesColor.override("never-set") == nil
    end

    test "hex/1 returns the override when set" do
      SpeciesColor.set_override("hash-y", "#112233")
      assert SpeciesColor.hex("hash-y") == "#112233"
    end

    test "hex/1 falls back to hash-derived when no override" do
      derived = SpeciesColor.hex("hash-z")
      SpeciesColor.set_override("hash-z", "#ff0000")
      assert SpeciesColor.hex("hash-z") == "#ff0000"
      SpeciesColor.clear_override("hash-z")
      assert SpeciesColor.hex("hash-z") == derived
    end

    test "set_override/2 replaces an existing override for the same hash" do
      SpeciesColor.set_override("hash-w", "#aaaaaa")
      SpeciesColor.set_override("hash-w", "#bbbbbb")
      assert SpeciesColor.override("hash-w") == "#bbbbbb"
    end

    test "multiple hashes have independent overrides" do
      SpeciesColor.set_override("hash-a", "#111111")
      SpeciesColor.set_override("hash-b", "#222222")
      assert SpeciesColor.override("hash-a") == "#111111"
      assert SpeciesColor.override("hash-b") == "#222222"
    end
  end
end
