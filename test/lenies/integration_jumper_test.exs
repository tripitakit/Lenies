defmodule Lenies.IntegrationJumperTest do
  use ExUnit.Case, async: true

  alias Lenies.Interpreter
  alias Lenies.Codeomes.TemplateJumper
  alias Lenies.Interpreter.State

  test "template-jumper sets slot[0] to 1 (proves jump landed at SUCCESS branch)" do
    codeome = TemplateJumper.codeome()
    state = State.new(energy: 1000.0, pos: {0, 0}, dir: :n)

    final = run_until_slot_set(state, codeome, 100)

    assert final.slots[0] == 1,
           "expected slot[0]=1 after template jump (got #{inspect(final.slots)})"
  end

  test "template-jumper FAIL branch sets slot[0] to 2 (sanity check: if jump didn't land, we'd see this)" do
    # This test simulates what happens if we manually start at IP=6 (fail path)
    codeome = TemplateJumper.codeome()
    state = State.new(energy: 1000.0, pos: {0, 0}, dir: :n, ip: 6)

    final = run_until_slot_set(state, codeome, 100)

    # Should see the fail branch set slot[0] = 2
    assert final.slots[0] == 2,
           "expected slot[0]=2 after fail-branch execution (got #{inspect(final.slots)})"
  end

  # Run interpreter steps until slot[0] becomes non-zero (or N steps exhausted)
  defp run_until_slot_set(state, _codeome, 0), do: state

  defp run_until_slot_set(state, codeome, n) do
    case Interpreter.step(state, codeome) do
      {:cont, new_state} ->
        if Map.get(new_state.slots, 0, 0) != 0 do
          new_state
        else
          run_until_slot_set(new_state, codeome, n - 1)
        end

      {:wait_world, _action, new_state} ->
        # template_jumper doesn't use world actions, but be defensive
        if Map.get(new_state.slots, 0, 0) != 0 do
          new_state
        else
          run_until_slot_set(new_state, codeome, n - 1)
        end

      {:halt, _reason, halted_state} ->
        halted_state
    end
  end
end
