defmodule LeniesWeb.GenomeBuffer do
  @moduledoc """
  Pure multi-section buffer for the unified codeome editor: one chromosome
  plus N plasmid buffers, addressed by `{section, index}` where `section`
  is `:chromosome | {:plasmid, i}`.

  Wraps `LeniesWeb.CodeomeBuffer` for per-section list operations; this
  module owns section addressing, the flat exec-codeome index space (the
  geography the stepper executes), genome-wide validation/economics, and
  breakpoint remapping across edits.
  """

  alias LeniesWeb.CodeomeBuffer

  defstruct chromosome: [], plasmids: []

  @type section :: :chromosome | {:plasmid, non_neg_integer()}
  @type t :: %__MODULE__{chromosome: [atom()], plasmids: [[atom()]]}

  @spec new([atom()], [[atom()]]) :: t()
  def new(chromosome \\ [], plasmids \\ []),
    do: %__MODULE__{chromosome: chromosome, plasmids: plasmids}

  @doc "Ordered `{section, buffer}` pairs: chromosome first, then plasmids."
  @spec sections(t()) :: [{section(), [atom()]}]
  def sections(%__MODULE__{} = g) do
    plasmid_sections =
      g.plasmids |> Enum.with_index() |> Enum.map(fn {buf, i} -> {{:plasmid, i}, buf} end)

    [{:chromosome, g.chromosome} | plasmid_sections]
  end

  @spec get_section(t(), section()) :: [atom()] | nil
  def get_section(%__MODULE__{} = g, :chromosome), do: g.chromosome
  def get_section(%__MODULE__{} = g, {:plasmid, i}) when i >= 0, do: Enum.at(g.plasmids, i)
  def get_section(_g, _section), do: nil

  @spec put_section(t(), section(), [atom()]) :: t()
  def put_section(%__MODULE__{} = g, :chromosome, buf) when is_list(buf),
    do: %{g | chromosome: buf}

  def put_section(%__MODULE__{} = g, {:plasmid, i}, buf) when is_list(buf) and i >= 0 do
    if i < length(g.plasmids),
      do: %{g | plasmids: List.replace_at(g.plasmids, i, buf)},
      else: g
  end

  @doc "Apply `fun` to one section's buffer; no-op when the section is missing."
  @spec update_section(t(), section(), ([atom()] -> [atom()])) :: t()
  def update_section(%__MODULE__{} = g, section, fun) when is_function(fun, 1) do
    case get_section(g, section) do
      nil -> g
      buf -> put_section(g, section, fun.(buf))
    end
  end

  @spec add_plasmid(t()) :: t()
  def add_plasmid(%__MODULE__{} = g), do: %{g | plasmids: g.plasmids ++ [[]]}

  @spec remove_plasmid(t(), non_neg_integer()) :: t()
  def remove_plasmid(%__MODULE__{} = g, i) when i >= 0 do
    if i < length(g.plasmids), do: %{g | plasmids: List.delete_at(g.plasmids, i)}, else: g
  end

  @spec plasmid_count(t()) :: non_neg_integer()
  def plasmid_count(%__MODULE__{} = g), do: length(g.plasmids)

  @doc """
  Flat exec-codeome list: chromosome ++ plasmids in order. Empty plasmid
  sections contribute zero rows, so flat indices line up 1:1 with the
  runtime exec codeome (which is built from non-empty plasmids only).
  """
  @spec to_exec_list(t()) :: [atom()]
  def to_exec_list(%__MODULE__{} = g), do: g.chromosome ++ Enum.concat(g.plasmids)

  @doc "Flat exec index of `{section, idx}`; nil for an unknown section."
  @spec flat_index(t(), section(), non_neg_integer()) :: non_neg_integer() | nil
  def flat_index(%__MODULE__{} = g, section, idx) when idx >= 0 do
    case section_offset(g, section) do
      nil -> nil
      offset -> offset + idx
    end
  end

  defp section_offset(_g, :chromosome), do: 0

  defp section_offset(%__MODULE__{} = g, {:plasmid, i}) when i >= 0 do
    if i < length(g.plasmids) do
      length(g.chromosome) +
        (g.plasmids |> Enum.take(i) |> Enum.map(&length/1) |> Enum.sum())
    end
  end

  defp section_offset(_g, _), do: nil

  @doc "Inverse of `flat_index/3` for op rows: `{section, idx}` or nil past the end."
  @spec section_at(t(), non_neg_integer()) :: {section(), non_neg_integer()} | nil
  def section_at(%__MODULE__{} = g, flat) when is_integer(flat) and flat >= 0 do
    g
    |> sections()
    |> Enum.reduce_while(flat, fn {section, buf}, rest ->
      if rest < length(buf), do: {:halt, {section, rest}}, else: {:cont, rest - length(buf)}
    end)
    |> case do
      {section, idx} -> {section, idx}
      _past_end -> nil
    end
  end

  @doc """
  Genome-wide validation: the chromosome rules from
  `CodeomeBuffer.validate/1` plus a per-plasmid length cap
  (`Lenies.Plasmid.max_length/0`). The `{:ok, info}` payload covers the
  chromosome only (replication is chromosome-bound).
  """
  @spec validate(t()) ::
          {:ok, %{len: non_neg_integer(), non_nops: non_neg_integer()}}
          | {:error, [term()]}
  def validate(%__MODULE__{} = g) do
    cap = Lenies.Plasmid.max_length()

    plasmid_errs =
      g.plasmids
      |> Enum.with_index()
      |> Enum.filter(fn {buf, _i} -> length(buf) > cap end)
      |> Enum.map(fn {buf, i} ->
        {:plasmid_too_long, [plasmid: i, max: cap, got: length(buf)]}
      end)

    case {CodeomeBuffer.validate(g.chromosome), plasmid_errs} do
      {{:ok, info}, []} -> {:ok, info}
      {{:ok, _info}, errs} -> {:error, errs}
      {{:error, errs}, perrs} -> {:error, errs ++ perrs}
    end
  end

  @doc """
  Energy budget over one linear pass of the whole exec genome. `:allocate`
  is priced with the CHROMOSOME length — self-replication copies the
  chromosome only; plasmids segregate and are never copied by :allocate.
  """
  @spec economics(t(), number(), number()) :: map()
  def economics(%__MODULE__{} = g, eat_amount, attack_damage) do
    CodeomeBuffer.economics(to_exec_list(g), eat_amount, attack_damage,
      alloc_size: length(g.chromosome)
    )
  end

  @doc """
  Remap flat-exec breakpoints across a genome change: a breakpoint keeps
  its `{section, in-section index}` address when that address still exists
  in `new`; breakpoints whose section vanished or whose index fell off the
  end are dropped.
  """
  @spec remap_breakpoints(t(), t(), MapSet.t()) :: MapSet.t()
  def remap_breakpoints(%__MODULE__{} = old, %__MODULE__{} = new, %MapSet{} = bps) do
    bps
    |> Enum.flat_map(fn flat ->
      with {section, idx} <- section_at(old, flat),
           new_buf when is_list(new_buf) <- get_section(new, section),
           true <- idx < length(new_buf),
           new_flat when is_integer(new_flat) <- flat_index(new, section, idx) do
        [new_flat]
      else
        _ -> []
      end
    end)
    |> MapSet.new()
  end
end
