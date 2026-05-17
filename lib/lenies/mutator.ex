defmodule Lenies.Mutator do
  @moduledoc """
  Pure logic for the two mutation sources (see spec §5.2):

  (a) **Copy error** (during `:write_child`): on each invocation the World
  calls `copy_outcome/1` to decide whether to substitute, insert, delete, or
  copy the requested opcode exactly. Probabilities are tuned via
  `copy_substitution_rate`, `copy_insert_rate`, `copy_delete_rate` config.

  (b) **Background environmental mutation** (rare, during life): the World
  calls `background_mutation/1` on an existing Codeome to apply a single
  random substitution.
  """

  alias Lenies.Codeome
  alias Lenies.Codeome.Opcodes

  @type rates :: %{substitution: float(), insert: float(), delete: float()}
  @type outcome :: :write | :substitute | :insert | :delete

  @doc """
  Decide which outcome to apply for a single `:write_child`. Rolls three
  independent dice in the order substitution → insertion → deletion; the first
  hit determines the outcome. If all miss, returns `:write` (exact copy).
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

  @doc "Returns a random opcode from the whitelist."
  @spec random_opcode() :: atom()
  def random_opcode do
    all = Opcodes.all()
    Enum.random(all)
  end

  @doc """
  Apply a single point mutation (random substitution) to the Codeome.
  Used for background mutation.
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
