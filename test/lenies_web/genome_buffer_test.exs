defmodule LeniesWeb.GenomeBufferTest do
  use ExUnit.Case, async: true

  alias LeniesWeb.GenomeBuffer

  @genome GenomeBuffer.new([:push0, :add], [[:move], [], [:eat, :sense_here]])

  describe "sections and access" do
    test "sections/1 returns chromosome first, then plasmids in order" do
      assert GenomeBuffer.sections(@genome) == [
               {:chromosome, [:push0, :add]},
               {{:plasmid, 0}, [:move]},
               {{:plasmid, 1}, []},
               {{:plasmid, 2}, [:eat, :sense_here]}
             ]
    end

    test "get_section/2" do
      assert GenomeBuffer.get_section(@genome, :chromosome) == [:push0, :add]
      assert GenomeBuffer.get_section(@genome, {:plasmid, 2}) == [:eat, :sense_here]
      assert GenomeBuffer.get_section(@genome, {:plasmid, 9}) == nil
    end

    test "put_section/3 replaces one section; unknown section is a no-op" do
      g = GenomeBuffer.put_section(@genome, {:plasmid, 0}, [:turn_left])
      assert GenomeBuffer.get_section(g, {:plasmid, 0}) == [:turn_left]
      assert GenomeBuffer.put_section(@genome, {:plasmid, 9}, [:eat]) == @genome
    end

    test "update_section/3 applies fun; missing section is a no-op" do
      g = GenomeBuffer.update_section(@genome, :chromosome, &(&1 ++ [:eat]))
      assert GenomeBuffer.get_section(g, :chromosome) == [:push0, :add, :eat]
      assert GenomeBuffer.update_section(@genome, {:plasmid, 9}, & &1) == @genome
    end

    test "add_plasmid/1 appends an empty section; remove_plasmid/2 deletes by index" do
      g = GenomeBuffer.add_plasmid(@genome)
      assert GenomeBuffer.plasmid_count(g) == 4
      assert GenomeBuffer.get_section(g, {:plasmid, 3}) == []

      g2 = GenomeBuffer.remove_plasmid(@genome, 1)
      assert GenomeBuffer.plasmid_count(g2) == 2
      assert GenomeBuffer.get_section(g2, {:plasmid, 1}) == [:eat, :sense_here]
    end
  end

  describe "flat exec index space" do
    test "to_exec_list/1 concatenates skipping nothing (empties add zero rows)" do
      assert GenomeBuffer.to_exec_list(@genome) ==
               [:push0, :add, :move, :eat, :sense_here]
    end

    test "flat_index/3 maps {section, idx} into exec space" do
      assert GenomeBuffer.flat_index(@genome, :chromosome, 0) == 0
      assert GenomeBuffer.flat_index(@genome, :chromosome, 1) == 1
      assert GenomeBuffer.flat_index(@genome, {:plasmid, 0}, 0) == 2
      assert GenomeBuffer.flat_index(@genome, {:plasmid, 2}, 1) == 4
      assert GenomeBuffer.flat_index(@genome, {:plasmid, 9}, 0) == nil
    end

    test "flat_index/3 returns nil for an out-of-range in-section index" do
      # chromosome has 2 ops; index 99 is out of bounds
      assert GenomeBuffer.flat_index(@genome, :chromosome, 99) == nil
      # plasmid 2 has 2 ops; index 5 is out of bounds
      assert GenomeBuffer.flat_index(@genome, {:plasmid, 2}, 5) == nil
    end

    test "section_at/2 inverts flat_index for op rows" do
      assert GenomeBuffer.section_at(@genome, 0) == {:chromosome, 0}
      assert GenomeBuffer.section_at(@genome, 1) == {:chromosome, 1}
      assert GenomeBuffer.section_at(@genome, 2) == {{:plasmid, 0}, 0}
      assert GenomeBuffer.section_at(@genome, 3) == {{:plasmid, 2}, 0}
      assert GenomeBuffer.section_at(@genome, 4) == {{:plasmid, 2}, 1}
      assert GenomeBuffer.section_at(@genome, 5) == nil
    end
  end

  describe "validate/1" do
    test "valid genome reports chromosome len/non_nops" do
      # test config: min_viable_codeome_opcodes=10, codeome_length_bounds={5,1024}
      g = GenomeBuffer.new(List.duplicate(:eat, 10), [[:move]])
      assert {:ok, %{len: 10, non_nops: 10}} = GenomeBuffer.validate(g)
    end

    test "chromosome errors pass through from CodeomeBuffer.validate/1" do
      g = GenomeBuffer.new([], [])
      assert {:error, errs} = GenomeBuffer.validate(g)
      assert Enum.any?(errs, &match?({:too_short, _}, &1))
    end

    test "over-cap plasmid yields :plasmid_too_long" do
      cap = Lenies.Plasmid.max_length()
      g = GenomeBuffer.new(List.duplicate(:eat, 10), [List.duplicate(:move, cap + 1)])
      assert {:error, errs} = GenomeBuffer.validate(g)
      assert {:plasmid_too_long, info} = Enum.find(errs, &match?({:plasmid_too_long, _}, &1))
      assert info[:plasmid] == 0
      assert info[:max] == cap
      assert info[:got] == cap + 1
    end
  end

  describe "economics/3" do
    test "iterates the whole exec genome but sizes :allocate by the chromosome" do
      g = GenomeBuffer.new([:allocate, :eat], [[:eat]])
      eco = GenomeBuffer.economics(g, 20, 10)
      # both eats counted (one lives in the plasmid)...
      assert eco.n_eat == 2
      # ...but allocate priced as if copying only the 2-op chromosome
      assert eco.alloc_size == 2
    end
  end

  describe "remap_breakpoints/3" do
    test "keeps {section, idx} addresses that still exist, in new flat space" do
      old = GenomeBuffer.new([:push0, :add], [[:move, :eat]])
      # bp on chromosome idx 1 (flat 1) and plasmid0 idx 1 (flat 3)
      bps = MapSet.new([1, 3])
      # insert one opcode at chromosome head -> plasmid region shifts right
      new = GenomeBuffer.new([:nop_0, :push0, :add], [[:move, :eat]])

      assert GenomeBuffer.remap_breakpoints(old, new, bps) == MapSet.new([1, 4])
    end

    test "drops breakpoints whose address fell off or whose section vanished" do
      old = GenomeBuffer.new([:push0, :add], [[:move, :eat]])
      bps = MapSet.new([1, 2, 3])
      new = GenomeBuffer.new([:push0], [])

      # chromosome idx 1 gone (len 1), plasmid section gone entirely
      assert GenomeBuffer.remap_breakpoints(old, new, bps) == MapSet.new([])
    end
  end

  describe "comments" do
    test "a new genome has no comments" do
      assert GenomeBuffer.new([:push0, :add]).comments == %{}
    end

    test "put_comment/get_comment store and read a cell comment" do
      g = GenomeBuffer.put_comment(GenomeBuffer.new([:push0, :add]), :chromosome, 1, "the add")
      assert GenomeBuffer.get_comment(g, :chromosome, 1) == "the add"
      assert GenomeBuffer.get_comment(g, :chromosome, 0) == nil
    end

    test "put_comment trims and truncates to 32 chars; blank clears" do
      long = String.duplicate("x", 50)
      g = GenomeBuffer.put_comment(GenomeBuffer.new([:push0, :add]), :chromosome, 0, long)
      assert String.length(GenomeBuffer.get_comment(g, :chromosome, 0)) == 32

      g2 = GenomeBuffer.put_comment(g, :chromosome, 0, "   ")
      assert GenomeBuffer.get_comment(g2, :chromosome, 0) == nil
    end

    test "insert shifts a comment so it stays on its opcode" do
      g =
        GenomeBuffer.new([:push0, :push1, :add, :move])
        |> GenomeBuffer.put_comment(:chromosome, 2, "loop head")

      g2 = GenomeBuffer.insert(g, :chromosome, 1, :dup)

      assert GenomeBuffer.get_section(g2, :chromosome) == [:push0, :dup, :push1, :add, :move]
      assert GenomeBuffer.get_comment(g2, :chromosome, 3) == "loop head"
      assert GenomeBuffer.get_comment(g2, :chromosome, 2) == nil
    end

    test "delete drops the deleted cell's comment and shifts later ones" do
      g =
        GenomeBuffer.new([:push0, :push1, :add, :move])
        |> GenomeBuffer.put_comment(:chromosome, 1, "b")
        |> GenomeBuffer.put_comment(:chromosome, 2, "c")

      g2 = GenomeBuffer.delete(g, :chromosome, 1)

      assert GenomeBuffer.get_section(g2, :chromosome) == [:push0, :add, :move]
      assert GenomeBuffer.get_comment(g2, :chromosome, 0) == nil
      # "b" was on the deleted cell → gone; "c" followed :add down to idx 1
      assert GenomeBuffer.get_comment(g2, :chromosome, 1) == "c"
      refute Enum.any?(g2.comments, fn {_k, v} -> v == "b" end)
    end

    test "move relocates a comment with its opcode" do
      g =
        GenomeBuffer.new([:push0, :push1, :add, :move])
        |> GenomeBuffer.put_comment(:chromosome, 2, "x")

      g2 = GenomeBuffer.move(g, :chromosome, 2, 0)

      assert GenomeBuffer.get_section(g2, :chromosome) == [:add, :push0, :push1, :move]
      assert GenomeBuffer.get_comment(g2, :chromosome, 0) == "x"
    end

    test "delete_range and move_range remap comments consistently with the opcodes" do
      g =
        GenomeBuffer.new([:push0, :push1, :add, :move, :eat])
        |> GenomeBuffer.put_comment(:chromosome, 3, "keep")

      # delete the first two cells; :move(idx3) shifts to idx1
      g2 = GenomeBuffer.delete_range(g, :chromosome, {0, 1})
      assert GenomeBuffer.get_section(g2, :chromosome) == [:add, :move, :eat]
      assert GenomeBuffer.get_comment(g2, :chromosome, 1) == "keep"
    end

    test "an edit in one section leaves other sections' comments untouched" do
      g =
        GenomeBuffer.new([:push0, :add], [[:move, :eat]])
        |> GenomeBuffer.put_comment({:plasmid, 0}, 1, "p")

      g2 = GenomeBuffer.insert(g, :chromosome, 0, :dup)
      assert GenomeBuffer.get_comment(g2, {:plasmid, 0}, 1) == "p"
    end

    test "comments_by_flat maps section-local comments to flat exec indices" do
      g =
        GenomeBuffer.new([:push0, :add], [[:move, :eat]])
        |> GenomeBuffer.put_comment(:chromosome, 1, "c")
        |> GenomeBuffer.put_comment({:plasmid, 0}, 1, "e")

      # chromosome occupies flat 0..1; plasmid 0 starts at flat 2
      assert GenomeBuffer.comments_by_flat(g) == %{1 => "c", 3 => "e"}
    end

    test "comments_by_flat and put_comments_by_flat round-trip" do
      g =
        GenomeBuffer.new([:push0, :add], [[:move, :eat]])
        |> GenomeBuffer.put_comment(:chromosome, 0, "head")
        |> GenomeBuffer.put_comment({:plasmid, 0}, 1, "tail")

      flat = GenomeBuffer.comments_by_flat(g)
      rebuilt = GenomeBuffer.put_comments_by_flat(GenomeBuffer.new([:push0, :add], [[:move, :eat]]), flat)

      assert rebuilt.comments == g.comments
    end

    test "put_comments_by_flat ignores indices past the end of the genome" do
      g = GenomeBuffer.put_comments_by_flat(GenomeBuffer.new([:push0, :add]), %{0 => "ok", 99 => "x"})
      assert GenomeBuffer.get_comment(g, :chromosome, 0) == "ok"
      assert map_size(g.comments) == 1
    end

    test "remove_plasmid drops that plasmid's comments and shifts later plasmids" do
      g =
        GenomeBuffer.new([:push0], [[:move], [:eat]])
        |> GenomeBuffer.put_comment({:plasmid, 0}, 0, "p0")
        |> GenomeBuffer.put_comment({:plasmid, 1}, 0, "p1")

      g2 = GenomeBuffer.remove_plasmid(g, 0)
      assert GenomeBuffer.get_comment(g2, {:plasmid, 0}, 0) == "p1"
      assert map_size(g2.comments) == 1
    end
  end
end
