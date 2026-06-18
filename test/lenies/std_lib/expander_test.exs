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
end
