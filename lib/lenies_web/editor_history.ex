defmodule LeniesWeb.EditorHistory do
  @moduledoc """
  Undo/redo stacks for the codeome editor buffer.

  `past` and `future` hold whole-buffer snapshots (buffers are small —
  bounded by the codeome length cap — so full snapshots are simpler than
  diffs). `past` is most-recent-first. Bounded by `max`: recording beyond
  `max` discards the oldest snapshot.
  """

  @type buffer :: [atom()]
  @type t :: %__MODULE__{past: [buffer()], future: [buffer()], max: pos_integer()}

  defstruct past: [], future: [], max: 100

  @spec new(pos_integer()) :: t()
  def new(max \\ 100) when is_integer(max) and max > 0 do
    %__MODULE__{past: [], future: [], max: max}
  end

  @doc "Record `prev_buffer` (the buffer before a change) and clear redo."
  @spec record(t(), buffer()) :: t()
  def record(%__MODULE__{} = h, prev_buffer) do
    %{h | past: Enum.take([prev_buffer | h.past], h.max), future: []}
  end

  @doc "Undo: returns `{restored_buffer, history}` or `:none` if nothing to undo."
  @spec undo(t(), buffer()) :: {buffer(), t()} | :none
  def undo(%__MODULE__{past: []}, _current), do: :none

  def undo(%__MODULE__{past: [prev | rest]} = h, current) do
    {prev, %{h | past: rest, future: [current | h.future]}}
  end

  @doc "Redo: returns `{restored_buffer, history}` or `:none` if nothing to redo."
  @spec redo(t(), buffer()) :: {buffer(), t()} | :none
  def redo(%__MODULE__{future: []}, _current), do: :none

  def redo(%__MODULE__{future: [next | rest]} = h, current) do
    {next, %{h | past: [current | h.past], future: rest}}
  end
end
