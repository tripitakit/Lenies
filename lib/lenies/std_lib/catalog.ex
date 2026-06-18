defmodule Lenies.StdLib.Catalog do
  @moduledoc "The built-in, read-only std-lib of functional snippets."
  alias Lenies.StdLib.Snippet

  @snippets [
    # Logic (0/1)
    %Snippet{id: "not", name: "not", category: "Logic", kind: :inline, signature: "( a -- !a )", doc: "Boolean NOT of a 0/1 value.", body: [:push1, :swap, :sub]},
    %Snippet{id: "and", name: "and", category: "Logic", kind: :inline, signature: "( a b -- a∧b )", doc: "Boolean AND of two 0/1 values (a*b).", body: [:mul]},
    %Snippet{id: "or", name: "or", category: "Logic", kind: :inline, signature: "( a b -- a∨b )", doc: "Boolean OR of two 0/1 values (De Morgan).", body: [:push1, :swap, :sub, :swap, :push1, :swap, :sub, :mul, :push1, :swap, :sub]},
    %Snippet{id: "xor", name: "xor", category: "Logic", kind: :inline, signature: "( a b -- a⊕b )", doc: "Boolean XOR of two 0/1 values ((a+b) mod 2).", body: [:add, :push1, :push1, :add, :mod]},
    %Snippet{id: "bool", name: "bool (normalize)", category: "Logic", kind: :inline, signature: "( a -- 0|1 )", doc: "Normalize any integer to 0/1 (nonzero -> 1).", body: [{:branch, :jnz, :t}, :push0, {:branch, :jmp, :e}, {:label, :t}, :push1, {:label, :e}]},

    # Compare (-> 0/1)
    %Snippet{id: "eq", name: "eq", category: "Compare", kind: :inline, signature: "( a b -- a=b )", doc: "1 if a equals b, else 0.", body: [:sub, {:branch, :jz, :t}, :push0, {:branch, :jmp, :e}, {:label, :t}, :push1, {:label, :e}]},
    %Snippet{id: "neq", name: "neq", category: "Compare", kind: :inline, signature: "( a b -- a≠b )", doc: "1 if a differs from b, else 0.", body: [:sub, {:branch, :jnz, :t}, :push0, {:branch, :jmp, :e}, {:label, :t}, :push1, {:label, :e}]},
    %Snippet{id: "lt", name: "lt", category: "Compare", kind: :inline, signature: "( a b -- a<b )", doc: "1 if a < b, else 0.", body: [:sub, {:branch, :jlt, :t}, :push0, {:branch, :jmp, :e}, {:label, :t}, :push1, {:label, :e}]},
    %Snippet{id: "gt", name: "gt", category: "Compare", kind: :inline, signature: "( a b -- a>b )", doc: "1 if a > b, else 0.", body: [:sub, {:branch, :jgt, :t}, :push0, {:branch, :jmp, :e}, {:label, :t}, :push1, {:label, :e}]},
    %Snippet{id: "lte", name: "lte", category: "Compare", kind: :inline, signature: "( a b -- a≤b )", doc: "1 if a ≤ b, else 0.", body: [:sub, {:branch, :jgt, :f}, :push1, {:branch, :jmp, :e}, {:label, :f}, :push0, {:label, :e}]},
    %Snippet{id: "gte", name: "gte", category: "Compare", kind: :inline, signature: "( a b -- a≥b )", doc: "1 if a ≥ b, else 0.", body: [:sub, {:branch, :jlt, :f}, :push1, {:branch, :jmp, :e}, {:label, :f}, :push0, {:label, :e}]},
    %Snippet{id: "sign", name: "sign", category: "Compare", kind: :inline, signature: "( a -- -1|0|1 )", doc: "Sign of a: -1, 0, or 1.", body: [:dup, {:branch, :jgt, :pos}, {:branch, :jz, :zero}, :push0, :push1, :sub, {:branch, :jmp, :e}, {:label, :zero}, :push0, {:branch, :jmp, :e}, {:label, :pos}, :drop, :push1, {:label, :e}]},

    # Numeric
    %Snippet{id: "negate", name: "negate", category: "Numeric", kind: :inline, signature: "( a -- -a )", doc: "Arithmetic negation (0 - a).", body: [:push0, :swap, :sub]},
    %Snippet{id: "double", name: "double", category: "Numeric", kind: :inline, signature: "( a -- 2a )", doc: "Double a value.", body: [:dup, :add]},
    %Snippet{id: "abs", name: "abs", category: "Numeric", kind: :inline, signature: "( a -- |a| )", doc: "Absolute value.", body: [:dup, {:branch, :jlt, :neg}, {:branch, :jmp, :e}, {:label, :neg}, :push0, :swap, :sub, {:label, :e}]},
    %Snippet{id: "min", name: "min", category: "Numeric", kind: :inline, signature: "( a b -- min )", doc: "Smaller of a and b. Uses memory slot 3 as scratch.", body: [{:const, 3}, :store, :dup, {:const, 3}, :load, :sub, {:branch, :jlt, :am}, :drop, {:const, 3}, :load, {:branch, :jmp, :e}, {:label, :am}, {:label, :e}]},
    %Snippet{id: "max", name: "max", category: "Numeric", kind: :inline, signature: "( a b -- max )", doc: "Larger of a and b. Uses memory slot 3 as scratch.", body: [{:const, 3}, :store, :dup, {:const, 3}, :load, :sub, {:branch, :jgt, :am}, :drop, {:const, 3}, :load, {:branch, :jmp, :e}, {:label, :am}, {:label, :e}]},
    %Snippet{id: "clamp", name: "clamp [lo,hi]", category: "Numeric", kind: :param, signature: "( v -- v' )", params: [:lo, :hi], doc: "Clamp v into [lo,hi]. Uses memory slot 3 as scratch.", body: [
      {:const, :lo}, {:const, 3}, :store, :dup, {:const, 3}, :load, :sub, {:branch, :jgt, :a1}, :drop, {:const, 3}, :load, {:branch, :jmp, :e1}, {:label, :a1}, {:label, :e1},
      {:const, :hi}, {:const, 3}, :store, :dup, {:const, 3}, :load, :sub, {:branch, :jlt, :a2}, :drop, {:const, 3}, :load, {:branch, :jmp, :e2}, {:label, :a2}, {:label, :e2}
    ]},
    %Snippet{id: "mod-k", name: "mod K", category: "Numeric", kind: :param, signature: "( a -- a mod K )", params: [:K], doc: "Remainder of a divided by K.", body: [{:const, :K}, :mod]},
    %Snippet{id: "const-k", name: "const K", category: "Numeric", kind: :param, signature: "( -- K )", params: [:K], doc: "Build the constant K with a doubling chain.", body: [{:require_pos, :K}, {:const, :K}]}
  ]

  @spec all() :: [Snippet.t()]
  def all, do: @snippets

  @spec get(String.t()) :: Snippet.t() | nil
  def get(id), do: Enum.find(@snippets, &(&1.id == id))

  @spec by_category() :: [{String.t(), [Snippet.t()]}]
  def by_category do
    @snippets |> Enum.group_by(& &1.category) |> Enum.sort_by(fn {cat, _} -> cat end)
  end
end
