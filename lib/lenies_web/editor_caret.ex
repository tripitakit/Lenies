defmodule LeniesWeb.EditorCaret do
  @moduledoc """
  Pure caret/selection math for the codeome editor.

  State is a `{caret, anchor}` pair of **gap** indices in `0..len`. A gap `i`
  sits *before* block `i`; gap `len` is at the end. `caret == anchor` is a
  collapsed caret (no selection); otherwise blocks
  `min(caret,anchor) .. max(caret,anchor) - 1` are selected.

  This module is the single source of truth for caret behavior and has no
  LiveView dependency, so it is unit-tested in isolation.
  """

  @type t :: {non_neg_integer(), non_neg_integer()}

  @doc "Inclusive block range `{lo, hi}` for the selection, or `nil` if collapsed."
  @spec derive_range(t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def derive_range({c, a}) when c == a, do: nil
  def derive_range({c, a}), do: {min(c, a), max(c, a) - 1}

  @doc "Collapsed caret at `gap`."
  @spec place(non_neg_integer()) :: t()
  def place(gap), do: {gap, gap}

  @doc "Selection of exactly block `i` (caret on its right edge)."
  @spec select_block(non_neg_integer()) :: t()
  def select_block(i), do: {i + 1, i}

  @type dir :: :up | :down

  @doc "Move the caret one gap, collapsing the selection."
  @spec move(t(), dir(), non_neg_integer()) :: t()
  def move({c, _a}, :up, _len), do: place(max(c - 1, 0))
  def move({c, _a}, :down, len), do: place(min(c + 1, len))

  @doc "Move the caret one gap, keeping the anchor (extends the selection)."
  @spec extend(t(), dir(), non_neg_integer()) :: t()
  def extend({c, a}, :up, _len), do: {max(c - 1, 0), a}
  def extend({c, a}, :down, len), do: {min(c + 1, len), a}

  @doc "Extend the selection so the caret lands on `gap`, keeping the anchor."
  @spec extend_to_gap(t(), non_neg_integer()) :: t()
  def extend_to_gap({_c, a}, gap), do: {gap, a}

  @doc """
  Extend the selection through block `i`, keeping the anchor. Forward of the
  anchor the caret lands on the block's right edge (`i + 1`); behind it, on the
  left edge (`i`).
  """
  @spec extend_to_block(t(), non_neg_integer()) :: t()
  def extend_to_block({_c, a}, i) do
    caret = if i >= a, do: i + 1, else: i
    {caret, a}
  end

  @doc "Clamp both ends into `0..len`."
  @spec clamp(t(), non_neg_integer()) :: t()
  def clamp({c, a}, len), do: {bound(c, len), bound(a, len)}

  defp bound(x, len), do: x |> max(0) |> min(len)

  @doc "Collapsed caret just past a run of `count` opcodes inserted at `at`."
  @spec after_insert(non_neg_integer(), non_neg_integer()) :: t()
  def after_insert(at, count), do: place(at + count)

  @doc "Collapsed caret at the start of a just-deleted range."
  @spec after_delete_range({non_neg_integer(), non_neg_integer()}) :: t()
  def after_delete_range({lo, _hi}), do: place(lo)

  @doc "Selection covering a run of `count` opcodes inserted at `at`."
  @spec select_inserted(non_neg_integer(), non_neg_integer()) :: t()
  def select_inserted(at, count), do: {at + count, at}
end
