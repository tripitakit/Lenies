defmodule Lenies.Species do
  @moduledoc """
  Aggregator for the `:lenies` ETS table, grouping by `codeome_hash`.

  Each species record:
  - `hash`: the codeome_hash binary
  - `population`: count of currently-alive Lenies with this hash
  - `avg_generation`: average generation number across the population
  - `sample_lenie_id`: id of one representative Lenie (for fetching the full Codeome via Registry)
  - `size`: codeome length in opcodes (0 if the codeome isn't cached yet —
    transient race before `Lenie.init/1` finishes caching)
  - `cost`: static energy cost for one linear pass through the codeome,
    using the current tuning values for `eat_amount` and `attack_damage`
  - `max_gain`: strict upper bound for one linear pass — `n_eat × eat_amount
    + n_attack × attack_damage`. See `LeniesWeb.CodeomeBuffer.economics/3`
    for the underlying maths and the single-pass caveat.

  Vedi spec §5.4 (speciazione) e §7.1 (panel Specie).
  """

  @type species_record :: %{
          hash: binary(),
          population: pos_integer(),
          avg_generation: float(),
          sample_lenie_id: binary(),
          size: non_neg_integer(),
          cost: float(),
          max_gain: float(),
          seed_origin: nil | binary(),
          plasmids: [[atom()]]
        }

  @doc """
  Aggregate the `:lenies` ETS table by codeome_hash. Returns a list of species records sorted
  by population descending.
  """
  @spec aggregate() :: [species_record()]
  def aggregate do
    if :ets.info(:lenies) == :undefined do
      []
    else
      do_aggregate()
    end
  end

  defp do_aggregate do
    eat_amount = Application.get_env(:lenies, :eat_amount, 20)
    attack_damage = Application.get_env(:lenies, :attack_damage, 10)

    :ets.tab2list(:lenies)
    # Filter out stale snapshots whose Lenie process is already dead.
    # `World.lenie_died` is a CAST so there's a window where the
    # process is gone but the :lenies record isn't deleted yet —
    # without this filter the species table reports pop=N for a
    # species nobody's actually running, and the inspector then
    # truthfully reports "No live Lenie" when clicked. The snapshot's
    # `pid` field is written on every snapshot so it's authoritative.
    |> Enum.filter(fn {_id, snap} ->
      case Map.get(snap, :pid) do
        pid when is_pid(pid) -> Process.alive?(pid)
        # Legacy / test snapshots without a `pid` key are kept (they
        # come from direct ETS inserts in tests; the live runtime
        # always writes pid via `maybe_write_snapshot`).
        _ -> true
      end
    end)
    |> Enum.group_by(fn {_id, snap} -> snap.codeome_hash end)
    |> Enum.map(fn {hash, entries} ->
      gens =
        entries
        |> Enum.map(fn {_id, snap} ->
          snap.lineage |> elem(1)
        end)

      avg_gen =
        if Enum.empty?(gens), do: 0.0, else: Enum.sum(gens) / length(gens) * 1.0

      {sample_id, sample_snap} = hd(entries)
      {size, cost, max_gain} = codeome_metrics(hash, eat_amount, attack_damage)
      # seed_origin is inherited identically by every Lenie of a species
      # (it never changes after spawn / divide). Taking the sample is
      # enough — any divergence within a species would imply an out-of-
      # band injection, which the rest of the simulation doesn't do.
      seed_origin = Map.get(sample_snap, :seed_origin)

      # Opcode lists of the plasmids the representative Lenie carries in its
      # buffer (acquired via conjugation or inherited). The dashboard maps
      # each to a human label (Twitch / Sprint / hex hash). Like seed_origin,
      # the plasmid buffer is uniform within a codeome-hash species.
      plasmids =
        sample_snap
        |> Map.get(:plasmids, [])
        |> Enum.map(fn
          %Lenies.Plasmid{opcodes: ops} -> ops
          ops when is_list(ops) -> ops
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      %{
        hash: hash,
        population: length(entries),
        avg_generation: avg_gen,
        sample_lenie_id: sample_id,
        size: size,
        cost: cost,
        max_gain: max_gain,
        seed_origin: seed_origin,
        plasmids: plasmids
      }
    end)
    |> Enum.sort_by(& &1.population, :desc)
  end

  # Reads the cached opcode list for a species hash and computes energy
  # metrics via `LeniesWeb.CodeomeBuffer.economics/3`. Returns zeros when
  # the cache miss (briefly possible if `aggregate/0` runs before
  # `Lenie.init/1` finishes — population would also be 0 in that case,
  # so the row is harmless).
  defp codeome_metrics(hash, eat_amount, attack_damage) do
    case ets_safe_lookup(:species_codeomes, hash) do
      [{^hash, opcodes}] when is_list(opcodes) ->
        e = LeniesWeb.CodeomeBuffer.economics(opcodes, eat_amount, attack_damage)
        {length(opcodes), e.cost, e.max_gain}

      _ ->
        {0, 0.0, 0.0}
    end
  end

  defp ets_safe_lookup(table, key) do
    case :ets.info(table) do
      :undefined -> []
      _ -> :ets.lookup(table, key)
    end
  end

  @doc "Return all `:lenies` records (raw {id, snap} tuples) with the given codeome_hash."
  @spec for_hash(binary()) :: [{binary(), map()}]
  def for_hash(hash) do
    if :ets.info(:lenies) == :undefined do
      []
    else
      :ets.tab2list(:lenies)
      |> Enum.filter(fn {_id, snap} -> snap.codeome_hash == hash end)
    end
  end

  @doc "Top N species by population. N defaults to 10."
  @spec top_n(pos_integer()) :: [species_record()]
  def top_n(n \\ 10) when is_integer(n) and n > 0 do
    aggregate() |> Enum.take(n)
  end
end
