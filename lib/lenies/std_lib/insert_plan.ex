defmodule Lenies.StdLib.InsertPlan do
  @moduledoc """
  What an insert does, separate from doing it. `caret_ops` go at the caret;
  `appended_ops` go to the chromosome tail (function bodies); `comments` are
  `{offset_into_appended, text}` annotations the editor sets after appending.
  """
  defstruct caret_ops: [], appended_ops: [], anchor: nil, comments: []

  @type t :: %__MODULE__{
          caret_ops: [atom()],
          appended_ops: [atom()],
          anchor: [atom()] | nil,
          comments: [{non_neg_integer(), String.t()}]
        }
end
