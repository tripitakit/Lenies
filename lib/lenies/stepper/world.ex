defmodule Lenies.Stepper.World do
  @moduledoc """
  Pure-functional mirror of `Lenies.World` for the codeome stepper.

  Operates on a `%Stepper.World{}` value (no ETS, no GenServer, no PubSub)
  and resolves the same `:wait_world` actions that `Lenies.Interpreter.step/2`
  emits — using the same return shape `Lenies.Lenie.apply_world_action/3`
  uses (`{:ok, updated_interp}`), but ALSO returning the updated world.

  See spec §"Architecture" — `docs/superpowers/specs/2026-06-01-codeome-stepper-design.md`.
  """

  alias Lenies.Interpreter.State

  @grid_size {64, 64}

  defstruct grid: @grid_size, cells: %{}, lenies: %{}, child_slots: %{}

  @type t :: %__MODULE__{
          grid: {pos_integer, pos_integer},
          cells: %{{integer, integer} => map},
          lenies: %{binary => map},
          child_slots: %{binary => map}
        }

  @doc "Build a fresh 64×64 world with all cells empty and no Lenies placed."
  def new do
    {w, h} = @grid_size

    cells =
      for x <- 0..(w - 1), y <- 0..(h - 1), into: %{} do
        {{x, y}, %{resource: 0, carcass: 0, carcass_hue: 0, lenie_id: nil}}
      end

    %__MODULE__{grid: @grid_size, cells: cells, lenies: %{}, child_slots: %{}}
  end

  @doc """
  Place a Lenie record at its `pos`. Returns `{:ok, world}` or
  `{:error, :cell_occupied}` if another Lenie already sits there, or
  `{:error, :out_of_bounds}` if pos is outside the grid.
  """
  def place_lenie(%__MODULE__{} = world, id, lenie) when is_binary(id) and is_map(lenie) do
    pos = lenie.pos

    case Map.get(world.cells, pos) do
      %{lenie_id: nil} = cell ->
        new_cell = %{cell | lenie_id: id}
        new_cells = Map.put(world.cells, pos, new_cell)
        new_lenies = Map.put(world.lenies, id, lenie)
        {:ok, %{world | cells: new_cells, lenies: new_lenies}}

      %{lenie_id: _} ->
        {:error, :cell_occupied}

      nil ->
        {:error, :out_of_bounds}
    end
  end

  @doc """
  Resolve a single `:wait_world` action against this world.
  """
  @spec apply_action(tuple | atom, t(), State.t(), binary) :: {:ok, t(), State.t()}
  def apply_action(action, world, interp, lenie_id)

  def apply_action({:sense_front, _pos, _dir}, world, interp, _lenie_id) do
    front = front_cell(interp.pos, interp.dir, world.grid)

    value =
      case Map.get(world.cells, front) do
        %{lenie_id: id} when is_binary(id) -> -1
        %{resource: r} when r > 0 -> r
        _ -> 0
      end

    {:ok, world, State.push(interp, value)}
  end

  def apply_action({:move, _pos, _dir}, world, interp, lenie_id) do
    front = front_cell(interp.pos, interp.dir, world.grid)

    case Map.get(world.cells, front) do
      %{lenie_id: nil} ->
        old_pos = interp.pos

        new_cells =
          world.cells
          |> Map.update!(old_pos, fn c -> %{c | lenie_id: nil} end)
          |> Map.update!(front, fn c -> %{c | lenie_id: lenie_id} end)

        new_lenies = Map.update!(world.lenies, lenie_id, fn rec -> %{rec | pos: front} end)
        new_world = %{world | cells: new_cells, lenies: new_lenies}
        {:ok, new_world, %{interp | pos: front}}

      _occupied_or_oob ->
        {:ok, world, interp}
    end
  end

  def apply_action({:eat, _pos}, world, interp, _lenie_id) do
    cell = world.cells[interp.pos]
    amount = cell.resource

    if amount > 0 do
      new_cell = %{cell | resource: 0}
      new_cells = Map.put(world.cells, interp.pos, new_cell)
      new_world = %{world | cells: new_cells}
      {:ok, new_world, %{interp | energy: interp.energy + amount}}
    else
      {:ok, world, interp}
    end
  end

  def apply_action({:attack, _pos, _dir}, world, interp, _lenie_id) do
    front = front_cell(interp.pos, interp.dir, world.grid)

    case Map.get(world.cells, front) do
      %{lenie_id: target_id} when is_binary(target_id) ->
        damage = Application.get_env(:lenies, :attack_damage, 10)
        target = world.lenies[target_id]
        new_energy = target.energy - damage

        if new_energy <= 0 do
          carcass_value = max(0, trunc(target.energy * 0.5))

          new_cells =
            Map.update!(world.cells, front, fn c ->
              %{c | lenie_id: nil, carcass: c.carcass + carcass_value, carcass_hue: 0}
            end)

          new_lenies = Map.delete(world.lenies, target_id)
          {:ok, %{world | cells: new_cells, lenies: new_lenies}, interp}
        else
          new_lenies = Map.update!(world.lenies, target_id, fn t -> %{t | energy: new_energy} end)
          {:ok, %{world | lenies: new_lenies}, interp}
        end

      _ ->
        {:ok, world, interp}
    end
  end

  def apply_action(:defend, world, interp, _lenie_id), do: {:ok, world, interp}

  def apply_action({:allocate, size, _pos, _dir}, world, interp, lenie_id) do
    case find_free_neighbour(world, interp.pos) do
      {:ok, target_cell} ->
        slot = %{target_cell: target_cell, size: size, buffer: List.duplicate(nil, size)}
        new_slots = Map.put(world.child_slots, lenie_id, slot)
        {:ok, %{world | child_slots: new_slots}, State.push(interp, 1)}

      :no_free ->
        {:ok, world, State.push(interp, 0)}
    end
  end

  def apply_action({:write_child, opcode_int, child_addr}, world, interp, lenie_id) do
    case Map.get(world.child_slots, lenie_id) do
      %{size: size, buffer: buffer} = slot ->
        idx = Integer.mod(child_addr, size)
        new_buffer = List.replace_at(buffer, idx, opcode_int)
        new_slot = %{slot | buffer: new_buffer}
        new_slots = Map.put(world.child_slots, lenie_id, new_slot)
        {:ok, %{world | child_slots: new_slots}, State.push(interp, 1)}

      nil ->
        {:ok, world, State.push(interp, 0)}
    end
  end

  def apply_action({:divide, _energy_arg, _pos, _dir}, world, interp, lenie_id) do
    case Map.get(world.child_slots, lenie_id) do
      %{target_cell: target_cell, size: _size, buffer: buffer} ->
        if Enum.any?(buffer, &is_nil/1) do
          {:ok, world, interp}
        else
          child_opcodes = Enum.map(buffer, &Lenies.Codeome.Opcodes.decode/1)
          child_codeome = Lenies.Codeome.from_list(child_opcodes)
          child_id = "child-#{:erlang.unique_integer([:positive])}"
          child_energy = max(1.0, interp.energy / 2)

          child = %{
            codeome: child_codeome,
            pos: target_cell,
            dir: interp.dir,
            energy: child_energy,
            kind: :child,
            plasmids: []
          }

          case place_lenie(world, child_id, child) do
            {:ok, world_with_child} ->
              new_slots = Map.delete(world_with_child.child_slots, lenie_id)
              new_interp = %{interp | energy: interp.energy - child_energy}
              {:ok, %{world_with_child | child_slots: new_slots}, new_interp}

            {:error, _} ->
              {:ok, world, interp}
          end
        end

      nil ->
        {:ok, world, interp}
    end
  end

  def apply_action({:conjugate, _pos, _dir, plasmid_opcodes}, world, interp, _lenie_id)
      when plasmid_opcodes == [] do
    {:ok, world, State.push(interp, 0)}
  end

  def apply_action({:conjugate, _pos, _dir, plasmid_opcodes}, world, interp, _lenie_id) do
    front = front_cell(interp.pos, interp.dir, world.grid)

    case Map.get(world.cells, front) do
      %{lenie_id: target_id} when is_binary(target_id) ->
        new_lenies =
          Map.update!(world.lenies, target_id, fn target ->
            %{target | plasmids: target.plasmids ++ [plasmid_opcodes]}
          end)

        {:ok, %{world | lenies: new_lenies}, State.push(interp, 1)}

      _ ->
        {:ok, world, State.push(interp, 0)}
    end
  end

  @doc """
  Encode the world for the canvas hook. Returns a map with `w, h, cells, lenies`
  suitable for JSON encoding and consumption by the JS `StepperCanvas` hook.
  """
  def encode_grid_payload(%__MODULE__{cells: cells, lenies: lenies, grid: {w, h}}) do
    cells_payload =
      for x <- 0..(w - 1), y <- 0..(h - 1) do
        c = cells[{x, y}]
        %{x: x, y: y, r: c.resource, c: c.carcass, l: c.lenie_id}
      end

    lenies_payload =
      Enum.map(lenies, fn {id, l} ->
        %{id: id, x: elem(l.pos, 0), y: elem(l.pos, 1), dir: l.dir, kind: l.kind}
      end)

    %{w: w, h: h, cells: cells_payload, lenies: lenies_payload}
  end

  # ----- helpers -----

  defp front_cell({x, y}, dir, {w, h}) do
    case dir do
      :n -> {x, Integer.mod(y - 1, h)}
      :s -> {x, Integer.mod(y + 1, h)}
      :e -> {Integer.mod(x + 1, w), y}
      :w -> {Integer.mod(x - 1, w), y}
    end
  end

  defp find_free_neighbour(%__MODULE__{grid: grid, cells: cells}, {x, y}) do
    {w, h} = grid

    neighbours = [
      {x, Integer.mod(y - 1, h)},
      {Integer.mod(x + 1, w), y},
      {x, Integer.mod(y + 1, h)},
      {Integer.mod(x - 1, w), y}
    ]

    case Enum.find(neighbours, fn pos -> match?(%{lenie_id: nil}, Map.get(cells, pos)) end) do
      nil -> :no_free
      pos -> {:ok, pos}
    end
  end
end
