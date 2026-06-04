defmodule LeniesWeb.JumpTargetsTest do
  use ExUnit.Case, async: false

  alias LeniesWeb.JumpTargets

  test "computes a forward complement target for a jmp_t" do
    # jmp_t at 0, template nop_0 at 1; complement nop_1 sits at index 3.
    buffer = [:jmp_t, :nop_0, :add, :nop_1, :eat]
    assert %{0 => {:ok, 3}} = JumpTargets.targets(buffer)
  end

  test "reports :not_found when no complement exists" do
    buffer = [:jmp_t, :nop_0, :add, :eat]
    assert %{0 => :not_found} = JumpTargets.targets(buffer)
  end

  test "ignores non-jump opcodes" do
    assert JumpTargets.targets([:push0, :add, :eat]) == %{}
  end

  test "handles multiple jumps" do
    buffer = [:jmp_t, :nop_0, :nop_1, :jz_t, :nop_1, :nop_0]
    result = JumpTargets.targets(buffer)
    assert Map.has_key?(result, 0)
    assert Map.has_key?(result, 3)
  end

  test "loops/1 is empty when all jumps are forward" do
    # forward target test elsewhere in this file confirms [:jmp_t, :nop_0, :add, :nop_1, :eat] => %{0 => {:ok, 3}}
    assert JumpTargets.loops([:jmp_t, :nop_0, :add, :nop_1, :eat]) == []
  end

  test "loops/1 is exactly the backward-only filter of targets/1" do
    buffer = [:nop_1, :add, :add, :jmp_t, :nop_0, :eat, :jz_t, :nop_1, :nop_0]

    expected =
      buffer
      |> JumpTargets.targets()
      |> Enum.flat_map(fn
        {jump, {:ok, target}} when target < jump -> [{jump, target}]
        _ -> []
      end)
      |> Enum.sort()

    assert JumpTargets.loops(buffer) == expected
  end
end
