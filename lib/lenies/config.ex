defmodule Lenies.Config do
  @moduledoc """
  Typed getters for Lenies simulation parameters.

  Values are read via `Application.get_env/3` under the `:lenies` key.
  Defaults are defined in `config/runtime.exs`; they can be changed at runtime
  via `Application.put_env/3` (for GUI tuning sliders).
  """

  @app :lenies

  def grid_size, do: get(:grid_size, {256, 256})
  def tick_interval_ms, do: get(:tick_interval_ms, 100)
  def radiation_per_tick, do: get(:radiation_per_tick, 100)
  def radiation_uniform_ratio, do: get(:radiation_uniform_ratio, 0.7)
  def hotspot_count, do: get(:hotspot_count, 8)
  def cell_resource_cap, do: get(:cell_resource_cap, 100)
  def carcass_decay, do: get(:carcass_decay, 0.05)
  def codeome_length_bounds, do: get(:codeome_length_bounds, {5, 1000})
  def min_viable_codeome_opcodes, do: get(:min_viable_codeome_opcodes, 10)
  def reconcile_interval_ms, do: get(:reconcile_interval_ms, 30_000)

  defp get(key, default), do: Application.get_env(@app, key, default)
end
