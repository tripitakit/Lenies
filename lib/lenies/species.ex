defmodule Lenies.Species do
  @moduledoc """
  Aggregator for the `:lenies` ETS table, grouping by `codeome_hash`.

  Each species record:
  - `hash`: the codeome_hash binary
  - `population`: count of currently-alive Lenies with this hash
  - `avg_generation`: average generation number across the population
  - `sample_lenie_id`: id of one representative Lenie (for fetching the full Codeome via Registry)

  Vedi spec §5.4 (speciazione) e §7.1 (panel Specie).
  """

  @type species_record :: %{
          hash: binary(),
          population: pos_integer(),
          avg_generation: float(),
          sample_lenie_id: binary()
        }

  @doc """
  Aggregate the `:lenies` ETS table by codeome_hash. Returns a list of species records sorted
  by population descending.
  """
  @spec aggregate() :: [species_record()]
  def aggregate do
    :ets.tab2list(:lenies)
    |> Enum.group_by(fn {_id, snap} -> snap.codeome_hash end)
    |> Enum.map(fn {hash, entries} ->
      gens =
        entries
        |> Enum.map(fn {_id, snap} ->
          snap.lineage |> elem(1)
        end)

      avg_gen =
        if Enum.empty?(gens), do: 0.0, else: Enum.sum(gens) / length(gens) * 1.0

      {sample_id, _} = hd(entries)

      %{
        hash: hash,
        population: length(entries),
        avg_generation: avg_gen,
        sample_lenie_id: sample_id
      }
    end)
    |> Enum.sort_by(& &1.population, :desc)
  end

  @doc "Return all `:lenies` records (raw {id, snap} tuples) with the given codeome_hash."
  @spec for_hash(binary()) :: [{binary(), map()}]
  def for_hash(hash) do
    :ets.tab2list(:lenies)
    |> Enum.filter(fn {_id, snap} -> snap.codeome_hash == hash end)
  end

  @doc "Top N species by population. N defaults to 10."
  @spec top_n(pos_integer()) :: [species_record()]
  def top_n(n \\ 10) when is_integer(n) and n > 0 do
    aggregate() |> Enum.take(n)
  end
end
