defmodule Lenies.StdLib.ExpanderTest do
  use ExUnit.Case, async: true
  alias Lenies.StdLib.{Expander, Catalog, InsertPlan}
  alias LeniesWeb.GenomeBuffer

  defp genome, do: GenomeBuffer.new([:nop_0, :sense_front, :eat, :move, :jmp_t])

  test "inline snippet → caret_ops are the literal body, nothing appended" do
    s = Catalog.get("graze-step")

    assert {:ok, %InsertPlan{caret_ops: [:eat, :move], appended_ops: [], anchor: nil}} =
             Expander.expand(s, %{}, genome(), {:chromosome, 0})
  end

  describe "const generation" do
    alias Lenies.{Interpreter, Codeome}
    alias Lenies.Interpreter.State

    defp run_to_stack(ops) do
      {:cont, s} =
        Interpreter.run_k_instructions(
          State.new(energy: 1000.0),
          Codeome.from_list(ops),
          length(ops)
        )

      s.stack
    end

    test "const_ops leaves exactly K on the stack for several K" do
      for k <- [1, 2, 5, 8, 13, 64] do
        {:ok, plan} =
          Expander.expand(
            Catalog.get("const-k"),
            %{"K" => k},
            GenomeBuffer.new([:nop_0, :eat, :move, :jmp_t, :ret]),
            {:chromosome, 0}
          )

        assert [^k | _] = run_to_stack(plan.caret_ops), "K=#{k}"
        assert plan.appended_ops == []
      end
    end

    test "const rejects K < 1" do
      assert {:error, :bad_param} =
               Expander.expand(
                 Catalog.get("const-k"),
                 %{"K" => 0},
                 GenomeBuffer.new([:nop_0, :eat, :move, :jmp_t, :ret]),
                 {:chromosome, 0}
               )
    end
  end

  describe "callable functions" do
    alias LeniesWeb.GenomeBuffer
    defp g0, do: GenomeBuffer.new([:nop_0, :sense_front, :eat, :move, :jmp_t])

    test "first insert: body appended, call at caret, anchor recorded in comments" do
      s = Catalog.get("scan-turn")
      {:ok, plan} = Expander.expand(s, %{}, g0(), {:chromosome, 2})
      assert plan.anchor != nil
      assert [:call_t | _] = plan.caret_ops
      assert hd(plan.appended_ops) == :push0
      assert :ret in plan.appended_ops
      assert [{_offset, "stdlib:scan-turn:anchor=" <> _}] = plan.comments
    end

    test "second insert when already defined: only a call, nothing appended" do
      s = Catalog.get("scan-turn")
      {:ok, p1} = Expander.expand(s, %{}, g0(), {:chromosome, 2})

      g1 =
        g0()
        |> GenomeBuffer.update_section(:chromosome, &(&1 ++ p1.appended_ops))
        |> then(fn g ->
          {offset, txt} = hd(p1.comments)
          GenomeBuffer.put_comment(g, :chromosome, length(g0().chromosome) + offset, txt)
        end)

      {:ok, p2} = Expander.expand(s, %{}, g1, {:chromosome, 1})
      assert [:call_t | _] = p2.caret_ops
      assert p2.appended_ops == []
    end
  end

  describe "allocate_labels/2" do
    alias LeniesWeb.GenomeBuffer

    test "returns n distinct 5-nop patterns, none equal to another or its complement" do
      g = GenomeBuffer.new([:eat, :move, :jmp_t, :ret, :nop_0])
      {:ok, pats} = Expander.allocate_labels(g, 3)
      assert length(pats) == 3
      assert Enum.all?(pats, &(length(&1) == 5 and Enum.all?(&1, fn o -> o in [:nop_0, :nop_1] end)))
      bits = Enum.map(pats, fn p -> Enum.map(p, fn :nop_1 -> 1; :nop_0 -> 0 end) end)
      assert Enum.uniq(bits) == bits
      flips = Enum.map(bits, fn b -> Enum.map(b, &(1 - &1)) end)
      assert MapSet.disjoint?(MapSet.new(bits), MapSet.new(flips))
    end

    test "n = 0 returns an empty list" do
      g = GenomeBuffer.new([:eat, :move, :jmp_t, :ret, :nop_0])
      assert {:ok, []} = Expander.allocate_labels(g, 0)
    end

    test "avoids 5-nop runs already in the chromosome" do
      g = GenomeBuffer.new([:nop_1, :nop_1, :nop_1, :nop_1, :nop_1, :eat, :move, :jmp_t])
      {:ok, [p]} = Expander.allocate_labels(g, 1)
      refute p == [:nop_1, :nop_1, :nop_1, :nop_1, :nop_1]
      refute p == [:nop_0, :nop_0, :nop_0, :nop_0, :nop_0]
    end

    test "exhaustion → {:error, :anchor_namespace_full}" do
      g0 = GenomeBuffer.new([:eat, :move, :jmp_t, :ret, :nop_0])
      g = Enum.reduce(0..31, g0, fn i, acc ->
        pat = i |> Integer.to_string(2) |> String.pad_leading(5, "0")
        GenomeBuffer.put_comment(acc, :chromosome, i, "stdlib:f#{i}:anchor=#{pat}")
      end)
      assert {:error, :anchor_namespace_full} = Expander.allocate_labels(g, 1)
    end
  end

  describe "branch/label compiler" do
    alias Lenies.{Interpreter, Codeome}
    alias Lenies.Interpreter.State
    alias Lenies.StdLib.Snippet
    alias LeniesWeb.GenomeBuffer

    defp g, do: GenomeBuffer.new([:eat, :move, :jmp_t, :ret, :nop_0])

    defp run_top(ops, seed) do
      st = Enum.reduce(seed, State.new(energy: 1000.0), &State.push(&2, &1))
      {_, s} = Interpreter.run_k_instructions(st, Codeome.from_list(ops), 200)
      s.stack
    end

    defp inline(body), do: %Snippet{id: "t", name: "t", category: "T", kind: :inline, signature: "", body: body}

    test "is-nonzero (bool) via jnz/jz: 0 -> 0, nonzero -> 1" do
      body = [{:branch, :jnz, :t}, :push0, {:branch, :jmp, :e}, {:label, :t}, :push1, {:label, :e}]
      {:ok, plan} = Expander.expand(inline(body), %{}, g(), {:chromosome, 0})
      assert [0 | _] = run_top(plan.caret_ops, [0])
      assert [1 | _] = run_top(plan.caret_ops, [7])
    end

    test "lt via sub + jlt: 3<5 -> 1, 5<5 -> 0, 9<5 -> 0" do
      body = [:sub, {:branch, :jlt, :t}, :push0, {:branch, :jmp, :e}, {:label, :t}, :push1, {:label, :e}]
      {:ok, plan} = Expander.expand(inline(body), %{}, g(), {:chromosome, 0})
      # seed order: bottom..top, so push a then b => stack [.. a b], sub = a-b
      assert [1 | _] = run_top(plan.caret_ops, [3, 5])
      assert [0 | _] = run_top(plan.caret_ops, [5, 5])
      assert [0 | _] = run_top(plan.caret_ops, [9, 5])
    end

    test "backward branch (loop) lands on its own label" do
      # decrement slot via loop: start counter 3 in slot 2, loop until 0, leave 0 on stack
      body = [
        {:label, :h}, {:const, 2}, :load, :push1, :sub, :dup, {:const, 2}, :store,
        {:branch, :jnz, :h}
      ]
      {:ok, plan} = Expander.expand(inline(body), %{}, g(), {:chromosome, 0})
      seed = [:push1, :push1, :add, :push1, :add, :push1, :push1, :add, :store]  # value 3, index 2 -> slot2 = 3
      {_, s0} = Interpreter.run_k_instructions(State.new(energy: 5000.0), Codeome.from_list(seed), length(seed))
      # 50 steps: enough for 3 iterations (3×17 real ops + 3×5 label nops = 66
      # steps max, but jnz template search resolves in 1 step so ~50 suffices),
      # stops before circular wrap re-decrements slot 2.
      {_, s} = Interpreter.run_k_instructions(%{s0 | stack: []}, Codeome.from_list(plan.caret_ops), 50)
      assert State.load(s, 2) == 0
    end
  end

  describe "repeat macro" do
    alias Lenies.{Interpreter, Codeome}
    alias Lenies.Interpreter.State
    alias Lenies.StdLib.Snippet
    alias LeniesWeb.GenomeBuffer

    test "body runs exactly K times (observed via a slot-1 counter)" do
      # body increments slot 1; after the loop a self-jmp sentinel spins harmlessly.
      body = [
        {:repeat, :K, [:push1, :load, :push1, :add, :push1, :store]},
        {:label, :done}, {:branch, :jmp, :done}
      ]
      s = %Snippet{id: "t", name: "t", category: "T", kind: :param, signature: "", params: [:K], body: body}
      g = GenomeBuffer.new([:eat, :move, :jmp_t, :ret, :nop_0])
      {:ok, plan} = Expander.expand(s, %{"K" => 4}, g, {:chromosome, 0})
      {_, st} = Interpreter.run_k_instructions(State.new(energy: 100_000.0), Codeome.from_list(plan.caret_ops), 1000)
      assert State.load(st, 1) == 4
    end
  end

  describe "nested repeats" do
    alias Lenies.{Interpreter, Codeome}
    alias Lenies.Interpreter.State
    alias Lenies.StdLib.Snippet
    alias LeniesWeb.GenomeBuffer

    test "outer repeat K=2, inner repeat M=3 yields slot-1 value of 6 (2x3)" do
      # Inner body: increment slot 1 (load slot1, add 1, store slot1)
      # Inner repeat: run M times => slot1 += M per outer iteration
      # Outer repeat: run K times => slot1 == K*M == 6
      # Sentinel: self-jmp so execution spins harmlessly after the loop
      body = [
        {:repeat, :K, [{:repeat, :M, [:push1, :load, :push1, :add, :push1, :store]}]},
        {:label, :done}, {:branch, :jmp, :done}
      ]
      s = %Snippet{id: "t", name: "t", category: "T", kind: :param, signature: "", params: [:K, :M], body: body}
      g = GenomeBuffer.new([:eat, :move, :jmp_t, :ret, :nop_0])
      {:ok, plan} = Expander.expand(s, %{"K" => 2, "M" => 3}, g, {:chromosome, 0})
      {_, st} = Interpreter.run_k_instructions(State.new(energy: 100_000.0), Codeome.from_list(plan.caret_ops), 2000)
      assert State.load(st, 1) == 6
    end
  end

  describe "anchor allocation" do
    alias LeniesWeb.GenomeBuffer

    test "picks a 5-nop pattern, avoids used patterns and their complements" do
      g = GenomeBuffer.new([:nop_1, :nop_1, :nop_1, :nop_1, :nop_1, :eat, :move, :jmp_t])
      {:ok, anchor} = Expander.allocate_anchor(g)
      assert length(anchor) == 5
      assert Enum.all?(anchor, &(&1 in [:nop_0, :nop_1]))
      refute anchor == [:nop_1, :nop_1, :nop_1, :nop_1, :nop_1]
      refute anchor == [:nop_0, :nop_0, :nop_0, :nop_0, :nop_0]
    end

    test "exhaustion → {:error, :anchor_namespace_full}" do
      # Register all 32 patterns at distinct comment indices.
      g0 = GenomeBuffer.new([:eat, :move, :jmp_t, :ret, :nop_0])

      g =
        Enum.reduce(0..31, g0, fn i, acc ->
          pat = i |> Integer.to_string(2) |> String.pad_leading(5, "0")
          GenomeBuffer.put_comment(acc, :chromosome, i, "stdlib:f#{i}:anchor=#{pat}")
        end)

      assert {:error, :anchor_namespace_full} = Expander.allocate_anchor(g)
    end
  end
end
