defmodule Lenies.StdLib.Snippet do
  @moduledoc "A built-in std-lib snippet: metadata + a body template the Expander concretises."
  @enforce_keys [:id, :name, :category, :kind, :signature, :body]
  defstruct [:id, :name, :category, :kind, :signature, :doc, :body, params: [], cost: nil]

  @type kind :: :inline | :param | :function
  @type branch_cond :: :jz | :jnz | :jlt | :jgt | :jmp
  @type placeholder ::
          {:const, atom() | integer()}
          | {:label, atom()}
          | {:branch, branch_cond(), atom()}
          | {:repeat, atom(), [body_item()]}
          | {:anchor, :self}
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
