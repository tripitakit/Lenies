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

  @doc """
  Copy the inclusive `{lo, hi}` range out of the buffer. `hi` is clamped to
  the last valid index; if `lo` is past the end, the result is empty.
  """
  @spec slice(buffer(), {non_neg_integer(), non_neg_integer()}) :: buffer()
  def slice(buffer, {lo, hi}) when lo >= 0 and hi >= lo do
    Enum.slice(buffer, lo..hi)
  end

  @doc """
  Delete the inclusive `{lo, hi}` range from the buffer. `hi` is clamped to
  the end; if `lo` is past the end the buffer is returned unchanged (no-op).
  """
  @spec delete_range(buffer(), {non_neg_integer(), non_neg_integer()}) :: buffer()
  def delete_range(buffer, {lo, hi}) when lo >= 0 and hi >= lo do
    {before, rest} = Enum.split(buffer, lo)
    before ++ Enum.drop(rest, hi - lo + 1)
  end

  @doc "Insert a list of opcodes at `index` (clamped to the buffer length)."
  @spec insert_many(buffer(), non_neg_integer(), [atom()]) :: buffer()
  def insert_many(buffer, index, opcodes) when index >= 0 and is_list(opcodes) do
    clamped = min(index, length(buffer))
    {before, rest} = Enum.split(buffer, clamped)
    before ++ opcodes ++ rest
  end

  @doc """
  Move the inclusive block range `{lo, hi}` so it lands at gap `to_gap`
  (gap coordinates of the *original* buffer). Dropping inside the moved range
  is a no-op.
  """
  @spec move_range(buffer(), {non_neg_integer(), non_neg_integer()}, non_neg_integer()) ::
          buffer()
  def move_range(buffer, {lo, hi}, to_gap) when lo >= 0 and hi >= lo and to_gap >= 0 do
    slice = Enum.slice(buffer, lo..hi)
    without = delete_range(buffer, {lo, hi})
    removed = hi - lo + 1

    adj =
      cond do
        to_gap <= lo -> to_gap
        to_gap <= hi + 1 -> lo
        true -> to_gap - removed
      end

    insert_many(without, adj, slice)
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

  @doc """
  Static energy budget for **one linear pass** through the codeome (each
  opcode executed exactly once, no branches taken). Drives the editor's
  energy mini-panel — gives a quick feel for whether a codeome can pay
  for itself before you commit to spawning it.

  * `cost` — sum of `Lenies.Codeome.Costs.cost/2` over the buffer.
    Template-jumps (`:jmp_t`, `:jz_t`, `:jnz_t`, `:call_t`) read the
    actual run of `:nop_0`/`:nop_1` immediately after the opcode (capped
    at the interpreter's `template_max_len`, default 8). `:allocate` is
    priced with `size = alloc_size` (defaults to `length(buffer)`; the
    unified editor passes the chromosome length so plasmid regions don't
    inflate replication cost). `:ret` is always priced with `t_len = 0`
    since it doesn't consume a template at runtime.
  * `max_gain` — `n_eat × cell_cap + n_attack × attack_damage`, where
    `cell_cap = 3 × eat_amount` is the per-cell resource cap. A single
    `:eat` empties the whole cell, so its best case is a full oasis cell
    at the cap. Strict upper bound — assumes every EAT lands on a full
    cell and every ATTACK succeeds (real hit rates are well below 1).
  * `net = max_gain - cost` is signed; the UI colours it.

  `eat_amount` and `attack_damage` are passed in so the function stays
  pure and the caller controls when to re-read tuning values.

  Note: this is NOT the multi-tick replication cycle cost from
  `docs/manual/08-energy-economy.md` — that requires understanding the
  buffer's loops. A single linear pass is a strict lower bound on
  per-cycle cost and an over-estimate of per-cycle gain.
  """
  @spec economics(buffer(), number(), number(), keyword()) :: %{
          cost: float(),
          max_gain: float(),
          net: float(),
          n_eat: non_neg_integer(),
          n_attack: non_neg_integer(),
          eat_amount: number(),
          cell_cap: number(),
          attack_damage: number(),
          alloc_size: non_neg_integer()
        }
  def economics(buffer, eat_amount, attack_damage, opts \\ []) do
    alloc_size = Keyword.get(opts, :alloc_size, length(buffer))
    cost = pass_cost(buffer, alloc_size)
    n_eat = Enum.count(buffer, &(&1 == :eat))
    n_attack = Enum.count(buffer, &(&1 == :attack))
    # :eat empties the WHOLE cell, so a single eat can yield up to the per-cell
    # resource cap (3 × eat_amount) — a full oasis cell. max_gain is the strict
    # upper bound (every eat on a full cell, every attack landing).
    cell_cap = 3 * eat_amount
    max_gain = (n_eat * cell_cap + n_attack * attack_damage) * 1.0

    %{
      cost: cost,
      max_gain: max_gain,
      net: max_gain - cost,
      n_eat: n_eat,
      n_attack: n_attack,
      eat_amount: eat_amount,
      cell_cap: cell_cap,
      attack_damage: attack_damage,
      alloc_size: alloc_size
    }
  end

  defp pass_cost(buffer, alloc_size) do
    template_max_len = Application.get_env(:lenies, :template_max_len, 8)
    buffer_tuple = List.to_tuple(buffer)

    0..(tuple_size(buffer_tuple) - 1)//1
    |> Enum.reduce(0.0, fn idx, acc ->
      op = elem(buffer_tuple, idx)

      cost =
        cond do
          op in [:jmp_t, :jz_t, :jnz_t, :call_t] ->
            Lenies.Codeome.Costs.cost(
              op,
              template_len_at(buffer_tuple, idx + 1, template_max_len)
            )

          op == :allocate ->
            Lenies.Codeome.Costs.cost(:allocate, alloc_size)

          true ->
            Lenies.Codeome.Costs.cost(op, 0)
        end

      acc + cost
    end)
    |> Float.round(2)
  end

  defp template_len_at(buffer_tuple, start, max_len) do
    size = tuple_size(buffer_tuple)
    take_while_nops(buffer_tuple, start, min(start + max_len, size), 0)
  end

  defp take_while_nops(_buf, at, stop, count) when at >= stop, do: count

  defp take_while_nops(buf, at, stop, count) do
    case elem(buf, at) do
      op when op in [:nop_0, :nop_1] -> take_while_nops(buf, at + 1, stop, count + 1)
      _ -> count
    end
  end
end
