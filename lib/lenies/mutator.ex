defmodule Lenies.Mutator do
  @moduledoc """
  Logica pura per le due fonti di mutazione (vedi spec §5.2):

  (a) **Errore di copia** (durante `:write_child`): ad ogni invocazione il
  World chiama `copy_outcome/1` per decidere se sostituire, inserire, cancellare,
  o copiare esattamente l'opcode richiesto. La probabilità è calibrata via
  `copy_substitution_rate`, `copy_insert_rate`, `copy_delete_rate` config.

  (b) **Mutazione ambientale di background** (raro, durante la vita): il World
  invoca `background_mutation/1` su un Codeome esistente per applicare una
  singola sostituzione random.
  """

  alias Lenies.Codeome
  alias Lenies.Codeome.Opcodes

  @type rates :: %{substitution: float(), insert: float(), delete: float()}
  @type outcome :: :write | :substitute | :insert | :delete

  @doc """
  Decide quale esito applicare per un singolo `:write_child`. Tira tre dadi
  indipendenti nell'ordine sostituzione → inserzione → cancellazione; il primo
  che colpisce determina l'esito. Se tutti falliscono, ritorna `:write` (copia
  esatta).
  """
  @spec copy_outcome(rates()) :: outcome()
  def copy_outcome(rates) do
    cond do
      :rand.uniform() < rates.substitution -> :substitute
      :rand.uniform() < rates.insert -> :insert
      :rand.uniform() < rates.delete -> :delete
      true -> :write
    end
  end

  @doc "Restituisce un opcode random dalla whitelist."
  @spec random_opcode() :: atom()
  def random_opcode do
    all = Opcodes.all()
    Enum.random(all)
  end

  @doc """
  Applica una singola mutazione puntuale (sostituzione random) al Codeome.
  Usato per la mutazione di background.
  """
  @spec background_mutation(Codeome.t()) :: Codeome.t()
  def background_mutation(%Codeome{} = c) do
    n = Codeome.size(c)

    if n == 0 do
      c
    else
      pos = :rand.uniform(n) - 1
      new_op = random_opcode()
      list = Codeome.to_list(c) |> List.replace_at(pos, new_op)
      Codeome.from_list(list)
    end
  end
end
