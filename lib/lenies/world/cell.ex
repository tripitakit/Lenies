defmodule Lenies.World.Cell do
  @moduledoc """
  Struct di una cella della griglia mondo.

  - `lenie_id`: id del Lenie residente, o `nil` se vuota.
  - `resource`: biomassa accumulata dalla radiazione (clamp a `cell_resource_cap`).
  - `carcass`: energia da carcasse (decay-tasso `carcass_decay`/tick).
  - `carcass_hue`: hue byte (1..255) della specie del Lenie morto in cella,
    oppure 0 se nessuna carcassa colorata. Azzerato quando `carcass` torna a 0.
  """

  alias Lenies.Config

  @type t :: %__MODULE__{
          lenie_id: nil | binary(),
          resource: non_neg_integer(),
          carcass: non_neg_integer(),
          carcass_hue: 0..255
        }

  defstruct lenie_id: nil, resource: 0, carcass: 0, carcass_hue: 0

  def new, do: %__MODULE__{}

  def add_resource(%__MODULE__{} = cell, amount) when amount > 0 do
    cap = Config.cell_resource_cap()
    %{cell | resource: min(cap, cell.resource + amount)}
  end

  def add_resource(%__MODULE__{} = cell, _), do: cell

  def decay_carcass(%__MODULE__{} = cell, rate) when rate >= 0 and rate <= 1 do
    new_amount = max(0, floor(cell.carcass * (1 - rate)))
    new_hue = if new_amount == 0, do: 0, else: cell.carcass_hue
    %{cell | carcass: new_amount, carcass_hue: new_hue}
  end
end
