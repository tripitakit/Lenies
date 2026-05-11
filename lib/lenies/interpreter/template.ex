defmodule Lenies.Interpreter.Template do
  @moduledoc """
  Template addressing alla Tierra: i salti leggono il template di `:nop_0`/`:nop_1`
  che li segue, poi cercano nel Codeome il complemento (bit invertiti) entro un
  raggio limitato. Vedi spec §4.2.

  Una mutazione su un :nop _può_ avere effetto selettivo (modifica quale
  template fa match) ma _può_ anche essere genuinamente neutrale (junk DNA).
  Vedi spec §5.3.
  """

  alias Lenies.Codeome

  @type template :: [atom()]

  @doc """
  Estrae il template che inizia in posizione `from` del Codeome.

  Restituisce `{template_list, length}`. Il template è la sequenza più lunga
  di `:nop_0`/`:nop_1` da `from`, cappata a `max_len`.
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

  @doc "Inverte i bit del template: `:nop_0 ↔ :nop_1`."
  @spec complement(template()) :: template()
  def complement(template) do
    Enum.map(template, fn
      :nop_0 -> :nop_1
      :nop_1 -> :nop_0
    end)
  end

  @doc """
  Cerca il complemento di `template` nel Codeome a partire da `from`.

  Cerca prima in avanti fino a `radius`, poi all'indietro. Ritorna
  `{:ok, position}` della prima occorrenza del complemento, o `:not_found`.
  La posizione restituita è l'indice del primo nop del match.
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
