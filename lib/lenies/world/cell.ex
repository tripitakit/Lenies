defmodule Lenies.World.Cell do
  @moduledoc """
  Struct for a single world-grid cell.

  - `lenie_id`: id of the resident Lenie, or `nil` if empty.
  - `resource`: biomass accumulated by radiation (clamped to `cell_resource_cap`).
  - `carcass`: energy from carcasses (decays at `carcass_decay` rate per tick).
  - `carcass_hue`: hue byte 0..255 (0 = no species color; 1..255 = hue byte
    of the dead Lenie). Reset to 0 when `carcass` returns to 0.
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
    # Proportional decay: per tick remove `carcass * rate` on average.
    # The integer part is removed deterministically; the fractional part
    # is removed with probability equal to itself, so the long-run mean
    # matches the ideal `carcass * (1 - rate)` without the floor() bias
    # that used to force −1/tick at small rates and turned every "slow"
    # slider value into a fast cleanup of small carcasses.
    total = cell.carcass * rate
    bulk = trunc(total)
    remainder = total - bulk
    extra = if remainder > 0 and :rand.uniform() < remainder, do: 1, else: 0
    new_amount = max(0, cell.carcass - bulk - extra)
    new_hue = if new_amount == 0, do: 0, else: cell.carcass_hue
    %{cell | carcass: new_amount, carcass_hue: new_hue}
  end
end
