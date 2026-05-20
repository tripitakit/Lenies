defmodule Lenies.Seeds do
  @moduledoc """
  Registry of seed Codeomes for the dashboard Seed dropdown.

  Each seed has:
  - `id`: atom identifier (used in dropdown values)
  - `name`: human-readable label
  - `codeome`: a `Lenies.Codeome.t()`
  - `default_options`: keyword/map with initial energy, etc.
  - `plasmid`: optional `[opcode]` payload carried in the seed's plasmid_buffer
    (currently only `:minimal_replicator` and `:carnivore` set it).

  Vedi spec §7.1 (Controllo / Seed) e §5.5 (seed predefiniti).
  """

  alias Lenies.Codeomes.{Carnivore, Defender, Forager, Hunter, MinimalReplicator}

  @doc "All available seeds as a list of records."
  def all do
    [
      %{
        id: :minimal_replicator,
        name: "Minimal Replicator (Twitch)",
        codeome: MinimalReplicator.codeome(),
        plasmid: MinimalReplicator.plasmid(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :carnivore,
        name: "Carnivore (Sprint)",
        codeome: Carnivore.codeome(),
        plasmid: Carnivore.plasmid(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :defender,
        name: "Defender",
        codeome: Defender.codeome(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :hunter,
        name: "Hunter",
        codeome: Hunter.codeome(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :forager,
        name: "Forager",
        codeome: Forager.codeome(),
        default_options: %{energy: 10_000.0}
      }
    ]
  end

  @doc "Look up a seed by id. Returns nil if not found."
  def get(id) when is_atom(id) do
    Enum.find(all(), &(&1.id == id))
  end
end
