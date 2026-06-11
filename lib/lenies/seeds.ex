defmodule Lenies.Seeds do
  @moduledoc """
  Registry of seed Codeomes for the dashboard Seed dropdown.

  The defaults form a **capability ladder** — four typologies designed ex novo,
  each organized around a different computational principle, in order of
  increasing complexity:

  1. `Reflex` — a pure sensor→motor reflex; no memory, no replication.
  2. `Ancestor` — the canonical self-copy replicator.
  3. `Architect` — a structured program of nested `call_t`/`ret` subroutines.
  4. `Symbiont` — an adaptive, age-clocked organism with runtime plasmid
     minting (`make_plasmid`) and horizontal gene transfer (`conjugate`).

  See `docs/superpowers/specs/2026-06-11-seed-codeomes-redesign-design.md`. The
  earlier role-based zoo (MinimalReplicator, Carnivore, Defender, Hunter,
  Forager) remains in `lib/lenies/codeomes/` for reference and is still covered
  by its tests, but is no longer offered as a default.

  Each seed record has:
  - `id`: atom identifier (used in dropdown values)
  - `name`: human-readable label
  - `codeome`: a `Lenies.Codeome.t()`
  - `default_options`: map with initial energy, etc.
  - `plasmid` (optional): `[opcode]` payload pre-injected into the seed's
    plasmid buffer. None of the ladder seeds use it — `Symbiont` mints its own
    plasmid at runtime instead.
  """

  alias Lenies.Codeomes.{Ancestor, Architect, Reflex, Symbiont}

  @doc "All available seeds as a list of records, in ladder order (simple → complex)."
  def all do
    [
      %{
        id: :reflex,
        name: "Reflex (Imp)",
        codeome: Reflex.codeome(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :ancestor,
        name: "Ancestor (Self-Copy)",
        codeome: Ancestor.codeome(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :architect,
        name: "Architect (Recursive)",
        codeome: Architect.codeome(),
        default_options: %{energy: 10_000.0}
      },
      %{
        id: :symbiont,
        name: "Symbiont (Conjugator)",
        codeome: Symbiont.codeome(),
        default_options: %{energy: 10_000.0}
      }
    ]
  end

  @doc "Look up a seed by id. Returns nil if not found."
  def get(id) when is_atom(id) do
    Enum.find(all(), &(&1.id == id))
  end
end
