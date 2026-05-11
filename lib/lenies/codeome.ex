defmodule Lenies.Codeome do
  @moduledoc """
  Il Codeome di un Lenie: sequenza di opcode che è sia genoma sia programma.

  Internamente rappresentato come tupla Elixir per lookup O(1) (`elem/2`).
  Tutte le funzioni rispettano l'aritmetica circolare di `at/2` — il Codeome
  è effettivamente un anello, per supportare il template addressing (vedi
  spec §4.2 e §5.1) che cerca il complemento del template nei due versi.

  Vedi `Lenies.Interpreter` per l'esecuzione e `Lenies.Codeome.Opcodes`
  per la whitelist degli opcode validi.
  """

  @type opcode :: atom()
  @type t :: %__MODULE__{opcodes: tuple()}

  defstruct opcodes: {}

  @spec from_list([opcode()]) :: t()
  def from_list(list) when is_list(list) do
    %__MODULE__{opcodes: List.to_tuple(list)}
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{opcodes: ops}), do: tuple_size(ops)

  @doc """
  Ritorna l'opcode in posizione `i`, con wrap modulo `size`. Supporta
  indici negativi (es. `-1` → ultimo opcode).
  """
  @spec at(t(), integer()) :: opcode()
  def at(%__MODULE__{opcodes: ops}, i) do
    n = tuple_size(ops)
    elem(ops, Integer.mod(i, n))
  end

  @spec to_list(t()) :: [opcode()]
  def to_list(%__MODULE__{opcodes: ops}), do: Tuple.to_list(ops)

  @doc """
  Hash strutturale del Codeome (xxhash a 64 bit). Stesso input → stesso hash.
  Usato come `codeome_hash` per il clustering di specie.
  """
  @spec hash(t()) :: binary()
  def hash(%__MODULE__{opcodes: ops}) do
    :erlang.phash2(ops, 4_294_967_296) |> Integer.to_string(16)
  end
end
