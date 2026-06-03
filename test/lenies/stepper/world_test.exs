defmodule Lenies.Stepper.WorldTest do
  use ExUnit.Case, async: true

  alias Lenies.Stepper.World

  describe "new/0" do
    test "returns a 64×64 world with all empty cells and no Lenies" do
      world = World.new()

      assert world.grid == {64, 64}
      assert world.lenies == %{}
      assert map_size(world.cells) == 64 * 64

      cell = world.cells[{0, 0}]
      assert cell.resource == 0
      assert cell.carcass == 0
      assert cell.lenie_id == nil
    end

    test "every cell is initialised — no missing keys" do
      world = World.new()

      for x <- 0..63, y <- 0..63 do
        assert Map.has_key?(world.cells, {x, y}),
               "missing cell at {#{x}, #{y}}"
      end
    end
  end

  describe "place_lenie/3" do
    test "places a Lenie at a free cell and marks the cell occupied" do
      world = World.new()

      lenie = %{
        codeome: %Lenies.Codeome{},
        pos: {5, 5},
        dir: :n,
        energy: 1000.0,
        kind: :seed,
        plasmids: []
      }

      {:ok, world1} = World.place_lenie(world, "seed-1", lenie)
      assert world1.lenies["seed-1"].pos == {5, 5}
      assert world1.cells[{5, 5}].lenie_id == "seed-1"
    end

    test "refuses to place on an occupied cell" do
      world = World.new()

      lenie = %{
        codeome: %Lenies.Codeome{},
        pos: {5, 5},
        dir: :n,
        energy: 1000.0,
        kind: :seed,
        plasmids: []
      }

      {:ok, world1} = World.place_lenie(world, "seed-1", lenie)

      assert {:error, :cell_occupied} =
               World.place_lenie(world1, "seed-2", %{lenie | pos: {5, 5}})
    end
  end

  describe "apply_action :move (toroidal)" do
    setup do
      world = World.new()

      interp = %Lenies.Interpreter.State{
        ip: 0,
        stack: [],
        slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
        call_stack: [],
        age: 0,
        energy: 1000.0,
        pos: {10, 10},
        dir: :n,
        plasmids: []
      }

      {:ok, world: world, interp: interp}
    end

    test "north advances y-1 and updates the world's debug Lenie pos", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {10, 10},
          dir: :n,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      action = {:move, {10, 10}, :n}

      {:ok, w2, i2} = World.apply_action(action, w1, %{i | pos: {10, 10}}, "debug")

      assert i2.pos == {10, 9}
      assert w2.cells[{10, 10}].lenie_id == nil
      assert w2.cells[{10, 9}].lenie_id == "debug"
      assert w2.lenies["debug"].pos == {10, 9}
    end

    test "wraps toroidally on the top edge", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {10, 0},
          dir: :n,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2, i2} = World.apply_action({:move, {10, 0}, :n}, w1, %{i | pos: {10, 0}}, "debug")

      assert i2.pos == {10, 63}
      assert w2.cells[{10, 63}].lenie_id == "debug"
    end

    test "blocked when target cell has another lenie", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {10, 10},
          dir: :n,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2} =
        World.place_lenie(w1, "seed-1", %{
          codeome: %Lenies.Codeome{},
          pos: {10, 9},
          dir: :s,
          energy: 500.0,
          kind: :seed,
          plasmids: []
        })

      {:ok, w3, i2} = World.apply_action({:move, {10, 10}, :n}, w2, %{i | pos: {10, 10}}, "debug")

      assert i2.pos == {10, 10}, "blocked — pos must NOT change"
      assert w3.cells[{10, 10}].lenie_id == "debug"
    end
  end

  describe "apply_action :sense_front" do
    setup do
      world = World.new()

      interp = %Lenies.Interpreter.State{
        ip: 0,
        stack: [],
        slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
        call_stack: [],
        age: 0,
        energy: 1000.0,
        pos: {5, 5},
        dir: :e,
        plasmids: []
      }

      {:ok, world: world, interp: interp}
    end

    test "empty front cell pushes 0", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, _w2, i2} = World.apply_action({:sense_front, {5, 5}, :e}, w1, i, "debug")
      assert i2.stack == [0]
    end

    test "front cell with resource pushes the resource amount", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      w2 = put_in(w1.cells[{6, 5}].resource, 12)
      {:ok, _w3, i2} = World.apply_action({:sense_front, {5, 5}, :e}, w2, i, "debug")
      assert i2.stack == [12]
    end

    test "front cell with a Lenie pushes -1", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2} =
        World.place_lenie(w1, "seed-1", %{
          codeome: %Lenies.Codeome{},
          pos: {6, 5},
          dir: :w,
          energy: 500.0,
          kind: :seed,
          plasmids: []
        })

      {:ok, _w3, i2} = World.apply_action({:sense_front, {5, 5}, :e}, w2, i, "debug")
      assert i2.stack == [-1]
    end
  end

  describe "apply_action :eat" do
    setup do
      world = World.new()

      interp = %Lenies.Interpreter.State{
        ip: 0,
        stack: [],
        slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
        call_stack: [],
        age: 0,
        energy: 500.0,
        pos: {5, 5},
        dir: :n,
        plasmids: []
      }

      {:ok, world: world, interp: interp}
    end

    test "eats the resource on the current cell, increments energy, zeros the resource", %{
      world: w,
      interp: i
    } do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :n,
          energy: 500.0,
          kind: :debug,
          plasmids: []
        })

      w2 = put_in(w1.cells[{5, 5}].resource, 20)

      {:ok, w3, i2} = World.apply_action({:eat, {5, 5}}, w2, i, "debug")

      assert i2.energy == 520.0
      assert w3.cells[{5, 5}].resource == 0
    end

    test "no resource = no-op on energy", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :n,
          energy: 500.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, _w2, i2} = World.apply_action({:eat, {5, 5}}, w1, i, "debug")
      assert i2.energy == 500.0
    end
  end

  describe "apply_action :attack / :defend" do
    setup do
      world = World.new()

      interp = %Lenies.Interpreter.State{
        ip: 0,
        stack: [],
        slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
        call_stack: [],
        age: 0,
        energy: 1000.0,
        pos: {5, 5},
        dir: :e,
        plasmids: []
      }

      {:ok, world: world, interp: interp}
    end

    test ":attack damages the front Lenie's energy by attack_damage", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2} =
        World.place_lenie(w1, "seed-1", %{
          codeome: %Lenies.Codeome{},
          pos: {6, 5},
          dir: :w,
          energy: 100.0,
          kind: :seed,
          plasmids: []
        })

      {:ok, w3, _i2} = World.apply_action({:attack, {5, 5}, :e}, w2, i, "debug")

      damage = Application.get_env(:lenies, :attack_damage, 10)
      assert w3.lenies["seed-1"].energy == 100.0 - damage
    end

    test ":attack on empty cell is a no-op", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2, i2} = World.apply_action({:attack, {5, 5}, :e}, w1, i, "debug")
      assert w2 == w1
      assert i2 == i
    end

    test ":attack that drops target ≤ 0 converts the target into a carcass", %{
      world: w,
      interp: i
    } do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2} =
        World.place_lenie(w1, "seed-1", %{
          codeome: %Lenies.Codeome{},
          pos: {6, 5},
          dir: :w,
          energy: 5.0,
          kind: :seed,
          plasmids: []
        })

      {:ok, w3, _i2} = World.apply_action({:attack, {5, 5}, :e}, w2, i, "debug")

      refute Map.has_key?(w3.lenies, "seed-1")
      assert w3.cells[{6, 5}].lenie_id == nil
      assert w3.cells[{6, 5}].carcass > 0
    end

    test ":defend is a no-op on the world state", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2, i2} = World.apply_action(:defend, w1, i, "debug")
      assert w2 == w1
      assert i2 == i
    end
  end

  describe "apply_action :allocate / :write_child" do
    setup do
      world = World.new()

      interp = %Lenies.Interpreter.State{
        ip: 0,
        stack: [],
        slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
        call_stack: [],
        age: 0,
        energy: 1000.0,
        pos: {5, 5},
        dir: :n,
        plasmids: []
      }

      {:ok, world: world, interp: interp}
    end

    test ":allocate with a free neighbour pushes 1 and registers a child slot", %{
      world: w,
      interp: i
    } do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :n,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2, i2} = World.apply_action({:allocate, 10, {5, 5}, :n}, w1, i, "debug")

      assert i2.stack == [1]
      assert Map.has_key?(w2.child_slots, "debug")
      assert w2.child_slots["debug"].size == 10
      assert length(w2.child_slots["debug"].buffer) == 10
    end

    test ":allocate refuses if all neighbour cells are blocked", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :n,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      # Block all 4 cardinal neighbours.
      w2 =
        Enum.reduce([{5, 4}, {5, 6}, {6, 5}, {4, 5}], w1, fn pos, acc ->
          {:ok, w3} =
            World.place_lenie(
              acc,
              "blocker-#{elem(pos, 0)}-#{elem(pos, 1)}",
              %{
                codeome: %Lenies.Codeome{},
                pos: pos,
                dir: :n,
                energy: 100.0,
                kind: :seed,
                plasmids: []
              }
            )

          w3
        end)

      {:ok, _w3, i2} = World.apply_action({:allocate, 10, {5, 5}, :n}, w2, i, "debug")
      assert i2.stack == [0]
    end

    test ":write_child writes the opcode_int into the buffer at child_addr", %{
      world: w,
      interp: i
    } do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :n,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2, _} = World.apply_action({:allocate, 5, {5, 5}, :n}, w1, i, "debug")

      {:ok, w3, i2} = World.apply_action({:write_child, 8, 2}, w2, i, "debug")

      assert i2.stack == [1]
      assert Enum.at(w3.child_slots["debug"].buffer, 2) == 8
    end

    test ":write_child without an allocated slot pushes 0", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :n,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, _w2, i2} = World.apply_action({:write_child, 8, 2}, w1, i, "debug")
      assert i2.stack == [0]
    end
  end

  describe "apply_action :divide" do
    setup do
      world = World.new()

      interp = %Lenies.Interpreter.State{
        ip: 0,
        stack: [],
        slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
        call_stack: [],
        age: 0,
        energy: 1000.0,
        pos: {5, 5},
        dir: :n,
        plasmids: []
      }

      {:ok, world: world, interp: interp}
    end

    test ":divide with a complete buffer spawns a child Lenie at target_cell", %{
      world: w,
      interp: i
    } do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :n,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2, _} = World.apply_action({:allocate, 10, {5, 5}, :n}, w1, i, "debug")

      w3 =
        Enum.reduce(0..9, w2, fn addr, acc ->
          {:ok, acc2, _} = World.apply_action({:write_child, 2, addr}, acc, i, "debug")
          acc2
        end)

      {:ok, w4, i2} =
        World.apply_action({:divide, 500.0, {5, 5}, :n}, w3, %{i | energy: 1000.0}, "debug")

      assert i2.energy < 1000.0, "parent loses energy on divide"
      child_id = w4.lenies |> Map.keys() |> Enum.find(&String.starts_with?(&1, "child-"))
      assert child_id != nil
      assert w4.lenies[child_id].kind == :child
      assert w4.lenies[child_id].pos == {5, 4}
      refute Map.has_key?(w4.child_slots, "debug")
    end

    test ":divide without a slot is a no-op", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :n,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2, i2} = World.apply_action({:divide, 500.0, {5, 5}, :n}, w1, i, "debug")
      assert w2 == w1
      assert i2 == i
    end
  end

  describe "apply_action :conjugate" do
    setup do
      world = World.new()

      interp = %Lenies.Interpreter.State{
        ip: 0,
        stack: [],
        slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
        call_stack: [],
        age: 0,
        energy: 1000.0,
        pos: {5, 5},
        dir: :e,
        plasmids: []
      }

      {:ok, world: world, interp: interp}
    end

    test ":conjugate with empty plasmid arg is a no-op (push 0)", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, _w2, i2} = World.apply_action({:conjugate, {5, 5}, :e, []}, w1, i, "debug")
      assert i2.stack == [0]
    end

    test ":conjugate with no front Lenie pushes 0", %{world: w, interp: i} do
      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, _w2, i2} = World.apply_action({:conjugate, {5, 5}, :e, [:nop_0]}, w1, i, "debug")
      assert i2.stack == [0]
    end

    test ":conjugate with a target Lenie in front transfers the plasmid (pushes 1, recipient gains)",
         %{world: w, interp: i} do
      plasmid_opcodes = [:push0, :nop_1]

      {:ok, w1} =
        World.place_lenie(w, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      {:ok, w2} =
        World.place_lenie(w1, "seed-1", %{
          codeome: %Lenies.Codeome{},
          pos: {6, 5},
          dir: :w,
          energy: 100.0,
          kind: :seed,
          plasmids: []
        })

      {:ok, w3, i2} =
        World.apply_action({:conjugate, {5, 5}, :e, plasmid_opcodes}, w2, i, "debug")

      assert i2.stack == [1]
      assert w3.lenies["seed-1"].plasmids == [plasmid_opcodes]
    end
  end

  describe "encode_grid_payload/1" do
    test "produces a map with w, h, cells list, lenies list" do
      world = World.new()

      {:ok, world} =
        World.place_lenie(world, "debug", %{
          codeome: %Lenies.Codeome{},
          pos: {5, 5},
          dir: :e,
          energy: 1000.0,
          kind: :debug,
          plasmids: []
        })

      payload = World.encode_grid_payload(world)

      assert payload.w == 64
      assert payload.h == 64
      assert is_list(payload.cells)
      assert length(payload.cells) == 64 * 64
      assert is_list(payload.lenies)
      assert Enum.find(payload.lenies, &(&1.id == "debug"))
    end
  end
end
