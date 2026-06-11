defmodule LeniesWeb.GenomeCaret do
  @moduledoc """
  Caret/selection math over a sectioned genome. An address is
  `{section, gap}` with gaps in `0..len(section)`. State is a
  `{caret, anchor}` pair of addresses; both ends always live in the SAME
  section (v1 invariant: a selection never crosses a section divider —
  cross-section moves collapse the selection). Per-section gap math
  delegates to `LeniesWeb.EditorCaret`.
  """

  alias LeniesWeb.{EditorCaret, GenomeBuffer}

  @type address :: {GenomeBuffer.section(), non_neg_integer()}
  @type t :: {address(), address()}

  @spec place(GenomeBuffer.section(), non_neg_integer()) :: t()
  def place(section, gap), do: {{section, gap}, {section, gap}}

  @spec select_block(GenomeBuffer.section(), non_neg_integer()) :: t()
  def select_block(section, idx), do: {{section, idx + 1}, {section, idx}}

  @doc "Selected `{section, {lo, hi}}`, or nil when collapsed."
  @spec derive_range(t()) ::
          {GenomeBuffer.section(), {non_neg_integer(), non_neg_integer()}} | nil
  def derive_range({{s, c}, {s, a}}) do
    case EditorCaret.derive_range({c, a}) do
      nil -> nil
      range -> {s, range}
    end
  end

  def derive_range(_pair), do: nil

  @doc "Collapsed move; crosses section boundaries at the edges."
  @spec move(t(), :up | :down, GenomeBuffer.t()) :: t()
  def move({{s, c}, _anchor}, dir, %GenomeBuffer{} = g) do
    len = length(GenomeBuffer.get_section(g, s) || [])

    case {dir, c} do
      {:up, 0} ->
        case neighbor(g, s, -1) do
          nil -> place(s, 0)
          prev -> place(prev, length(GenomeBuffer.get_section(g, prev)))
        end

      {:down, ^len} ->
        case neighbor(g, s, +1) do
          nil -> place(s, len)
          next -> place(next, 0)
        end

      {:up, _} ->
        place(s, c - 1)

      {:down, _} ->
        place(s, min(c + 1, len))
    end
  end

  @doc "Extend the selection one gap, clamped inside the anchor's section."
  @spec extend(t(), :up | :down, GenomeBuffer.t()) :: t()
  def extend({{s, c}, {s, a}}, dir, %GenomeBuffer{} = g) do
    len = length(GenomeBuffer.get_section(g, s) || [])
    {nc, na} = EditorCaret.extend({c, a}, dir, len)
    {{s, nc}, {s, na}}
  end

  def extend(pair, _dir, _g), do: pair

  @doc "Extend to `gap` keeping the anchor when in the same section; else collapse there."
  @spec extend_to_gap(t(), GenomeBuffer.section(), non_neg_integer()) :: t()
  def extend_to_gap({{s, _c}, {s, a}}, s, gap), do: {{s, gap}, {s, a}}
  def extend_to_gap(_pair, section, gap), do: place(section, gap)

  @doc "Extend through block `idx` keeping the anchor when same-section; else select it."
  @spec extend_to_block(t(), GenomeBuffer.section(), non_neg_integer()) :: t()
  def extend_to_block({{s, c}, {s, a}}, s, idx) do
    {nc, na} = EditorCaret.extend_to_block({c, a}, idx)
    {{s, nc}, {s, na}}
  end

  def extend_to_block(_pair, section, idx), do: select_block(section, idx)

  @spec after_insert(GenomeBuffer.section(), non_neg_integer(), non_neg_integer()) :: t()
  def after_insert(section, at, count), do: place(section, at + count)

  @spec after_delete_range(GenomeBuffer.section(), {non_neg_integer(), non_neg_integer()}) :: t()
  def after_delete_range(section, {lo, _hi}), do: place(section, lo)

  @spec select_inserted(GenomeBuffer.section(), non_neg_integer(), non_neg_integer()) :: t()
  def select_inserted(section, at, count), do: {{section, at + count}, {section, at}}

  @doc """
  Repair the pair after a genome mutation: clamp gaps into the section's
  new bounds; if the section vanished, collapse at the genome end.
  """
  @spec clamp(t(), GenomeBuffer.t()) :: t()
  def clamp({{s, c}, {s, a}} = _pair, %GenomeBuffer{} = g) do
    case GenomeBuffer.get_section(g, s) do
      nil ->
        end_of(g)

      buf ->
        {nc, na} = EditorCaret.clamp({c, a}, length(buf))
        {{s, nc}, {s, na}}
    end
  end

  def clamp(_pair, %GenomeBuffer{} = g), do: end_of(g)

  @doc "Collapsed caret at the last gap of the last section."
  @spec end_of(GenomeBuffer.t()) :: t()
  def end_of(%GenomeBuffer{} = g) do
    {section, buf} = g |> GenomeBuffer.sections() |> List.last()
    place(section, length(buf))
  end

  # Section `offset` steps away in the genome's section order, or nil.
  defp neighbor(%GenomeBuffer{} = g, section, offset) do
    order = g |> GenomeBuffer.sections() |> Enum.map(&elem(&1, 0))

    case Enum.find_index(order, &(&1 == section)) do
      nil -> nil
      i when i + offset < 0 -> nil
      i -> Enum.at(order, i + offset)
    end
  end
end
