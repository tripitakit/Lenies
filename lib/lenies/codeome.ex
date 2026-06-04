defmodule Lenies.Codeome do
  @moduledoc """
  A Lenie's Codeome: an opcode sequence that is both genome and program.

  Internally represented as an Elixir tuple for O(1) lookup (`elem/2`).
  All functions respect the circular arithmetic of `at/2` — the Codeome
  is effectively a ring, to support template addressing (see spec §4.2
  and §5.1) which searches for the complement of a template in both
  directions.

  See `Lenies.Interpreter` for execution and `Lenies.Codeome.Opcodes`
  for the opcode whitelist.
  """

  @type opcode :: atom()
  @typedoc """
  Optional precomputed jump-target cache: `%{ip => {t_len, find_result}}` for
  every template-jump opcode in the codeome (see `Lenies.Interpreter.index_jumps/1`).
  `nil` means "not precomputed" — the interpreter then resolves jumps live.
  """
  @type jump_index :: nil | %{non_neg_integer() => {non_neg_integer(), term()}}
  @type t :: %__MODULE__{opcodes: tuple(), jump_index: jump_index()}

  defstruct opcodes: {}, jump_index: nil

  @spec from_list([opcode()]) :: t()
  def from_list(list) when is_list(list) do
    # A fresh codeome carries no jump_index — building one is opt-in (only the
    # long-lived Lenie execution path bothers; editor/disassembler/stepper skip
    # it). This also guarantees a rebuilt/mutated codeome can never carry a
    # stale index.
    %__MODULE__{opcodes: List.to_tuple(list)}
  end

  @doc "Attach a precomputed `jump_index` (see `Lenies.Interpreter.index_jumps/1`)."
  @spec put_jump_index(t(), %{non_neg_integer() => {non_neg_integer(), term()}}) :: t()
  def put_jump_index(%__MODULE__{} = c, index) when is_map(index) do
    %{c | jump_index: index}
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{opcodes: ops}), do: tuple_size(ops)

  @doc """
  Returns the opcode at position `i`, with wrap modulo `size`. Supports
  negative indices (e.g. `-1` → last opcode).
  """
  @spec at(t(), integer()) :: opcode()
  def at(%__MODULE__{opcodes: ops}, i) do
    n = tuple_size(ops)
    elem(ops, Integer.mod(i, n))
  end

  @spec to_list(t()) :: [opcode()]
  def to_list(%__MODULE__{opcodes: ops}), do: Tuple.to_list(ops)

  @doc """
  Structural hash of the Codeome, as a hex string. Same input → same hash.
  Used as `codeome_hash` for species clustering.

  Implemented with `:erlang.phash2/2` over the 0..2^32 range (a 32-bit hash,
  not 64-bit). `phash2` is not guaranteed stable across Erlang/OTP major
  versions, so persisted snapshots from a different OTP major may cluster
  differently — fine for live clustering, but don't treat the value as a
  durable cross-version identifier.
  """
  @spec hash(t()) :: binary()
  def hash(%__MODULE__{opcodes: ops}) do
    :erlang.phash2(ops, 4_294_967_296) |> Integer.to_string(16)
  end
end
