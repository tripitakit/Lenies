defmodule Lenies.World.Cell do
  @moduledoc """
  Struct di una cella della griglia mondo.

  - `lenie_id`: id del Lenie residente, o `nil` se vuota.
  - `resource`: biomassa accumulata dalla radiazione (clamp a `cell_resource_cap`).
  - `carcass`: energia da carcasse (decay-tasso `carcass_decay`/tick).
  """

  alias Lenies.Config

  @type t :: %__MODULE__{
          lenie_id: nil | binary(),
          resource: non_neg_integer(),
          carcass: non_neg_integer()
        }

  defstruct lenie_id: nil, resource: 0, carcass: 0

  def new, do: %__MODULE__{}

  def add_resource(%__MODULE__{} = cell, amount) when amount > 0 do
    cap = Config.cell_resource_cap()
    %{cell | resource: min(cap, cell.resource + amount)}
  end

  def add_resource(%__MODULE__{} = cell, _), do: cell

  def decay_carcass(%__MODULE__{} = cell, rate) when rate >= 0 and rate <= 1 do
    %{cell | carcass: max(0, floor(cell.carcass * (1 - rate)))}
  end
end
