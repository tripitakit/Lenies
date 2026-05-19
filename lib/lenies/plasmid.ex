defmodule Lenies.Plasmid do
  @moduledoc """
  A short opcode buffer that a Lenie can transfer to an adjacent Lenie via
  the `:conjugate` opcode. Plasmids inherit vertically through `:divide`
  alongside the codeome, and spread horizontally through conjugation.

  The MVP enforces a hard length cap of 64 opcodes per plasmid. The buffer
  is a plain Elixir list (not a tuple like `Lenies.Codeome`) because
  plasmids are small and the cost of `Tuple.to_list` round-trips would
  dominate. See `docs/superpowers/specs/2026-05-19-plasmid-conjugation-design.md`.
  """

  @max_length 64

  defstruct opcodes: []

  @type t :: %__MODULE__{opcodes: [atom()]}

  @spec new([atom()]) :: t()
  def new(opcodes) when is_list(opcodes), do: %__MODULE__{opcodes: opcodes}

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{opcodes: ops}), do: length(ops)

  @doc "Whether `len` is in the valid range for `:make_plasmid` (1..64)."
  @spec valid_length?(integer()) :: boolean()
  def valid_length?(len) when is_integer(len), do: len >= 1 and len <= @max_length
  def valid_length?(_), do: false

  @spec max_length() :: pos_integer()
  def max_length, do: @max_length
end
