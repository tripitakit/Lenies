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

  # `comments` are free-text cell annotations kept OUTSIDE the executable
  # opcode stream (the VM never sees them). Keyed by `{section, in-section
  # index}` so an annotation rides with its opcode through edits; rendered in
  # the editor and disassembler/stepper, persisted with the seed, stripped at
  # `to_codeome`. Stored in the struct so undo/redo snapshots and the dirty
  # check include them for free.
  defstruct chromosome: [], plasmids: [], comments: %{}

  @comment_max_len 32

  @type section :: :chromosome | {:plasmid, non_neg_integer()}
  @type comment_key :: {section(), non_neg_integer()}
  @type t :: %__MODULE__{
          chromosome: [atom()],
          plasmids: [[atom()]],
          comments: %{optional(comment_key()) => String.t()}
        }

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
    if i < length(g.plasmids) do
      %{g | plasmids: List.delete_at(g.plasmids, i), comments: drop_plasmid_comments(g.comments, i)}
    else
      g
    end
  end

  # Plasmid `removed` is deleted: drop its comments and renumber the sections
  # of the plasmids that came after it (`{:plasmid, j}` → `{:plasmid, j-1}`).
  defp drop_plasmid_comments(comments, removed) do
    comments
    |> Enum.flat_map(fn
      {{{:plasmid, ^removed}, _idx}, _text} -> []
      {{{:plasmid, j}, idx}, text} when j > removed -> [{{{:plasmid, j - 1}, idx}, text}]
      kv -> [kv]
    end)
    |> Map.new()
  end

  # ----- comments -----

  @doc """
  Set (or, with blank text, clear) the comment on cell `{section, idx}`. Text
  is trimmed and truncated to #{@comment_max_len} characters.
  """
  @spec put_comment(t(), section(), non_neg_integer(), String.t()) :: t()
  def put_comment(%__MODULE__{} = g, section, idx, text) when idx >= 0 do
    trimmed = text |> to_string() |> String.trim() |> String.slice(0, @comment_max_len)

    comments =
      if trimmed == "",
        do: Map.delete(g.comments, {section, idx}),
        else: Map.put(g.comments, {section, idx}, trimmed)

    %{g | comments: comments}
  end

  @spec get_comment(t(), section(), non_neg_integer()) :: String.t() | nil
  def get_comment(%__MODULE__{} = g, section, idx), do: Map.get(g.comments, {section, idx})

  @doc "Comments re-keyed by flat exec index, for the disassembler/stepper view and persistence."
  @spec comments_by_flat(t()) :: %{optional(non_neg_integer()) => String.t()}
  def comments_by_flat(%__MODULE__{} = g) do
    for {{section, idx}, text} <- g.comments,
        flat = flat_index(g, section, idx),
        is_integer(flat),
        into: %{},
        do: {flat, text}
  end

  @doc """
  Attach comments given by flat exec index (the persisted shape) onto the
  matching `{section, idx}` cells. Flat indices past the end of the genome are
  ignored. Inverse of `comments_by_flat/1`.
  """
  @spec put_comments_by_flat(t(), %{optional(non_neg_integer()) => String.t()}) :: t()
  def put_comments_by_flat(%__MODULE__{} = g, flat_map) when is_map(flat_map) do
    Enum.reduce(flat_map, g, fn {flat, text}, acc ->
      case section_at(acc, flat) do
        {section, idx} -> put_comment(acc, section, idx, text)
        nil -> acc
      end
    end)
  end

  @doc "Maximum comment length in characters."
  @spec comment_max_len() :: pos_integer()
  def comment_max_len, do: @comment_max_len

  # ----- comment-aware section edits -----
  #
  # Each wraps the matching `CodeomeBuffer` op AND remaps this section's
  # comments so every surviving cell keeps its annotation. Correctness is
  # guaranteed by applying the *same* list op to a list of index tokens
  # (`remap_section/3`): wherever an old index lands in the token result is
  # where its comment goes; indices absent from the result were deleted.

  @spec insert(t(), section(), non_neg_integer(), atom()) :: t()
  def insert(%__MODULE__{} = g, section, idx, opcode) when is_atom(opcode),
    do: edit_section(g, section, &CodeomeBuffer.insert(&1, idx, opcode))

  @spec insert_many(t(), section(), non_neg_integer(), [atom()]) :: t()
  def insert_many(%__MODULE__{} = g, section, idx, opcodes) when is_list(opcodes),
    do: edit_section(g, section, &CodeomeBuffer.insert_many(&1, idx, opcodes))

  @spec delete(t(), section(), non_neg_integer()) :: t()
  def delete(%__MODULE__{} = g, section, idx),
    do: edit_section(g, section, &CodeomeBuffer.delete(&1, idx))

  @spec delete_range(t(), section(), {non_neg_integer(), non_neg_integer()}) :: t()
  def delete_range(%__MODULE__{} = g, section, range),
    do: edit_section(g, section, &CodeomeBuffer.delete_range(&1, range))

  @spec move(t(), section(), non_neg_integer(), non_neg_integer()) :: t()
  def move(%__MODULE__{} = g, section, from, to),
    do: edit_section(g, section, &CodeomeBuffer.move(&1, from, to))

  @spec move_range(t(), section(), {non_neg_integer(), non_neg_integer()}, non_neg_integer()) :: t()
  def move_range(%__MODULE__{} = g, section, range, to_gap),
    do: edit_section(g, section, &CodeomeBuffer.move_range(&1, range, to_gap))

  # Apply `list_op` to a section's opcode buffer and remap its comments by the
  # identical transformation on an index-token list.
  defp edit_section(%__MODULE__{} = g, section, list_op) do
    case get_section(g, section) do
      nil ->
        g

      buf ->
        new_buf = list_op.(buf)
        tokens = list_op.(Enum.to_list(0..(length(buf) - 1)//1))

        # new position of each surviving old index (token integers only;
        # inserted opcodes are atoms and have no prior index).
        new_pos =
          tokens
          |> Enum.with_index()
          |> Enum.flat_map(fn
            {old_idx, new_idx} when is_integer(old_idx) -> [{old_idx, new_idx}]
            _inserted -> []
          end)
          |> Map.new()

        comments =
          g.comments
          |> Enum.flat_map(fn
            {{^section, old_idx}, text} ->
              case Map.fetch(new_pos, old_idx) do
                {:ok, new_idx} -> [{{section, new_idx}, text}]
                :error -> []
              end

            other ->
              [other]
          end)
          |> Map.new()

        %{g | comments: comments} |> put_section(section, new_buf)
    end
  end

  @spec plasmid_count(t()) :: non_neg_integer()
  def plasmid_count(%__MODULE__{} = g), do: length(g.plasmids)

  @doc """
  Flat exec-codeome list: chromosome ++ plasmids in order. Empty plasmid
  sections contribute zero rows, so flat indices line up 1:1 with the
  runtime exec codeome.
  """
  @spec to_exec_list(t()) :: [atom()]
  def to_exec_list(%__MODULE__{} = g), do: g.chromosome ++ Enum.concat(g.plasmids)

  @doc "Flat exec index of `{section, idx}`; nil for an unknown section or an out-of-range `idx`."
  @spec flat_index(t(), section(), non_neg_integer()) :: non_neg_integer() | nil
  def flat_index(%__MODULE__{} = g, section, idx) when idx >= 0 do
    case {section_offset(g, section), get_section(g, section)} do
      {nil, _} -> nil
      {_, nil} -> nil
      {offset, buf} when idx < length(buf) -> offset + idx
      _ -> nil
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
  @spec remap_breakpoints(t(), t(), MapSet.t(non_neg_integer())) :: MapSet.t(non_neg_integer())
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
