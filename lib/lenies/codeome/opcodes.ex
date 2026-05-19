defmodule Lenies.Codeome.Opcodes do
  @moduledoc """
  Whitelist of valid opcodes and the bidirectional atom ↔ integer mapping.

  The integer encoding is used by `:read_self` (which returns the opcode as
  an integer on the stack) and by `:write_child` (which receives the integer
  and decodes it to write into the child slot).

  See spec §4.2. Unknown opcodes are treated as `:nop_0` (mutation tolerance:
  no "syntax error").
  """

  # Full whitelist including predation.
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
    # Predazione
    :attack,
    :defend,
    # Self-inspection
    :get_ip,
    :get_size,
    :read_self,
    # Replicazione
    :allocate,
    :write_child,
    :divide,
    # Memoria locale
    :store,
    :load,
    # Plasmid / horizontal gene transfer
    :make_plasmid,
    :conjugate
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
