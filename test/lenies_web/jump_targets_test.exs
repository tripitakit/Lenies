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

  test "loops/1 includes a real backward jump and excludes forward ones" do
    # jmp_t at index 2; template nop_0 at index 3; complement nop_1 sits at
    # index 0 (only reachable via the backward search — no nop_1 exists forward
    # of the jump). So targets/1 returns %{2 => {:ok, 0}} and loops/1 yields
    # [{2, 0}] — a genuine backward jump (0 < 2).
    buffer = [:nop_1, :add, :jmp_t, :nop_0, :eat]

    loops = JumpTargets.loops(buffer)

    # at least one real backward loop present
    assert Enum.any?(loops, fn {jump, target} -> target < jump end)

    # loops/1 is exactly the backward-only filter of targets/1
    expected =
      buffer
      |> JumpTargets.targets()
      |> Enum.flat_map(fn
        {j, {:ok, t}} when t < j -> [{j, t}]
        _ -> []
      end)
      |> Enum.sort()

    assert loops == expected
  end
end
