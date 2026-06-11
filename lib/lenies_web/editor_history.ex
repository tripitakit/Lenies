defmodule LeniesWeb.EditorHistory do
  @moduledoc """
  Undo/redo stacks for the codeome editor. `past` and `future` hold
  whole-genome snapshots (`%LeniesWeb.GenomeBuffer{}` in the unified
  editor, `[atom()]` in the legacy single-buffer editor). Snapshots are
  small (bounded by the codeome length cap) so full snapshots are simpler
  than diffs. `past` is most-recent-first. Bounded by `max`: recording
  beyond `max` discards the oldest snapshot.
  """

  @type snapshot :: term()
  @type t :: %__MODULE__{past: [snapshot()], future: [snapshot()], max: pos_integer()}

  defstruct past: [], future: [], max: 100

  @spec new(pos_integer()) :: t()
  def new(max \\ 100) when is_integer(max) and max > 0 do
    %__MODULE__{past: [], future: [], max: max}
  end

  @doc "Record `prev_snapshot` (the snapshot before a change) and clear redo."
  @spec record(t(), snapshot()) :: t()
  def record(%__MODULE__{} = h, prev_buffer) do
    %{h | past: Enum.take([prev_buffer | h.past], h.max), future: []}
  end

  @doc "Undo: returns `{restored_snapshot, history}` or `:none` if nothing to undo."
  @spec undo(t(), snapshot()) :: {snapshot(), t()} | :none
  def undo(%__MODULE__{past: []}, _current), do: :none

  def undo(%__MODULE__{past: [prev | rest]} = h, current) do
    {prev, %{h | past: rest, future: [current | h.future]}}
  end

  @doc "Redo: returns `{restored_snapshot, history}` or `:none` if nothing to redo."
  @spec redo(t(), snapshot()) :: {snapshot(), t()} | :none
  def redo(%__MODULE__{future: []}, _current), do: :none

  def redo(%__MODULE__{future: [next | rest]} = h, current) do
    {next, %{h | past: Enum.take([current | h.past], h.max), future: rest}}
  end

  @doc "True when there is at least one buffer to undo to."
  @spec can_undo?(t()) :: boolean()
  def can_undo?(%__MODULE__{past: []}), do: false
  def can_undo?(%__MODULE__{}), do: true

  @doc "True when there is at least one buffer to redo to."
  @spec can_redo?(t()) :: boolean()
  def can_redo?(%__MODULE__{future: []}), do: false
  def can_redo?(%__MODULE__{}), do: true
end
