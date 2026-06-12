defmodule Lenies.Interpreter.ControlFlowTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  test ":jmp_t with no template falls through (no jump)" do
    # IP at :jmp_t, next opcode is :push0 (not a nop), so template is empty,
    # IP advances past :jmp_t only (no template to skip)
    c = Codeome.from_list([:jmp_t, :push0, :push1])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 1
  end

  test ":jmp_t with single-bit template jumps to complement" do
    # Codeome: [:jmp_t, :nop_0, :push0, :push1, :nop_1, :sub]
    # template after :jmp_t = [:nop_0] (length 1)
    # complement = [:nop_1] → found at index 4
    # IP after jump = 4 + 1 = 5 (position AFTER the matched complement)
    c = Codeome.from_list([:jmp_t, :nop_0, :push0, :push1, :nop_1, :sub])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 5
  end

  test ":jmp_t with template not found falls through (advance past template)" do
    c = Codeome.from_list([:jmp_t, :nop_0, :push0, :push1])
    # template = [:nop_0], complement = [:nop_1] — not present
    # IP advances to past template: 1 (start) + 1 (template_len) = 2
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
  end

  test ":jz_t jumps only if top of stack is zero" do
    c = Codeome.from_list([:jz_t, :nop_0, :push0, :nop_1, :sub])
    # stack top = 0 → jump
    state = State.new(energy: 100.0) |> State.push(0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 4
    assert s.stack == []

    # stack top != 0 → fall through past template
    state = State.new(energy: 100.0) |> State.push(7)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    assert s.stack == []
  end

  test ":jnz_t jumps only if top of stack is non-zero" do
    c = Codeome.from_list([:jnz_t, :nop_0, :push0, :nop_1, :sub])
    # stack top != 0 → jump
    state = State.new(energy: 100.0) |> State.push(5)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 4

    # stack top = 0 → fall through
    state = State.new(energy: 100.0) |> State.push(0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
  end

  test ":jlt_t jumps only if top of stack is negative" do
    c = Codeome.from_list([:jlt_t, :nop_0, :push0, :nop_1, :sub])

    # top < 0 → jump (lands past the matched complement :nop_1 at index 3 → ip 4)
    state = State.new(energy: 100.0) |> State.push(-3)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 4
    assert s.stack == []

    # top == 0 → fall through past template (ip 2)
    state = State.new(energy: 100.0) |> State.push(0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    assert s.stack == []

    # top > 0 → fall through past template (ip 2)
    state = State.new(energy: 100.0) |> State.push(7)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    assert s.stack == []
  end

  test ":jgt_t jumps only if top of stack is positive" do
    c = Codeome.from_list([:jgt_t, :nop_0, :push0, :nop_1, :sub])

    # top > 0 → jump (lands past the matched complement :nop_1 at index 3 → ip 4)
    state = State.new(energy: 100.0) |> State.push(5)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 4
    assert s.stack == []

    # top == 0 → fall through
    state = State.new(energy: 100.0) |> State.push(0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    assert s.stack == []

    # top < 0 → fall through
    state = State.new(energy: 100.0) |> State.push(-2)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    assert s.stack == []
  end

  test ":jlt_t consumes exactly one stack value (taken and fall-through)" do
    c = Codeome.from_list([:jlt_t, :nop_0, :push0, :nop_1, :sub])

    # taken: top -1, 99 below survives
    state = State.new(energy: 100.0) |> State.push(99) |> State.push(-1)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 4
    assert s.stack == [99]

    # fall-through: top 4, 99 below survives
    state = State.new(energy: 100.0) |> State.push(99) |> State.push(4)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    assert s.stack == [99]
  end

  test ":jgt_t consumes exactly one stack value (taken and fall-through)" do
    c = Codeome.from_list([:jgt_t, :nop_0, :push0, :nop_1, :sub])

    # taken: top 8, 99 below survives
    state = State.new(energy: 100.0) |> State.push(99) |> State.push(8)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 4
    assert s.stack == [99]

    # fall-through: top -6, 99 below survives
    state = State.new(energy: 100.0) |> State.push(99) |> State.push(-6)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    assert s.stack == [99]
  end

  test ":jlt_t / :jgt_t cost scales with template length like other jumps" do
    # 4-bit template; base 0.2 + 0.05 * 4 = 0.4 whether taken or not
    c_lt = Codeome.from_list([:jlt_t, :nop_0, :nop_0, :nop_0, :nop_0, :push0])
    state = State.new(energy: 100.0) |> State.push(-1)
    {:cont, s} = Interpreter.step(state, c_lt)
    assert_in_delta s.energy, 100.0 - 0.4, 0.0001

    c_gt = Codeome.from_list([:jgt_t, :nop_0, :nop_0, :nop_0, :nop_0, :push0])
    state = State.new(energy: 100.0) |> State.push(1)
    {:cont, s} = Interpreter.step(state, c_gt)
    assert_in_delta s.energy, 100.0 - 0.4, 0.0001
  end

  test ":call_t pushes return address on call_stack and jumps" do
    c = Codeome.from_list([:call_t, :nop_0, :push0, :push1, :nop_1, :ret])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    # jumped to past :nop_1 → ip = 5
    assert s.ip == 5
    # return address is the position right after template = 2
    assert s.call_stack == [2]
  end

  test ":ret pops return address from call_stack and jumps there" do
    state = State.new(energy: 100.0, ip: 5, call_stack: [2])
    c = Codeome.from_list([:nop_0, :nop_0, :push0, :nop_1, :nop_1, :ret])
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    assert s.call_stack == []
  end

  test ":ret with empty call_stack falls through (advances IP by 1)" do
    state = State.new(energy: 100.0, ip: 0)
    c = Codeome.from_list([:ret, :push0])
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 1
  end

  test "jump cost scales with template length" do
    # 4-bit template
    c = Codeome.from_list([:jmp_t, :nop_0, :nop_0, :nop_0, :nop_0, :push0])
    state = State.new(energy: 100.0)
    {:cont, s} = Interpreter.step(state, c)
    # base 0.2 + 0.05 * 4 = 0.4
    assert_in_delta s.energy, 100.0 - 0.4, 0.0001
  end

  # I11 — single-pop semantics for conditional jumps

  test ":jmp_t (:always) does not consume any stack value" do
    c = Codeome.from_list([:jmp_t, :push0])
    state = State.new(energy: 100.0) |> State.push(42) |> State.push(7)
    {:cont, s} = Interpreter.step(state, c)
    # Stack depth unchanged: :always pops nothing
    # push(42) then push(7) → [7, 42] (7 on top)
    assert length(s.stack) == 2
    assert s.stack == [7, 42]
  end

  test ":jz_t consumes exactly one stack value on jump taken" do
    # top = 0 → jump taken
    c = Codeome.from_list([:jz_t, :nop_0, :push0, :nop_1, :sub])
    state = State.new(energy: 100.0) |> State.push(99) |> State.push(0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 4
    # Only the top (0) was consumed; 99 remains
    assert s.stack == [99]
  end

  test ":jz_t consumes exactly one stack value on fall-through" do
    # top != 0 → fall through
    c = Codeome.from_list([:jz_t, :nop_0, :push0, :nop_1, :sub])
    state = State.new(energy: 100.0) |> State.push(99) |> State.push(5)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    # Only the top (5) was consumed; 99 remains
    assert s.stack == [99]
  end

  test ":jnz_t consumes exactly one stack value on jump taken" do
    # top != 0 → jump taken
    c = Codeome.from_list([:jnz_t, :nop_0, :push0, :nop_1, :sub])
    state = State.new(energy: 100.0) |> State.push(99) |> State.push(3)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 4
    # Only the top (3) was consumed; 99 remains
    assert s.stack == [99]
  end

  test ":jnz_t consumes exactly one stack value on fall-through" do
    # top = 0 → fall through
    c = Codeome.from_list([:jnz_t, :nop_0, :push0, :nop_1, :sub])
    state = State.new(energy: 100.0) |> State.push(99) |> State.push(0)
    {:cont, s} = Interpreter.step(state, c)
    assert s.ip == 2
    # Only the top (0) was consumed; 99 remains
    assert s.stack == [99]
  end
end
