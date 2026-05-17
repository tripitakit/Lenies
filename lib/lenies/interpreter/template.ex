defmodule Lenies.Interpreter.Template do
  @moduledoc """
  Tierra-style template addressing: jump instructions read the `:nop_0`/`:nop_1`
  template that follows them, then search the Codeome for the complement (bits
  flipped) within a limited radius. See spec §4.2.

  A mutation on a :nop _may_ have a selective effect (changes which template
  matches) but _may_ also be genuinely neutral (junk DNA). See spec §5.3.
  """

  alias Lenies.Codeome

  @type template :: [atom()]

  @doc """
  Extracts the template starting at position `from` in the Codeome.

  Returns `{template_list, length}`. The template is the longest contiguous
  sequence of `:nop_0`/`:nop_1` starting at `from`, capped at `max_len`.
  """
  @spec extract(Codeome.t(), non_neg_integer(), pos_integer()) :: {template(), non_neg_integer()}
  def extract(%Codeome{} = c, from, max_len) do
    take_nops(c, from, max_len, [])
  end

  defp take_nops(_c, _at, 0, acc), do: {Enum.reverse(acc), length(acc)}

  defp take_nops(c, at, remaining, acc) do
    op = Codeome.at(c, at)

    if op in [:nop_0, :nop_1] do
      take_nops(c, at + 1, remaining - 1, [op | acc])
    else
      {Enum.reverse(acc), length(acc)}
    end
  end

  @doc "Flips the template bits: `:nop_0 ↔ :nop_1`."
  @spec complement(template()) :: template()
  def complement(template) do
    Enum.map(template, fn
      :nop_0 -> :nop_1
      :nop_1 -> :nop_0
    end)
  end

  @doc """
  Searches for the complement of `template` in the Codeome starting from `from`.

  Searches forward up to `radius` positions first, then backward. Returns
  `{:ok, position}` for the first occurrence of the complement, or `:not_found`.
  The returned position is the index of the first nop of the match.
  """
  @spec find_complement(Codeome.t(), template(), non_neg_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | :not_found
  def find_complement(_c, [], _from, _radius), do: :not_found

  def find_complement(%Codeome{} = c, template, from, radius) do
    target = complement(template)
    size = Codeome.size(c)

    case search_forward(c, target, from + 1, radius, size) do
      {:ok, _pos} = ok -> ok
      :not_found -> search_backward(c, target, from - 1, radius, size)
    end
  end

  defp search_forward(_c, _target, _at, 0, _size), do: :not_found

  defp search_forward(c, target, at, remaining, size) do
    if matches_at?(c, at, target) do
      {:ok, Integer.mod(at, size)}
    else
      search_forward(c, target, at + 1, remaining - 1, size)
    end
  end

  defp search_backward(_c, _target, _at, 0, _size), do: :not_found

  defp search_backward(c, target, at, remaining, size) do
    if matches_at?(c, at, target) do
      {:ok, Integer.mod(at, size)}
    else
      search_backward(c, target, at - 1, remaining - 1, size)
    end
  end

  defp matches_at?(c, at, target) do
    Enum.with_index(target)
    |> Enum.all?(fn {expected, offset} ->
      Codeome.at(c, at + offset) == expected
    end)
  end
end
