defmodule LeniesWeb.EditorCaretTest do
  use ExUnit.Case, async: true

  alias LeniesWeb.EditorCaret, as: C

  describe "derive_range/1 and collapsed?/1" do
    test "collapsed caret has no range" do
      assert C.collapsed?({2, 2})
      assert C.derive_range({2, 2}) == nil
    end

    test "caret after anchor selects blocks [anchor, caret-1]" do
      refute C.collapsed?({3, 1})
      assert C.derive_range({3, 1}) == {1, 2}
    end

    test "anchor after caret derives the same inclusive block range" do
      assert C.derive_range({1, 3}) == {1, 2}
    end
  end

  describe "place/1 and select_block/1" do
    test "place collapses both ends to the gap" do
      assert C.place(4) == {4, 4}
    end

    test "select_block selects exactly that one block" do
      sel = C.select_block(2)
      assert sel == {3, 2}
      assert C.derive_range(sel) == {2, 2}
    end
  end
end
