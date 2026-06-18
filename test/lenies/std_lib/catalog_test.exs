defmodule Lenies.StdLib.CatalogTest do
  use ExUnit.Case, async: true
  alias Lenies.StdLib.{Catalog, Snippet}

  test "all/0 returns Snippet structs with unique ids" do
    all = Catalog.all()
    assert length(all) >= 6
    assert Enum.all?(all, &match?(%Snippet{}, &1))
    ids = Enum.map(all, & &1.id)
    assert ids == Enum.uniq(ids)
  end

  test "get/1 finds by id, nil otherwise" do
    assert %Snippet{id: "random-bit"} = Catalog.get("random-bit")
    assert Catalog.get("nope") == nil
  end

  test "by_category/0 groups, chromosome-safe order" do
    grouped = Catalog.by_category()
    assert is_list(grouped)
    assert {_cat, [%Snippet{} | _]} = hd(grouped)
  end

  test "every inline snippet body is whitelisted opcodes only" do
    ok = Lenies.Codeome.Opcodes.all() |> MapSet.new()
    for %Snippet{kind: :inline, body: body, id: id} <- Catalog.all() do
      assert Enum.all?(body, &MapSet.member?(ok, &1)), "#{id} has non-opcode body item"
    end
  end

  describe "every catalog snippet expands valid + runnable" do
    alias Lenies.StdLib.{Catalog, Expander}
    alias LeniesWeb.{GenomeBuffer, CodeomeBuffer}
    alias Lenies.{Interpreter, Codeome}
    alias Lenies.Interpreter.State

    # 9 non-nop ops so even the smallest inline snippet (2 ops) pushes total >= 10
    @base GenomeBuffer.new([
      :nop_0, :push0, :push1, :eat, :move, :sense_front, :turn_right, :drop, :jmp_t, :ret
    ])

    test "expansion yields whitelisted opcodes, a valid codeome, and runs without crashing" do
      ok = Lenies.Codeome.Opcodes.all() |> MapSet.new()

      for s <- Catalog.all() do
        params = Map.new(s.params, fn p -> {Atom.to_string(p), 8} end)
        assert {:ok, plan} = Expander.expand(s, params, @base, {:chromosome, 1}), "expand #{s.id}"
        ops = plan.caret_ops ++ plan.appended_ops
        assert Enum.all?(ops, &MapSet.member?(ok, &1)), "#{s.id} produced a non-opcode"
        merged = @base.chromosome ++ plan.appended_ops ++ plan.caret_ops
        assert {:ok, _} = CodeomeBuffer.validate(merged), "#{s.id} invalid codeome"
        c = Codeome.from_list(merged)
        result = Interpreter.run_k_instructions(State.new(energy: 1000.0), c, 20) |> elem(0)
        assert result in [:cont, :wait_world, :halt], "#{s.id} crashed with #{result}"
      end
    end
  end
end
