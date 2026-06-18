defmodule Lenies.StdLib.Catalog do
  @moduledoc "The built-in, read-only std-lib of functional snippets."
  alias Lenies.StdLib.Snippet

  @snippets [
    %Snippet{id: "random-bit", name: "random bit", category: "Branching",
      kind: :inline, signature: "( -- 0|1 )", doc: "A 50/50 random bit on the stack.",
      body: [:pushN, :push1, :add, :mod]},
    %Snippet{id: "if-food", name: "if food ahead", category: "Branching",
      kind: :inline, signature: "( -- )", doc: "Senses the front cell; leaves its reading for a following jz_t.",
      body: [:sense_front, :dup]},
    %Snippet{id: "graze-step", name: "graze step", category: "Foraging",
      kind: :inline, signature: "( -- )", doc: "Eat the current cell, then step forward.",
      body: [:eat, :move]},
    %Snippet{id: "slot-save", name: "save to slot 1", category: "Memory",
      kind: :inline, signature: "( v -- )", doc: "Store the top value into memory slot 1.",
      body: [:push1, :store]},
    %Snippet{id: "slot-load", name: "load slot 1", category: "Memory",
      kind: :inline, signature: "( -- v )", doc: "Push memory slot 1 onto the stack.",
      body: [:push1, :load]},
    %Snippet{id: "increment-slot1", name: "increment slot 1", category: "Memory",
      kind: :inline, signature: "( -- )", doc: "Add 1 to memory slot 1 in place.",
      body: [:push1, :load, :push1, :add, :push1, :store]}
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
