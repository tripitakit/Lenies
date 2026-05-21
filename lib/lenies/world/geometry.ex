defmodule Lenies.World.Geometry do
  @moduledoc """
  Shared geometric helpers for the toroidal grid.
  """

  @doc """
  Returns the cell one step in direction `dir` from `{x, y}`, wrapping at
  the grid boundaries `{w, h}`.

  Direction conventions: `:n` decrements y, `:s` increments y,
  `:e` increments x, `:w` decrements x.
  """
  @spec step({non_neg_integer(), non_neg_integer()}, :n | :s | :e | :w, {pos_integer(), pos_integer()}) ::
          {non_neg_integer(), non_neg_integer()}
  def step({x, y}, dir, {w, h}) do
    case dir do
      :n -> {x, Integer.mod(y - 1, h)}
      :s -> {x, Integer.mod(y + 1, h)}
      :e -> {Integer.mod(x + 1, w), y}
      :w -> {Integer.mod(x - 1, w), y}
    end
  end
end
