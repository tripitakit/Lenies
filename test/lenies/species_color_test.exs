defmodule Lenies.SpeciesColorTest do
  use ExUnit.Case, async: true

  alias Lenies.SpeciesColor

  # A standalone test handle whose `tables.color_overrides` points at a
  # private ETS table. Avoids needing to boot a `Lenies.World` (slow,
  # not-async-safe) for unit tests of SpeciesColor itself.
  defp make_handle do
    tid = :ets.new(:color_overrides_test, [:set, :public, read_concurrency: true])

    handle = %Lenies.WorldHandle{
      id: :test,
      pid: self(),
      tables: %{cells: nil, lenies: nil, child_slots: nil, history: nil, color_overrides: tid},
      pubsub_prefix: "test"
    }

    {handle, tid}
  end

  describe "hue_byte/2" do
    setup do
      {handle, tid} = make_handle()
      on_exit(fn -> if :ets.info(tid) != :undefined, do: :ets.delete(tid) end)
      {:ok, handle: handle}
    end

    test "is deterministic for the same hash", %{handle: handle} do
      hash = "abc123"
      assert SpeciesColor.hue_byte(handle, hash) == SpeciesColor.hue_byte(handle, hash)
    end

    test "is always in 1..255 (0 is reserved)", %{handle: handle} do
      for _n <- 1..200 do
        hash = :crypto.strong_rand_bytes(16)
        byte = SpeciesColor.hue_byte(handle, hash)
        assert byte >= 1 and byte <= 255, "got #{byte} for hash #{inspect(hash)}"
      end
    end

    test "produces a reasonable spread across distinct hashes", %{handle: handle} do
      hashes = for _n <- 1..50, do: :crypto.strong_rand_bytes(16)
      bytes = Enum.map(hashes, fn h -> SpeciesColor.hue_byte(handle, h) end)
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

  describe "hex/2" do
    setup do
      {handle, tid} = make_handle()
      on_exit(fn -> if :ets.info(tid) != :undefined, do: :ets.delete(tid) end)
      {:ok, handle: handle}
    end

    test "matches byte_to_hex(hue_byte(hash))", %{handle: handle} do
      hash = "any-hash-bytes"

      assert SpeciesColor.hex(handle, hash) ==
               SpeciesColor.byte_to_hex(SpeciesColor.hue_byte(handle, hash))
    end

    test "is deterministic for the same hash", %{handle: handle} do
      assert SpeciesColor.hex(handle, "seed") == SpeciesColor.hex(handle, "seed")
    end
  end

  describe "color overrides" do
    setup do
      {handle, tid} = make_handle()
      on_exit(fn -> if :ets.info(tid) != :undefined, do: :ets.delete(tid) end)
      {:ok, handle: handle}
    end

    test "set_override/3 then override/2 returns the hex", %{handle: handle} do
      SpeciesColor.set_override(handle, "hash-x", "#abcdef")
      assert SpeciesColor.override(handle, "hash-x") == "#abcdef"
    end

    test "override/2 returns nil when no override is set", %{handle: handle} do
      assert SpeciesColor.override(handle, "never-set") == nil
    end

    test "hex/2 returns the override when set", %{handle: handle} do
      SpeciesColor.set_override(handle, "hash-y", "#112233")
      assert SpeciesColor.hex(handle, "hash-y") == "#112233"
    end

    test "hex/2 falls back to hash-derived when no override", %{handle: handle} do
      derived = SpeciesColor.hex(handle, "hash-z")
      SpeciesColor.set_override(handle, "hash-z", "#ff0000")
      assert SpeciesColor.hex(handle, "hash-z") == "#ff0000"
      SpeciesColor.clear_override(handle, "hash-z")
      assert SpeciesColor.hex(handle, "hash-z") == derived
    end

    test "set_override/3 replaces an existing override for the same hash", %{handle: handle} do
      SpeciesColor.set_override(handle, "hash-w", "#aaaaaa")
      SpeciesColor.set_override(handle, "hash-w", "#bbbbbb")
      assert SpeciesColor.override(handle, "hash-w") == "#bbbbbb"
    end

    test "multiple hashes have independent overrides", %{handle: handle} do
      SpeciesColor.set_override(handle, "hash-a", "#111111")
      SpeciesColor.set_override(handle, "hash-b", "#222222")
      assert SpeciesColor.override(handle, "hash-a") == "#111111"
      assert SpeciesColor.override(handle, "hash-b") == "#222222"
    end

    test "hue_byte/2 follows the override's hue (so the canvas matches)", %{handle: handle} do
      hash = "canvas-override-hash"
      no_override_byte = SpeciesColor.hue_byte(handle, hash)

      # Pure red sits at hue 0°: byte should be 1 (the lowest of 1..255).
      SpeciesColor.set_override(handle, hash, "#FF0000")
      red_byte = SpeciesColor.hue_byte(handle, hash)
      assert red_byte == 1

      # Pure green sits at hue 120°: byte ≈ round(120/360 × 255) + 1 = 86.
      SpeciesColor.set_override(handle, hash, "#00FF00")
      green_byte = SpeciesColor.hue_byte(handle, hash)
      assert green_byte == 86

      # And the byte is different from the hash-derived default in at
      # least one of the two cases (sanity check for non-trivial override).
      assert red_byte != no_override_byte or green_byte != no_override_byte
    end

    test "hue_byte/2 falls back to hash-derived for greyscale overrides", %{handle: handle} do
      hash = "grey-override-hash"
      default = SpeciesColor.hue_byte(handle, hash)

      # Pure grey has no defined hue → override is ignored, byte falls
      # back to the hash-derived default so the canvas still paints
      # something instead of going to 0.
      SpeciesColor.set_override(handle, hash, "#808080")
      assert SpeciesColor.hue_byte(handle, hash) == default
    end
  end
end
