defmodule Lenies.World.Radiation do
  @moduledoc """
  Distribuzione della radiazione "solare" sulla griglia toroidale.

  Tutte le funzioni sono pure e restituiscono una mappa `%{{x, y} => amount}`
  che il chiamante applicherà alle celle ETS. Total amount preserved.
  """

  @type grid :: {pos_integer(), pos_integer()}
  @type coord :: {non_neg_integer(), non_neg_integer()}
  @type deposit :: %{coord() => pos_integer()}

  @spec uniform_deposit(grid(), non_neg_integer()) :: deposit()
  def uniform_deposit({w, h}, amount) when amount >= 0 do
    total_cells = w * h

    cond do
      amount == 0 ->
        %{}

      amount >= total_cells ->
        base = div(amount, total_cells)
        remainder = rem(amount, total_cells)

        m =
          for x <- 0..(w - 1), y <- 0..(h - 1), into: %{} do
            {{x, y}, base}
          end

        scatter_amount(m, {w, h}, remainder)

      true ->
        # distribuzione casuale di `amount` "pacchetti unitari"
        scatter_amount(%{}, {w, h}, amount)
    end
  end

  @spec hotspot_deposit(grid(), non_neg_integer(), [coord()], keyword()) :: deposit()
  def hotspot_deposit(_grid, 0, _hotspots, _opts), do: %{}
  def hotspot_deposit(_grid, _amount, [], _opts), do: %{}

  def hotspot_deposit({w, h}, amount, hotspots, opts) do
    radius = Keyword.get(opts, :radius, 5)
    per_hotspot = div(amount, length(hotspots))
    remainder = rem(amount, length(hotspots))

    hotspots
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{hx, hy}, idx}, acc ->
      extra = if idx < remainder, do: 1, else: 0
      n = per_hotspot + extra
      candidates = neighborhood({hx, hy}, radius, {w, h})
      scatter_among(acc, candidates, n)
    end)
  end

  @spec combined(grid(), non_neg_integer(), [coord()], keyword()) :: deposit()
  def combined(grid, amount, hotspots, opts) do
    ratio = Keyword.get(opts, :uniform_ratio, 0.7)
    hotspot_radius = Keyword.get(opts, :hotspot_radius, 5)
    uniform_amount = round(amount * ratio)
    hotspot_amount = amount - uniform_amount

    u = uniform_deposit(grid, uniform_amount)
    h = hotspot_deposit(grid, hotspot_amount, hotspots, radius: hotspot_radius)

    Map.merge(u, h, fn _k, a, b -> a + b end)
  end

  # ----- internals -----

  defp scatter_amount(m, _grid, 0), do: m

  defp scatter_amount(m, {w, h}, n) when n > 0 do
    cell = {:rand.uniform(w) - 1, :rand.uniform(h) - 1}
    new_m = Map.update(m, cell, 1, &(&1 + 1))
    scatter_amount(new_m, {w, h}, n - 1)
  end

  defp scatter_among(m, _candidates, 0), do: m

  defp scatter_among(m, candidates, n) when n > 0 do
    cell = Enum.random(candidates)
    new_m = Map.update(m, cell, 1, &(&1 + 1))
    scatter_among(new_m, candidates, n - 1)
  end

  defp neighborhood({hx, hy}, radius, {w, h}) do
    for dx <- -radius..radius, dy <- -radius..radius, abs(dx) + abs(dy) <= radius do
      {Integer.mod(hx + dx, w), Integer.mod(hy + dy, h)}
    end
  end
end
