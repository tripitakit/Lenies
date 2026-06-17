defmodule Lenies.World.FieldTest do
  use ExUnit.Case, async: true
  alias Lenies.World.Field

  test "level/4 is always in 0.0..1.0" do
    f = Field.new(12345)

    for x <- [0, 7, 63, 127], y <- [0, 31, 127], tick <- [0, 1, 50, 999] do
      v = Field.level(f, x, y, tick)
      assert is_float(v) and v >= 0.0 and v <= 1.0
    end
  end

  test "level/4 is deterministic for the same field + coords + tick" do
    f = Field.new(999)
    assert Field.level(f, 10, 20, 5) == Field.level(f, 10, 20, 5)
  end

  test "level/4 varies across space (not flat)" do
    f = Field.new(7)
    # Full grid: robust to zone width + the @gamma shape (which crushes most of
    # the field toward 0, leaving sparse oases — a small window can sit in one).
    vals = for x <- 0..127, y <- 0..127, do: Field.level(f, x, y, 0)
    assert Enum.max(vals) - Enum.min(vals) > 0.1
  end

  test "level/4 varies across time somewhere (not temporally frozen)" do
    f = Field.new(7)
    # The most-varying cell (an oasis) must move over time; a desert cell barely
    # changes under the gamma shape, so take the max over a coarse cell grid.
    ranges =
      for x <- 0..120//8, y <- 0..120//8 do
        vals = for t <- [0, 100, 200, 300, 400], do: Field.level(f, x, y, t)
        Enum.max(vals) - Enum.min(vals)
      end

    assert Enum.max(ranges) > 0.03
  end

  test "different seeds give different fields" do
    a = Field.new(1)
    b = Field.new(2)

    diffs =
      for x <- 0..30, y <- 0..30 do
        abs(Field.level(a, x, y, 0) - Field.level(b, x, y, 0))
      end

    assert Enum.sum(diffs) > 0.0
  end

  test "new/1 derives a stable field from a seed" do
    assert Field.new(42) == Field.new(42)
  end
end
