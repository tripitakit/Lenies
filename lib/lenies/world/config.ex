defmodule Lenies.World.Config do
  @moduledoc """
  Per-world simulation tuning. Each `Lenies.World` holds one of these in its
  state. `defaults/0` sources values from `Application.get_env(:lenies, …)`
  so existing `config/runtime.exs` files keep working — but the **source of
  truth at runtime is the world's state**, not the global app env.

  System bounds that are not per-world (codeome length bounds, opcode
  whitelist, snapshot root, reconcile interval) stay in `Lenies.Config`.
  """

  # Field defaults intentionally match the historical
  # `Application.get_env(:lenies, key, <default>)` fallbacks used pre-Task-5
  # (see the removed `@cfg_defaults` in Lenies.World). Tests that
  # `Application.delete_env(:lenies, key)` on_exit expect this fallback to
  # match the pre-refactor behaviour.
  defstruct radiation_per_tick: 2500,
            eat_amount: 50,
            carcass_decay: 0.05,
            lenie_metabolize_delay_ms: 0,
            tick_interval_ms: 100,
            copy_substitution_rate: 0.005,
            copy_insert_rate: 0.0005,
            copy_delete_rate: 0.0005,
            background_mutation_rate_per_1000_ticks: 1,
            attack_damage: 10,
            spawn_cap: 50,
            replication_cap: 50

  @type t :: %__MODULE__{}

  @doc """
  Build a `%Config{}` from `Application.get_env(:lenies, …)` falling back to
  the struct defaults if a key is absent.
  """
  @spec defaults() :: t()
  def defaults do
    %__MODULE__{
      radiation_per_tick: get(:radiation_per_tick, 2500),
      eat_amount: get(:eat_amount, 50),
      carcass_decay: get(:carcass_decay, 0.05),
      lenie_metabolize_delay_ms: get(:lenie_metabolize_delay_ms, 0),
      tick_interval_ms: get(:tick_interval_ms, 100),
      copy_substitution_rate: get(:copy_substitution_rate, 0.005),
      copy_insert_rate: get(:copy_insert_rate, 0.0005),
      copy_delete_rate: get(:copy_delete_rate, 0.0005),
      background_mutation_rate_per_1000_ticks: get(:background_mutation_rate_per_1000_ticks, 1),
      attack_damage: get(:attack_damage, 10),
      spawn_cap: get(:spawn_cap, 50),
      replication_cap: get(:replication_cap, 50)
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
