defmodule Lenies.Config do
  @moduledoc """
  Typed getters for Lenies simulation parameters.

  Values are read via `Application.get_env/3` under the `:lenies` key.
  Defaults are defined in `config/runtime.exs`; they can be changed at runtime
  via `Application.put_env/3` (for GUI tuning sliders).
  """

  @app :lenies

  def grid_size, do: get(:grid_size, {128, 128})
  def tick_interval_ms, do: get(:tick_interval_ms, 100)
  def radiation_per_tick, do: get(:radiation_per_tick, 2500)
  def radiation_uniform_ratio, do: get(:radiation_uniform_ratio, 1.0)
  def hotspot_count, do: get(:hotspot_count, 8)
  def carcass_decay, do: get(:carcass_decay, 0.05)
  def codeome_length_bounds, do: get(:codeome_length_bounds, {5, 1024})
  def min_viable_codeome_opcodes, do: get(:min_viable_codeome_opcodes, 10)
  def plasmid_loss_probability, do: get(:plasmid_loss_probability, 0.10)
  def reconcile_interval_ms, do: get(:reconcile_interval_ms, 30_000)

  @doc """
  Reference energy for the display brightness ramp. A Lenie at `energy_ref`
  renders at full brightness; below it dims toward the client-side floor.
  Not per-world (it's a display constant; the renderer has no per-world
  config), so it lives here with the other system-wide bounds.
  """
  @spec energy_ref() :: pos_integer()
  def energy_ref, do: Application.get_env(:lenies, :energy_ref, 1000)

  defp get(key, default), do: Application.get_env(@app, key, default)
end
