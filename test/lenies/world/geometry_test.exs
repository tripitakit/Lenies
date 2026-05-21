defmodule Lenies.World.GeometryTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Geometry

  describe "step/3" do
    test ":n decrements y, wrapping at grid top" do
      assert Geometry.step({5, 0}, :n, {10, 10}) == {5, 9}
      assert Geometry.step({5, 3}, :n, {10, 10}) == {5, 2}
    end

    test ":s increments y, wrapping at grid bottom" do
      assert Geometry.step({5, 9}, :s, {10, 10}) == {5, 0}
      assert Geometry.step({5, 3}, :s, {10, 10}) == {5, 4}
    end

    test ":e increments x, wrapping at grid right edge" do
      assert Geometry.step({9, 5}, :e, {10, 10}) == {0, 5}
      assert Geometry.step({3, 5}, :e, {10, 10}) == {4, 5}
    end

    test ":w decrements x, wrapping at grid left edge" do
      assert Geometry.step({0, 5}, :w, {10, 10}) == {9, 5}
      assert Geometry.step({3, 5}, :w, {10, 10}) == {2, 5}
    end
  end
end
