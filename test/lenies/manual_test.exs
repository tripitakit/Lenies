defmodule Lenies.ManualTest do
  use ExUnit.Case, async: false

  alias Lenies.Manual

  setup do
    case Process.whereis(Manual) do
      nil -> {:ok, _} = Manual.start_link([])
      _ -> :ok
    end

    :ok
  end

  test "list_chapters/0 returns all 15 chapters in filename order" do
    chapters = Manual.list_chapters()
    assert length(chapters) == 15

    filenames = Enum.map(chapters, & &1.filename)
    expected = ~w(
      README.md
      00-introduction.md
      01-vm-anatomy.md
      02-opcode-reference.md
      03-first-codeome.md
      04-loops-and-templates.md
      05-memory-and-arithmetic.md
      06-procedures.md
      07-replication.md
      08-energy-economy.md
      09-minimal-replicator.md
      10-conjugation-and-plasmids.md
      11-cookbook.md
      A-stack-machines.md
      LLM-APPENDIX.md
    )

    assert MapSet.new(filenames) == MapSet.new(expected)
  end

  test "each chapter has a non-empty title and html" do
    for ch <- Manual.list_chapters() do
      assert is_binary(ch.title)
      assert byte_size(ch.title) > 0
      entry = Manual.get(ch.filename)
      assert entry.html =~ "<"
    end
  end

  test "get/1 with unknown filename returns nil" do
    assert Manual.get("does-not-exist.md") == nil
  end
end
