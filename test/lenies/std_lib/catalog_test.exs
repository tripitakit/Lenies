defmodule Lenies.StdLib.CatalogTest do
  use ExUnit.Case, async: true
  alias Lenies.StdLib.{Catalog, Snippet, Expander}

  test "all/0 returns Snippet structs with unique ids" do
    all = Catalog.all()
    assert length(all) >= 6
    assert Enum.all?(all, &match?(%Snippet{}, &1))
    ids = Enum.map(all, & &1.id)
    assert ids == Enum.uniq(ids)
  end

  test "get/1 finds by id, nil otherwise" do
    assert %Snippet{id: "not"} = Catalog.get("not")
    assert Catalog.get("nope") == nil
  end

  test "by_category/0 groups, chromosome-safe order" do
    grouped = Catalog.by_category()
    assert is_list(grouped)
    assert {_cat, [%Snippet{} | _]} = hd(grouped)
  end

  test "every inline snippet body is whitelisted opcodes only" do
    ok = Lenies.Codeome.Opcodes.all() |> MapSet.new()

    for %Snippet{kind: :inline, body: body, id: id} <- Catalog.all(),
        Enum.all?(body, &is_atom/1) do
      assert Enum.all?(body, &MapSet.member?(ok, &1)), "#{id} has non-opcode body item"
    end
  end

  describe "operator semantics (interpreter oracle)" do
    alias Lenies.{Interpreter, Codeome}
    alias Lenies.Interpreter.State
    alias LeniesWeb.GenomeBuffer

    defp gx, do: GenomeBuffer.new([:eat, :move, :jmp_t, :ret, :nop_0])

    defp top(id, seed, params \\ %{}) do
      s = Catalog.get(id)
      {:ok, plan} = Expander.expand(s, params, gx(), {:chromosome, 0})
      st = Enum.reduce(seed, State.new(energy: 5000.0), &State.push(&2, &1))
      {_, out} = Interpreter.run_k_instructions(st, Codeome.from_list(plan.caret_ops), 300)
      hd(out.stack)
    end

    test "logic truth tables" do
      assert top("not", [0]) == 1 and top("not", [1]) == 0
      for {a, b, r} <- [{0,0,0},{0,1,0},{1,0,0},{1,1,1}], do: assert top("and", [a, b]) == r
      for {a, b, r} <- [{0,0,0},{0,1,1},{1,0,1},{1,1,1}], do: assert top("or", [a, b]) == r
      for {a, b, r} <- [{0,0,0},{0,1,1},{1,0,1},{1,1,0}], do: assert top("xor", [a, b]) == r
      assert top("bool", [0]) == 0 and top("bool", [5]) == 1 and top("bool", [-3]) == 1
    end

    test "compare" do
      assert top("eq", [4, 4]) == 1 and top("eq", [4, 5]) == 0
      assert top("neq", [4, 5]) == 1 and top("neq", [4, 4]) == 0
      assert top("lt", [3, 5]) == 1 and top("lt", [5, 5]) == 0 and top("lt", [9, 5]) == 0
      assert top("gt", [9, 5]) == 1 and top("gt", [5, 5]) == 0
      assert top("lte", [5, 5]) == 1 and top("lte", [6, 5]) == 0
      assert top("gte", [5, 5]) == 1 and top("gte", [4, 5]) == 0
      assert top("sign", [-7]) == -1 and top("sign", [0]) == 0 and top("sign", [7]) == 1
    end

    test "numeric" do
      assert top("negate", [6]) == -6 and top("double", [6]) == 12
      assert top("abs", [-8]) == 8 and top("abs", [8]) == 8
      assert top("min", [3, 9]) == 3 and top("min", [9, 3]) == 3
      assert top("max", [3, 9]) == 9 and top("max", [9, 3]) == 9
      assert top("clamp", [12], %{"lo" => 0, "hi" => 10}) == 10
      assert top("clamp", [-4], %{"lo" => 0, "hi" => 10}) == 0
      assert top("clamp", [5], %{"lo" => 0, "hi" => 10}) == 5
      assert top("mod-k", [13], %{"K" => 8}) == 5
    end

    test "min/max touch only slot 3" do
      s = Catalog.get("min")
      {:ok, plan} = Expander.expand(s, %{}, gx(), {:chromosome, 0})
      st = State.new(energy: 5000.0) |> State.push(7) |> State.push(2)
      {_, out} = Interpreter.run_k_instructions(st, Codeome.from_list(plan.caret_ops), 300)
      assert State.load(out, 0) == 0 and State.load(out, 1) == 0 and State.load(out, 2) == 0
    end
  end

  describe "every catalog snippet expands valid + runnable" do
    alias Lenies.StdLib.{Catalog, Expander}
    alias LeniesWeb.{GenomeBuffer, CodeomeBuffer}
    alias Lenies.{Interpreter, Codeome}
    alias Lenies.Interpreter.State

    # 9 non-nop ops so even the smallest inline snippet (2 ops) pushes total >= 10
    @base GenomeBuffer.new([
            :nop_0,
            :push0,
            :push1,
            :eat,
            :move,
            :sense_front,
            :turn_right,
            :drop,
            :jmp_t,
            :ret
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
