defmodule Lenies.StdLib.Expander do
  @moduledoc """
  Concretises a Snippet's body template into an `%InsertPlan{}` against the
  current genome + caret. Pure — no UI.
  """
  alias Lenies.StdLib.{Snippet, InsertPlan}

  @cond_op %{jz: :jz_t, jnz: :jnz_t, jlt: :jlt_t, jgt: :jgt_t, jmp: :jmp_t}

  @spec expand(Snippet.t(), map(), LeniesWeb.GenomeBuffer.t(), {atom(), non_neg_integer()}) ::
          {:ok, InsertPlan.t()} | {:error, atom()}
  def expand(%Snippet{kind: kind, body: body}, params, genome, _caret)
      when kind in [:inline, :param] do
    case compile_body(body, params, genome) do
      {:ok, ops} -> finalize(genome, %InsertPlan{caret_ops: ops})
      {:error, r} -> {:error, r}
    end
  end

  def expand(%Snippet{kind: :function, id: id, body: body}, _params, genome, _caret) do
    case anchor_for(genome, id) do
      {:ok, anchor} ->
        finalize(genome, %InsertPlan{caret_ops: call_ops(anchor)})

      :undefined ->
        with {:ok, anchor} <- allocate_anchor(genome),
             body1 = substitute_anchor(body, anchor),
             anchor_bits = MapSet.new([bits(anchor_to_int(anchor))]),
             {:ok, ops} <- compile_body(body1, %{}, genome, anchor_bits) do
          appended = [:push0] ++ ops

          finalize(genome, %InsertPlan{
            caret_ops: call_ops(anchor),
            appended_ops: appended,
            anchor: anchor,
            comments: [{1, "stdlib:#{id}:anchor=#{bits_str(anchor)}"}]
          })
        end
    end
  end

  defp finalize(genome, plan), do: guard_length(genome, plan)

  defp guard_length(genome, %InsertPlan{} = plan) do
    {_min, max} = Lenies.Config.codeome_length_bounds()
    added = length(plan.caret_ops) + length(plan.appended_ops)
    if length(genome.chromosome) + added > max, do: {:error, :too_long}, else: {:ok, plan}
  end

  defp compile_body(body, params, genome, extra_used \\ MapSet.new()) do
    items = expand_repeats(body, 0, 0) |> elem(0)
    labels = items |> Enum.flat_map(fn {:label, n} -> [n]; _ -> [] end) |> Enum.uniq()

    with {:ok, pats} <- allocate_labels(genome, length(labels), extra_used) do
      pmap = labels |> Enum.zip(pats) |> Map.new()
      emit(items, params, pmap)
    end
  end

  @repeat_slot 2
  # Maximum nesting depth is 2 (slots 2 and 3), staying within slots 0-3.
  @repeat_max_depth 1

  # Public entry: called from compile_body with counter=0, depth=0
  defp expand_repeats(items, counter, depth) do
    Enum.reduce(items, {[], counter}, fn
      {:repeat, key, body}, {acc, c} ->
        lbl = String.to_atom("__rpt#{c}")
        slot = @repeat_slot + depth
        {inner, c2} = expand_repeats(body, c + 1, min(depth + 1, @repeat_max_depth))

        loop =
          [{:const, key}, {:const, slot}, :store, {:label, lbl}] ++
            inner ++
            [
              {:const, slot}, :load, :push1, :sub, {:const, slot}, :store,
              {:const, slot}, :load, {:branch, :jnz, lbl}
            ]

        {acc ++ loop, c2}

      item, {acc, c} ->
        {acc ++ [item], c}
    end)
  end

  defp emit(items, params, pmap) do
    {ops, _prev} =
      Enum.reduce(items, {[], nil}, fn item, {acc, prev} ->
        {acc ++ emit_item(item, params, pmap, prev), item}
      end)

    if Enum.any?(ops, &(&1 == :__bad_param__)),
      do: {:error, :bad_param},
      else: {:ok, ops}
  end

  defp emit_item({:const, k}, params, _m, _prev) do
    case const_ops(resolve_int(k, params)) do
      {:ok, ops} -> ops
      {:error, _} -> [:__bad_param__]
    end
  end

  defp emit_item({:require_pos, k}, params, _m, _prev) do
    case resolve_int(k, params) do
      n when is_integer(n) and n >= 1 -> []
      _ -> [:__bad_param__]
    end
  end

  defp emit_item({:branch, cond, name}, _p, m, _prev),
    do: [Map.fetch!(@cond_op, cond) | Lenies.Interpreter.Template.complement(Map.fetch!(m, name))]

  defp emit_item({:label, name}, _p, m, prev) do
    sep = if match?({:branch, _, _}, prev), do: [:push0], else: []
    sep ++ Map.fetch!(m, name)
  end

  defp emit_item(op, _p, _m, _prev) when is_atom(op), do: [op]

  defp resolve_int(k, _params) when is_integer(k), do: k
  defp resolve_int(k, params) when is_atom(k), do: fetch_int(params, k)

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

  # Cheapest exact build of K>=0: 0 maps to push0; K>=1 uses a doubling chain.
  defp const_ops(0), do: {:ok, [:push0]}

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

  defp substitute_anchor(body, anchor) do
    Enum.flat_map(body, fn
      {:anchor, :self} -> anchor
      {:sep} -> [:push0]
      other -> [other]
    end)
  end

  defp anchor_to_int(anchor) do
    anchor
    |> Enum.map(fn :nop_1 -> 1; :nop_0 -> 0 end)
    |> Integer.undigits(2)
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

  @doc "Allocate n distinct genome-global-unique 5-bit patterns (lists of :nop_0/:nop_1)."
  @spec allocate_labels(LeniesWeb.GenomeBuffer.t(), non_neg_integer()) ::
          {:ok, [[atom()]]} | {:error, :anchor_namespace_full}
  def allocate_labels(genome, n), do: allocate_labels(genome, n, MapSet.new())

  @spec allocate_labels(LeniesWeb.GenomeBuffer.t(), non_neg_integer(), MapSet.t()) ::
          {:ok, [[atom()]]} | {:error, :anchor_namespace_full}
  def allocate_labels(_genome, 0, _extra_used), do: {:ok, []}

  def allocate_labels(genome, n, extra_used) when is_integer(n) and n > 0 do
    all = 0..(trunc(:math.pow(2, @anchor_len)) - 1) |> Enum.map(&bits/1)
    base_used = MapSet.union(used_anchor_bits(genome), extra_used)

    Enum.reduce_while(1..n, {:ok, [], base_used}, fn _, {:ok, pats, used} ->
      case Enum.find(all, fn b ->
             not MapSet.member?(used, b) and not MapSet.member?(used, flip(b))
           end) do
        nil ->
          {:halt, {:error, :anchor_namespace_full}}

        b ->
          pat = Enum.map(b, fn 1 -> :nop_1; 0 -> :nop_0 end)
          {:cont, {:ok, pats ++ [pat], MapSet.put(used, b)}}
      end
    end)
    |> case do
      {:ok, pats, _} -> {:ok, pats}
      err -> err
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
