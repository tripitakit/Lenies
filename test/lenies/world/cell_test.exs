defmodule Lenies.World.CellTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Cell

  test "new/0 returns an empty cell" do
    assert %Cell{lenie_id: nil, resource: 0, carcass: 0} = Cell.new()
  end

  test "add_resource/2 caps at cell_resource_cap" do
    cell = Cell.new()
    cell = Cell.add_resource(cell, 80)
    assert cell.resource == 80
    cell = Cell.add_resource(cell, 50)
    assert cell.resource == 100
  end

  test "add_resource/2 ignores negative" do
    cell = %Cell{resource: 10}
    assert Cell.add_resource(cell, -5).resource == 10
  end

  test "decay_carcass/2 applies decay rate" do
    cell = %Cell{carcass: 100}
    cell = Cell.decay_carcass(cell, 0.05)
    assert cell.carcass == 95
  end

  test "decay_carcass/2 floors at 0" do
    cell = %Cell{carcass: 1}
    cell = Cell.decay_carcass(cell, 0.99)
    assert cell.carcass == 0
  end
end
