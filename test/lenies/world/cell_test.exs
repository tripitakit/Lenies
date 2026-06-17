defmodule Lenies.World.CellTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Cell

  test "add_resource/3 caps at the given cap" do
    cell = %Cell{}
    cell = Cell.add_resource(cell, 80, 150)
    assert cell.resource == 80
    cell = Cell.add_resource(cell, 100, 150)
    assert cell.resource == 150
  end

  test "add_resource/3 ignores non-positive amounts" do
    cell = %Cell{resource: 10}
    assert Cell.add_resource(cell, -5, 150).resource == 10
    assert Cell.add_resource(cell, 0, 150).resource == 10
  end

  test "decay_carcass/2 applies decay rate" do
    cell = %Cell{carcass: 100}
    cell = Cell.decay_carcass(cell, 0.05)
    assert cell.carcass == 95
  end

  test "decay_carcass/2 floors at 0" do
    # rate = 1.0 → total = carcass × 1.0 is integer, bulk removes
    # everything deterministically; no stochastic residue to handle.
    cell = %Cell{carcass: 1}
    cell = Cell.decay_carcass(cell, 1.0)
    assert cell.carcass == 0
  end

  describe "carcass_hue field" do
    test "defaults to 0" do
      assert %Cell{}.carcass_hue == 0
    end
  end

  describe "decay_carcass/2" do
    test "leaves carcass_hue alone while carcass > 0 after decay" do
      cell = %Cell{carcass: 100, carcass_hue: 42}
      decayed = Cell.decay_carcass(cell, 0.10)
      assert decayed.carcass == 90
      assert decayed.carcass_hue == 42
    end

    test "clears carcass_hue when carcass reaches 0" do
      cell = %Cell{carcass: 3, carcass_hue: 42}
      decayed = Cell.decay_carcass(cell, 1.0)
      assert decayed.carcass == 0
      assert decayed.carcass_hue == 0
    end

    test "clears carcass_hue when carcass was already 0" do
      cell = %Cell{carcass: 0, carcass_hue: 42}
      decayed = Cell.decay_carcass(cell, 0.10)
      assert decayed.carcass == 0
      assert decayed.carcass_hue == 0
    end
  end

  test "relax_resource moves toward a higher target by at least 1" do
    c = %Cell{resource: 0}
    c2 = Cell.relax_resource(c, 75, 0.15)
    assert c2.resource > 0 and c2.resource <= 75
  end

  test "relax_resource moves toward a lower target (valley receding)" do
    c = %Cell{resource: 100}
    c2 = Cell.relax_resource(c, 10, 0.15)
    assert c2.resource < 100 and c2.resource >= 10
  end

  test "relax_resource never overshoots the target" do
    assert Cell.relax_resource(%Cell{resource: 74}, 75, 0.15).resource == 75
    assert Cell.relax_resource(%Cell{resource: 11}, 10, 0.15).resource == 10
  end

  test "relax_resource converges to target after enough steps" do
    final =
      Enum.reduce(1..200, %Cell{resource: 0}, fn _, c ->
        Cell.relax_resource(c, 75, 0.15)
      end)

    assert final.resource == 75
  end

  test "relax_resource never goes negative" do
    assert Cell.relax_resource(%Cell{resource: 2}, 0, 0.15).resource >= 0
  end
end
