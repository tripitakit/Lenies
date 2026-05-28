defmodule Lenies.World.Config do
  @moduledoc """
  Per-world simulation tuning. Each `Lenies.World` holds one of these in its
  state. `defaults/0` sources values from `Application.get_env(:lenies, …)`
  so existing `config/runtime.exs` files keep working — but the **source of
  truth at runtime is the world's state**, not the global app env.

  System bounds that are not per-world (codeome length bounds, opcode
  whitelist, snapshot root, reconcile interval) stay in `Lenies.Config`.
  """

  defstruct radiation_per_tick: 0.05,
            eat_amount: 100.0,
            carcass_decay: 0.01,
            lenie_metabolize_delay_ms: 0,
            tick_interval_ms: 100,
            copy_substitution_rate: 0.001,
            copy_insert_rate: 0.0005,
            copy_delete_rate: 0.0005,
            background_mutation_rate_per_1000_ticks: 0.0,
            attack_damage: 50,
            grid_width: 256,
            grid_height: 256

  @type t :: %__MODULE__{}

  @doc """
  Build a `%Config{}` from `Application.get_env(:lenies, …)` falling back to
  the struct defaults if a key is absent.
  """
  @spec defaults() :: t()
  def defaults do
    %__MODULE__{
      radiation_per_tick: get(:radiation_per_tick, 0.05),
      eat_amount: get(:eat_amount, 100.0),
      carcass_decay: get(:carcass_decay, 0.01),
      lenie_metabolize_delay_ms: get(:lenie_metabolize_delay_ms, 0),
      tick_interval_ms: get(:tick_interval_ms, 100),
      copy_substitution_rate: get(:copy_substitution_rate, 0.001),
      copy_insert_rate: get(:copy_insert_rate, 0.0005),
      copy_delete_rate: get(:copy_delete_rate, 0.0005),
      background_mutation_rate_per_1000_ticks: get(:background_mutation_rate_per_1000_ticks, 0.0),
      attack_damage: get(:attack_damage, 50),
      grid_width: get(:grid_width, 256),
      grid_height: get(:grid_height, 256)
    }
  end

  @doc """
  Merge a caller-provided overrides map into a `%Config{}`. Unknown keys are
  silently dropped (Map.take limits to known fields).
  """
  @spec merge(t(), map()) :: t()
  def merge(%__MODULE__{} = cfg, overrides) when is_map(overrides) do
    known = Map.keys(Map.from_struct(cfg))
    struct(cfg, Map.take(overrides, known))
  end

  defp get(key, default), do: Application.get_env(:lenies, key, default)
end
