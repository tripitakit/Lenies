defmodule Lenies.StdLib.Expander do
  @moduledoc """
  Concretises a Snippet's body template into an `%InsertPlan{}` against the
  current genome + caret. Pure — no UI.
  """
  alias Lenies.StdLib.{Snippet, InsertPlan}

  @spec expand(Snippet.t(), map(), LeniesWeb.GenomeBuffer.t(), {atom(), non_neg_integer()}) ::
          {:ok, InsertPlan.t()} | {:error, atom()}
  def expand(%Snippet{kind: :param, body: body}, params, _genome, _caret) do
    case concretise_inline(body, params) do
      {:ok, ops} -> {:ok, %InsertPlan{caret_ops: ops}}
      {:error, r} -> {:error, r}
    end
  end

  def expand(%Snippet{kind: :inline, body: body}, _params, _genome, _caret) do
    {:ok, %InsertPlan{caret_ops: body}}
  end

  # Expand a placeholder list that needs NO anchors (const only) into opcodes.
  defp concretise_inline(body, params) do
    Enum.reduce_while(body, {:ok, []}, fn
      {:const, key}, {:ok, acc} ->
        case const_ops(fetch_int(params, key)) do
          {:ok, ops} -> {:cont, {:ok, acc ++ ops}}
          err -> {:halt, err}
        end

      op, {:ok, acc} when is_atom(op) ->
        {:cont, {:ok, acc ++ [op]}}
    end)
  end

  defp fetch_int(params, key) do
    case params[Atom.to_string(key)] || params[key] do
      n when is_integer(n) -> n
      s when is_binary(s) -> (case Integer.parse(s) do {n, _} -> n; :error -> nil end)
      _ -> nil
    end
  end

  # Cheapest exact build of K>=1: push1 (MSB), then double-and-add per bit.
  defp const_ops(k) when is_integer(k) and k >= 1 do
    [_msb | rest] = Integer.digits(k, 2)
    ops =
      Enum.reduce(rest, [:push1], fn bit, acc ->
        doubled = acc ++ [:dup, :add]
        if bit == 1, do: doubled ++ [:push1, :add], else: doubled
      end)
    {:ok, ops}
  end
  defp const_ops(_), do: {:error, :bad_param}
end
