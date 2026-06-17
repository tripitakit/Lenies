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
    vals = for x <- 0..30, y <- 0..30, do: Field.level(f, x, y, 0)
    assert Enum.max(vals) - Enum.min(vals) > 0.2
  end

  test "level/4 varies across time at a fixed cell" do
    f = Field.new(7)
    vals = for t <- 0..200, do: Field.level(f, 40, 40, t)
    assert Enum.max(vals) - Enum.min(vals) > 0.1
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
