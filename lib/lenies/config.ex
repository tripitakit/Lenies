defmodule Lenies.Config do
  @moduledoc """
  Getter tipizzati per i parametri di simulazione del progetto Lenies.

  I valori vengono letti via `Application.get_env/3` dalla chiave `:lenies`.
  In `config/runtime.exs` sono definiti i default; possono essere mutati a
  runtime via `Application.put_env/3` (per i tuning slider della GUI futura).
  """

  @app :lenies

  def grid_size, do: get(:grid_size, {256, 256})
  def population_cap, do: get(:population_cap, 50_000)
  def population_warning_threshold, do: get(:population_warning_threshold, 0.8)
  def tick_interval_ms, do: get(:tick_interval_ms, 100)
  def radiation_per_tick, do: get(:radiation_per_tick, 100)
  def radiation_uniform_ratio, do: get(:radiation_uniform_ratio, 0.7)
  def hotspot_count, do: get(:hotspot_count, 8)
  def cell_resource_cap, do: get(:cell_resource_cap, 100)
  def carcass_decay, do: get(:carcass_decay, 0.05)

  defp get(key, default), do: Application.get_env(@app, key, default)
end
