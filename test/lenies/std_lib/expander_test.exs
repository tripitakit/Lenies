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
      {:cont, s} = Interpreter.run_k_instructions(State.new(energy: 1000.0), Codeome.from_list(ops), length(ops))
      s.stack
    end

    test "const_ops leaves exactly K on the stack for several K" do
      for k <- [1, 2, 5, 8, 13, 64] do
        {:ok, plan} = Expander.expand(Catalog.get("const-k"), %{"K" => k}, GenomeBuffer.new([:nop_0, :eat, :move, :jmp_t, :ret]), {:chromosome, 0})
        assert [^k | _] = run_to_stack(plan.caret_ops), "K=#{k}"
        assert plan.appended_ops == []
      end
    end

    test "const rejects K < 1" do
      assert {:error, :bad_param} = Expander.expand(Catalog.get("const-k"), %{"K" => 0}, GenomeBuffer.new([:nop_0, :eat, :move, :jmp_t, :ret]), {:chromosome, 0})
    end
  end
end
