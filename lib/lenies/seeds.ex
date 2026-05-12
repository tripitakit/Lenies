defmodule Lenies.Seeds do
  @moduledoc """
  Registry of seed Codeomes for the dashboard Seed dropdown.

  Each seed has:
  - `id`: atom identifier (used in dropdown values)
  - `name`: human-readable label
  - `codeome`: a `Lenies.Codeome.t()` (or a 0-arity function for lazy/random ones)
  - `default_options`: keyword/map with initial energy, etc.

  Vedi spec §7.1 (Controllo / Seed) e §5.5 (seed predefiniti).
  """

  alias Lenies.Codeome
  alias Lenies.Codeome.Opcodes
  alias Lenies.Codeomes.{Carnivore, MinimalReplicator}

  @random_min_len 30
  @random_max_len 120

  @doc "All available seeds as a list of records."
  def all do
    [
      %{
        id: :minimal_replicator,
        name: "Minimal Replicator",
        codeome: MinimalReplicator.codeome(),
        default_options: %{energy: 2000.0}
      },
      %{
        id: :carnivore,
        name: "Carnivore",
        codeome: Carnivore.codeome(),
        default_options: %{energy: 2000.0}
      },
      %{
        id: :random,
        name: "Random (probabilmente sterile)",
        codeome: build_random_codeome(),
        default_options: %{energy: 200.0}
      }
    ]
  end

  @doc "Look up a seed by id. Returns nil if not found."
  def get(id) when is_atom(id) do
    Enum.find(all(), &(&1.id == id))
  end

  @doc """
  Build a random Codeome of length between @random_min_len and @random_max_len,
  with opcodes uniformly sampled from the whitelist.
  """
  def build_random_codeome do
    len = :rand.uniform(@random_max_len - @random_min_len + 1) + @random_min_len - 1
    whitelist = Opcodes.all()

    opcodes = for _ <- 1..len, do: Enum.random(whitelist)
    Codeome.from_list(opcodes)
  end
end
