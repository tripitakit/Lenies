defmodule Lenies.World.Hotspots do
  @moduledoc """
  Gestione dei centri "hotspot" di radiazione: posizioni che ricevono il 30%
  della radiazione del tick. Si muovono lentamente sulla griglia toroidale.
  """

  @type grid :: {pos_integer(), pos_integer()}
  @type coord :: {non_neg_integer(), non_neg_integer()}

  @spec initial(grid(), non_neg_integer()) :: [coord()]
  def initial({w, h}, n) when n >= 0 do
    for _ <- 1..n//1 do
      {:rand.uniform(w) - 1, :rand.uniform(h) - 1}
    end
  end

  @spec drift([coord()], grid()) :: [coord()]
  def drift(hotspots, {w, h}) do
    Enum.map(hotspots, fn {x, y} ->
      # -1 | 0 | 1
      dx = :rand.uniform(3) - 2
      dy = :rand.uniform(3) - 2
      {Integer.mod(x + dx, w), Integer.mod(y + dy, h)}
    end)
  end
end
