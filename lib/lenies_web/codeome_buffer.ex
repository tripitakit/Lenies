defmodule LeniesWeb.CodeomeBuffer do
  @moduledoc """
  Pure operations on a list-of-opcode-atoms buffer used by the codeome editor.

  Each operation returns a new buffer; nothing in-place. The component owns
  the assign; this module owns the transformations.
  """

  @type buffer :: [atom()]

  @type validation_error ::
          {:too_short, [min: pos_integer(), got: non_neg_integer()]}
          | {:too_long, [max: pos_integer(), got: non_neg_integer()]}
          | {:insufficient_non_nops, [min: pos_integer(), got: non_neg_integer()]}

  @spec from_codeome(Lenies.Codeome.t()) :: buffer()
  def from_codeome(codeome), do: Lenies.Codeome.to_list(codeome)

  @spec to_codeome(buffer()) :: Lenies.Codeome.t()
  def to_codeome(buffer), do: Lenies.Codeome.from_list(buffer)

  @spec insert(buffer(), non_neg_integer(), atom()) :: buffer()
  def insert(buffer, index, opcode) when is_atom(opcode) and index >= 0 do
    clamped = min(index, length(buffer))
    {before, rest} = Enum.split(buffer, clamped)
    before ++ [opcode] ++ rest
  end

  @spec delete(buffer(), non_neg_integer()) :: buffer()
  def delete(buffer, index) when index >= 0 do
    case Enum.split(buffer, index) do
      {before, [_removed | rest]} -> before ++ rest
      {_, []} -> buffer
    end
  end

  @spec replace(buffer(), non_neg_integer(), atom()) :: buffer()
  def replace(buffer, index, opcode) when is_atom(opcode) and index >= 0 do
    case Enum.split(buffer, index) do
      {before, [_old | rest]} -> before ++ [opcode] ++ rest
      {_, []} -> buffer
    end
  end

  @spec move(buffer(), non_neg_integer(), non_neg_integer()) :: buffer()
  def move(buffer, from, to) when from >= 0 and to >= 0 do
    cond do
      from == to ->
        buffer

      from >= length(buffer) ->
        buffer

      true ->
        {item, without} = List.pop_at(buffer, from)
        clamped_to = min(to, length(without))
        List.insert_at(without, clamped_to, item)
    end
  end

  @spec validate(buffer()) ::
          {:ok, %{len: non_neg_integer(), non_nops: non_neg_integer()}}
          | {:error, [validation_error()]}
  def validate(buffer) do
    {min_len, max_len} = Lenies.Config.codeome_length_bounds()
    min_non_nops = Lenies.Config.min_viable_codeome_opcodes()
    len = length(buffer)
    non_nops = Enum.count(buffer, &(&1 not in [:nop_0, :nop_1]))

    errs =
      [
        len < min_len && {:too_short, min: min_len, got: len},
        len > max_len && {:too_long, max: max_len, got: len},
        non_nops < min_non_nops &&
          {:insufficient_non_nops, min: min_non_nops, got: non_nops}
      ]
      |> Enum.filter(& &1)

    if errs == [], do: {:ok, %{len: len, non_nops: non_nops}}, else: {:error, errs}
  end
end
