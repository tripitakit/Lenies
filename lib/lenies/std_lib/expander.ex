defmodule Lenies.StdLib.Expander do
  @moduledoc """
  Concretises a Snippet's body template into an `%InsertPlan{}` against the
  current genome + caret. Pure — no UI.
  """
  alias Lenies.StdLib.{Snippet, InsertPlan}

  @spec expand(Snippet.t(), map(), LeniesWeb.GenomeBuffer.t(), {atom(), non_neg_integer()}) ::
          {:ok, InsertPlan.t()} | {:error, atom()}
  def expand(%Snippet{kind: :inline, body: body}, _params, _genome, _caret) do
    {:ok, %InsertPlan{caret_ops: body}}
  end
end
