defmodule Lenies.Codeome.Opcodes do
  @moduledoc """
  Whitelist degli opcode validi e mapping bidirezionale atom ↔ integer.

  L'integer encoding serve per `:read_self` (che ritorna l'opcode come integer
  sullo stack) e per `:write_child` (sotto-progetto 3, che riceve l'integer
  e lo decodifica per scrivere nello slot figlio).

  Vedi spec §4.2. Opcode non noti vengono trattati come `:nop_0` (tolleranza
  alle mutazioni: nessun "syntax error").
  """

  # Whitelist completa di sotto-progetto 2.
  # Replicazione (:allocate, :write_child, :divide) e predazione (:attack, :defend)
  # saranno aggiunti nei sotto-progetti 3 e 4 rispettivamente.
  @opcodes [
    # Template / bit
    :nop_0,
    :nop_1,
    # Stack / aritmetica
    :push0,
    :push1,
    :pushN,
    :dup,
    :drop,
    :swap,
    :add,
    :sub,
    :mul,
    :mod,
    # Controllo template-based
    :jmp_t,
    :jz_t,
    :jnz_t,
    :call_t,
    :ret,
    # Senso
    :sense_front,
    :sense_self,
    :sense_energy,
    :sense_age,
    :sense_size,
    # Azione mondo
    :move,
    :turn_left,
    :turn_right,
    :eat,
    # Self-inspection
    :get_ip,
    :get_size,
    :read_self,
    # Memoria locale
    :store,
    :load
  ]

  @encoding @opcodes |> Enum.with_index() |> Enum.into(%{})
  @decoding @encoding |> Map.new(fn {op, i} -> {i, op} end)

  @spec all() :: [atom()]
  def all, do: @opcodes

  @spec known?(atom()) :: boolean()
  def known?(op), do: Map.has_key?(@encoding, op)

  @spec encode(atom()) :: non_neg_integer()
  def encode(op), do: Map.get(@encoding, op, 0)

  @doc "Decodifica un integer al suo opcode. Integer fuori range → `:nop_0`."
  @spec decode(integer()) :: atom()
  def decode(i) when is_integer(i), do: Map.get(@decoding, i, :nop_0)
end
