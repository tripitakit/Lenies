defmodule LeniesWeb.EditorHistoryTest do
  use ExUnit.Case, async: true

  alias LeniesWeb.EditorHistory

  test "new/1 starts empty with the given max" do
    h = EditorHistory.new(50)
    assert h.past == []
    assert h.future == []
    assert h.max == 50
  end

  test "record pushes prev buffer and clears future" do
    h = EditorHistory.new(50) |> Map.put(:future, [[:x]])
    h = EditorHistory.record(h, [:a])
    assert h.past == [[:a]]
    assert h.future == []
  end

  test "undo moves current onto future and returns the last past buffer" do
    h = EditorHistory.new(50) |> EditorHistory.record([:a])
    assert {[:a], h2} = EditorHistory.undo(h, [:b])
    assert h2.past == []
    assert h2.future == [[:b]]
  end

  test "undo on empty past returns :none" do
    assert EditorHistory.undo(EditorHistory.new(50), [:b]) == :none
  end

  test "redo moves current onto past and returns the last future buffer" do
    h = EditorHistory.new(50) |> EditorHistory.record([:a])
    {[:a], h2} = EditorHistory.undo(h, [:b])
    assert {[:b], h3} = EditorHistory.redo(h2, [:a])
    assert h3.past == [[:a]]
    assert h3.future == []
  end

  test "redo on empty future returns :none" do
    assert EditorHistory.redo(EditorHistory.new(50), [:a]) == :none
  end

  test "record stacks onto a non-empty past (most-recent-first)" do
    h =
      EditorHistory.new(50)
      |> EditorHistory.record([:a])
      |> EditorHistory.record([:b])

    assert h.past == [[:b], [:a]]
  end

  test "record drops oldest past beyond max depth" do
    h =
      Enum.reduce(1..5, EditorHistory.new(3), fn n, acc ->
        EditorHistory.record(acc, [n])
      end)

    # max 3: keeps the 3 most-recent pushes (5, 4, 3), drops 2 and 1
    assert h.past == [[5], [4], [3]]
  end
end
