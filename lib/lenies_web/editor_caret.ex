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

  @spec collapsed?(t()) :: boolean()
  def collapsed?({c, a}), do: c == a

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
end
