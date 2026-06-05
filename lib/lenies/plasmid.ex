defmodule Lenies.Plasmid do
  @moduledoc """
  A short opcode buffer that a Lenie can transfer to an adjacent Lenie via
  the `:conjugate` opcode. Plasmids are extra-chromosomal: they are kept
  separately from the chromosome (`Lenies.Codeome`) and never fused into it.
  They spread horizontally through conjugation and inherit vertically at
  `:divide`, where each plasmid segregates to the child stochastically (kept
  with probability `1 - plasmid_loss_probability`). Their opcodes execute by
  concatenation into the host's execution stream (the Lenie's `exec_codeome`),
  expressed only where execution reaches them (fall-through).

  The MVP enforces a hard length cap of 64 opcodes per plasmid. The buffer
  is a plain Elixir list (not a tuple like `Lenies.Codeome`) because
  plasmids are small and the cost of `Tuple.to_list` round-trips would
  dominate. See `docs/superpowers/specs/2026-05-19-plasmid-conjugation-design.md`.
  """

  @max_length 64

  defstruct opcodes: []

  @type t :: %__MODULE__{opcodes: [Lenies.Codeome.opcode()]}

  @doc """
  Raw (unchecked) constructor. Accepts any list of opcodes, including
  empty or oversized lists. The `:make_plasmid` opcode dispatch is
  responsible for calling `valid_length?/1` before calling this; other
  callers (e.g. tests, snapshot restore) may legitimately need to
  construct off-boundary plasmids.
  """
  @spec new([Lenies.Codeome.opcode()]) :: t()
  def new(opcodes) when is_list(opcodes), do: %__MODULE__{opcodes: opcodes}

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{opcodes: ops}), do: length(ops)

  @doc "Whether `len` is in the valid range for `:make_plasmid` (1..64)."
  @spec valid_length?(integer()) :: boolean()
  def valid_length?(len) when is_integer(len), do: len >= 1 and len <= @max_length
  def valid_length?(_), do: false

  @doc "The hard cap on plasmid opcode count (#{@max_length})."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length
end
