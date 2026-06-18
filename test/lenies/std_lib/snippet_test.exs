defmodule Lenies.StdLib.SnippetTest do
  use ExUnit.Case, async: true
  alias Lenies.StdLib.{Snippet, InsertPlan}

  test "snippet struct holds metadata + body" do
    s = %Snippet{id: "random-bit", name: "random bit", category: "Branching",
                 kind: :inline, signature: "( -- 0|1 )", doc: "50/50 bit",
                 body: [:pushN, :push1, :add, :mod]}
    assert s.kind == :inline
    assert s.body == [:pushN, :push1, :add, :mod]
    assert s.params == []
  end

  test "insert plan defaults to empty" do
    assert %InsertPlan{}.caret_ops == []
    assert %InsertPlan{}.appended_ops == []
    assert %InsertPlan{}.anchor == nil
    assert %InsertPlan{}.comments == []
  end
end
