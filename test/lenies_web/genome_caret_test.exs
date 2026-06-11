defmodule LeniesWeb.GenomeCaretTest do
  use ExUnit.Case, async: true

  alias LeniesWeb.{GenomeBuffer, GenomeCaret}

  # chromosome: 2 ops (gaps 0..2), plasmid 0: 1 op (gaps 0..1), plasmid 1: empty
  @genome GenomeBuffer.new([:push0, :add], [[:move], []])

  test "place/2 and select_block/2" do
    assert GenomeCaret.place(:chromosome, 1) == {{:chromosome, 1}, {:chromosome, 1}}

    assert GenomeCaret.select_block({:plasmid, 0}, 0) ==
             {{{:plasmid, 0}, 1}, {{:plasmid, 0}, 0}}
  end

  test "derive_range/1 returns {section, {lo, hi}} or nil" do
    assert GenomeCaret.derive_range(GenomeCaret.place(:chromosome, 1)) == nil

    assert GenomeCaret.derive_range({{:chromosome, 2}, {:chromosome, 0}}) ==
             {:chromosome, {0, 1}}
  end

  describe "move/3 crosses section boundaries, collapsing" do
    test "down past the last gap of a section lands on gap 0 of the next" do
      pair = GenomeCaret.place(:chromosome, 2)
      assert GenomeCaret.move(pair, :down, @genome) == GenomeCaret.place({:plasmid, 0}, 0)
    end

    test "up from gap 0 lands on the last gap of the previous section" do
      pair = GenomeCaret.place({:plasmid, 0}, 0)
      assert GenomeCaret.move(pair, :up, @genome) == GenomeCaret.place(:chromosome, 2)
    end

    test "clamped at the genome edges" do
      assert GenomeCaret.move(GenomeCaret.place(:chromosome, 0), :up, @genome) ==
               GenomeCaret.place(:chromosome, 0)

      # last section is the empty plasmid 1: its only gap is 0
      assert GenomeCaret.move(GenomeCaret.place({:plasmid, 1}, 0), :down, @genome) ==
               GenomeCaret.place({:plasmid, 1}, 0)
    end

    test "interior moves stay in section" do
      assert GenomeCaret.move(GenomeCaret.place(:chromosome, 1), :down, @genome) ==
               GenomeCaret.place(:chromosome, 2)
    end
  end

  describe "extend/3 clamps inside the anchor's section" do
    test "extending down at the section end does not cross the divider" do
      pair = {{:chromosome, 2}, {:chromosome, 1}}
      assert GenomeCaret.extend(pair, :down, @genome) == pair
    end

    test "extend grows the selection inside the section" do
      pair = GenomeCaret.place(:chromosome, 1)
      assert GenomeCaret.extend(pair, :down, @genome) == {{:chromosome, 2}, {:chromosome, 1}}
    end
  end

  test "extend_to_gap/3 same section keeps anchor; other section collapses there" do
    pair = {{:chromosome, 0}, {:chromosome, 0}}
    assert GenomeCaret.extend_to_gap(pair, :chromosome, 2) == {{:chromosome, 2}, {:chromosome, 0}}

    assert GenomeCaret.extend_to_gap(pair, {:plasmid, 0}, 1) ==
             GenomeCaret.place({:plasmid, 0}, 1)
  end

  test "extend_to_block/3 same section extends; other section selects that block" do
    pair = {{:chromosome, 0}, {:chromosome, 0}}

    assert GenomeCaret.extend_to_block(pair, :chromosome, 1) ==
             {{:chromosome, 2}, {:chromosome, 0}}

    assert GenomeCaret.extend_to_block(pair, {:plasmid, 0}, 0) ==
             GenomeCaret.select_block({:plasmid, 0}, 0)
  end

  test "after_insert/3, after_delete_range/2, select_inserted/3" do
    assert GenomeCaret.after_insert(:chromosome, 1, 2) == GenomeCaret.place(:chromosome, 3)

    assert GenomeCaret.after_delete_range({:plasmid, 0}, {0, 0}) ==
             GenomeCaret.place({:plasmid, 0}, 0)

    assert GenomeCaret.select_inserted(:chromosome, 1, 2) == {{:chromosome, 3}, {:chromosome, 1}}
  end

  describe "clamp/2 repairs the pair after genome mutations" do
    test "clamps gaps into the section's new bounds" do
      pair = {{:chromosome, 9}, {:chromosome, 9}}
      assert GenomeCaret.clamp(pair, @genome) == GenomeCaret.place(:chromosome, 2)
    end

    test "a vanished section falls back to the genome end" do
      pair = GenomeCaret.place({:plasmid, 5}, 0)
      assert GenomeCaret.clamp(pair, @genome) == GenomeCaret.end_of(@genome)
    end
  end

  test "end_of/1 is the last gap of the last section" do
    assert GenomeCaret.end_of(@genome) == GenomeCaret.place({:plasmid, 1}, 0)
    assert GenomeCaret.end_of(GenomeBuffer.new([:eat], [])) == GenomeCaret.place(:chromosome, 1)
  end
end
