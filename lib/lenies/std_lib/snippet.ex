defmodule Lenies.StdLib.Snippet do
  @moduledoc "A built-in std-lib snippet: metadata + a body template the Expander concretises."
  @enforce_keys [:id, :name, :category, :kind, :signature, :body]
  defstruct [:id, :name, :category, :kind, :signature, :doc, :body, params: [], cost: nil]

  @type kind :: :inline | :param | :function
  @type placeholder ::
          {:const, atom()}
          | {:counter, atom(), non_neg_integer()}
          | {:anchor, :self}
          | {:call, :self}
          | {:sep}
  @type body_item :: atom() | placeholder()
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          category: String.t(),
          kind: kind(),
          signature: String.t(),
          doc: String.t() | nil,
          body: [body_item()],
          params: [atom()],
          cost: number() | nil
        }
end
