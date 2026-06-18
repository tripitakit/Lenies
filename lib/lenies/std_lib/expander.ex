defmodule Lenies.StdLib.Expander do
  @moduledoc """
  Concretises a Snippet's body template into an `%InsertPlan{}` against the
  current genome + caret. Pure — no UI.
  """
  alias Lenies.StdLib.{Snippet, InsertPlan}

  @spec expand(Snippet.t(), map(), LeniesWeb.GenomeBuffer.t(), {atom(), non_neg_integer()}) ::
          {:ok, InsertPlan.t()} | {:error, atom()}
  def expand(%Snippet{kind: :param, body: body}, params, genome, _caret) do
    case concretise_inline(body, params) do
      {:ok, ops} -> finalize(genome, %InsertPlan{caret_ops: ops})
      {:error, r} -> {:error, r}
    end
  end

  def expand(%Snippet{kind: :inline, body: body}, _params, genome, _caret) do
    finalize(genome, %InsertPlan{caret_ops: body})
  end

  def expand(%Snippet{kind: :function, id: id, body: body}, _params, genome, _caret) do
    case anchor_for(genome, id) do
      {:ok, anchor} ->
        finalize(genome, %InsertPlan{caret_ops: call_ops(anchor)})

      :undefined ->
        with {:ok, anchor} <- allocate_anchor(genome) do
          appended = [:push0] ++ concretise_function_body(body, anchor)

          finalize(
            genome,
            %InsertPlan{
              caret_ops: call_ops(anchor),
              appended_ops: appended,
              anchor: anchor,
              comments: [{1, "stdlib:#{id}:anchor=#{bits_str(anchor)}"}]
            }
          )
        end
    end
  end

  defp finalize(genome, plan), do: guard_length(genome, plan)

  defp guard_length(genome, %InsertPlan{} = plan) do
    {_min, max} = Lenies.Config.codeome_length_bounds()
    added = length(plan.caret_ops) + length(plan.appended_ops)
    if length(genome.chromosome) + added > max, do: {:error, :too_long}, else: {:ok, plan}
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
      n when is_integer(n) ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
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

  # ---------------------------------------------------------------------------
  # Function snippet helpers
  # ---------------------------------------------------------------------------

  defp call_ops(anchor), do: [:call_t | Lenies.Interpreter.Template.complement(anchor)]

  defp concretise_function_body(body, anchor) do
    Enum.flat_map(body, fn
      {:anchor, :self} -> anchor
      {:sep} -> [:push0]
      op when is_atom(op) -> [op]
    end)
  end

  defp bits_str(anchor),
    do:
      Enum.map_join(anchor, "", fn
        :nop_1 -> "1"
        :nop_0 -> "0"
      end)

  defp anchor_for(genome, id) do
    genome.comments
    |> Map.values()
    |> Enum.find_value(:undefined, fn txt ->
      case Regex.run(~r/^stdlib:#{Regex.escape(id)}:anchor=([01]{5})$/, txt) do
        [_, pat] ->
          {:ok,
           Enum.map(String.graphemes(pat), fn
             "1" -> :nop_1
             "0" -> :nop_0
           end)}

        _ ->
          nil
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Anchor allocation
  # ---------------------------------------------------------------------------

  @anchor_len 5

  @doc "Allocate a free 5-bit anchor pattern (list of :nop_0/:nop_1) for the genome."
  @spec allocate_anchor(LeniesWeb.GenomeBuffer.t()) ::
          {:ok, [atom()]} | {:error, :anchor_namespace_full}
  def allocate_anchor(genome) do
    used = used_anchor_bits(genome)

    free =
      0..(trunc(:math.pow(2, @anchor_len)) - 1)
      |> Enum.map(&bits/1)
      |> Enum.find(fn b -> not MapSet.member?(used, b) and not MapSet.member?(used, flip(b)) end)

    case free do
      nil ->
        {:error, :anchor_namespace_full}

      b ->
        {:ok,
         Enum.map(b, fn
           1 -> :nop_1
           0 -> :nop_0
         end)}
    end
  end

  defp bits(i),
    do: i |> Integer.digits(2) |> then(&(List.duplicate(0, @anchor_len - length(&1)) ++ &1))

  defp flip(b), do: Enum.map(b, &(1 - &1))

  defp used_anchor_bits(genome) do
    from_comments =
      genome.comments
      |> Map.values()
      |> Enum.flat_map(fn txt ->
        case Regex.run(~r/anchor=([01]{5})/, txt) do
          [_, pat] -> [pat |> String.graphemes() |> Enum.map(&String.to_integer/1)]
          _ -> []
        end
      end)

    from_runs =
      genome.chromosome
      |> Enum.chunk_every(@anchor_len, 1, :discard)
      |> Enum.filter(&Enum.all?(&1, fn op -> op in [:nop_0, :nop_1] end))
      |> Enum.map(fn run ->
        Enum.map(run, fn
          :nop_1 -> 1
          :nop_0 -> 0
        end)
      end)

    MapSet.new(from_comments ++ from_runs)
  end
end
