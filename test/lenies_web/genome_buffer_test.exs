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
      assert GenomeBuffer.flat_index(@genome, :chromosome, 2) == 2
      assert GenomeBuffer.flat_index(@genome, {:plasmid, 0}, 0) == 2
      assert GenomeBuffer.flat_index(@genome, {:plasmid, 2}, 1) == 4
      assert GenomeBuffer.flat_index(@genome, {:plasmid, 9}, 0) == nil
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
end
