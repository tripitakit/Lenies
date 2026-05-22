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

  describe "move/3 and extend/3" do
    test "move :up decrements caret, collapsing the selection" do
      assert C.move({3, 1}, :up, 5) == {2, 2}
    end

    test "move :down increments caret, clamped to len" do
      assert C.move({5, 5}, :down, 5) == {5, 5}
      assert C.move({2, 2}, :down, 5) == {3, 3}
    end

    test "move :up clamps at 0" do
      assert C.move({0, 0}, :up, 5) == {0, 0}
    end

    test "extend keeps the anchor and moves only the caret" do
      assert C.extend({2, 2}, :down, 5) == {3, 2}
      assert C.extend({2, 2}, :up, 5) == {1, 2}
    end
  end

  describe "extend_to_gap/2 and extend_to_block/2" do
    test "extend_to_gap moves caret to the gap, keeps anchor" do
      assert C.extend_to_gap({2, 2}, 4) == {4, 2}
    end

    test "extend_to_block selects through that block forward" do
      assert C.extend_to_block({2, 1}, 3) == {4, 1}
    end

    test "extend_to_block selects through that block backward" do
      assert C.extend_to_block({4, 4}, 1) == {1, 4}
    end
  end

  describe "clamp/2 and post-edit helpers" do
    test "clamp pulls both ends into 0..len" do
      assert C.clamp({9, -3}, 5) == {5, 0}
    end

    test "after_insert leaves a collapsed caret past the inserted run" do
      assert C.after_insert(2, 3) == {5, 5}
    end

    test "after_delete_range collapses to the range start" do
      assert C.after_delete_range({1, 2}) == {1, 1}
    end

    test "select_inserted selects the freshly inserted run" do
      assert C.select_inserted(2, 3) == {5, 2}
      assert C.derive_range(C.select_inserted(2, 3)) == {2, 4}
    end
  end
end
