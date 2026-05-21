defmodule Lenies.Interpreter.WorldActionTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter, Plasmid}
  alias Lenies.Interpreter.State
  alias Lenies.Codeome.Costs

  # ── :conjugate dispatch tests (I4 fix) ──────────────────────────────────────

  test ":conjugate with sufficient energy returns :wait_world and charges base cost" do
    # A donor with a plasmid and plenty of energy should yield to the world,
    # with the base cost already deducted and IP advanced.
    plasmid = Plasmid.new([:turn_left, :defend, :eat])
    c = Codeome.from_list([:conjugate, :nop_0])
    state =
      State.new(energy: 100.0, pos: {5, 5}, dir: :e)
      |> Map.put(:plasmids, [plasmid])

    assert {:wait_world, {:conjugate, {5, 5}, :e, _ops}, new_state} = Interpreter.step(state, c)
    assert new_state.ip == 1
    base_cost = Costs.cost(:conjugate, 0)
    assert_in_delta new_state.energy, 100.0 - base_cost, 0.0001
  end

  test ":conjugate with empty plasmid list still returns :wait_world (world handles the no-plasmid case)" do
    # Even with no plasmids, dispatch yields to world — the world handler applies
    # the failure push(0) and no additional cost (base already paid here).
    c = Codeome.from_list([:conjugate, :nop_0])
    state = State.new(energy: 100.0, pos: {3, 3}, dir: :n)

    assert {:wait_world, {:conjugate, {3, 3}, :n, []}, new_state} = Interpreter.step(state, c)
    assert new_state.ip == 1
    base_cost = Costs.cost(:conjugate, 0)
    assert_in_delta new_state.energy, 100.0 - base_cost, 0.0001
  end

  # I4 fix: a Lenie whose energy is below the base cost must halt with
  # :starvation AT the :conjugate opcode, not survive to the next opcode.
  # This test FAILS against the pre-fix code (dispatch never charges or halts).
  test ":conjugate halts with :starvation when energy < base cost (I4 fix)" do
    base_cost = Costs.cost(:conjugate, 0)
    # Energy just above 0 but below the base cost — should be fatal.
    low_energy = base_cost - 1.0

    plasmid = Plasmid.new([:eat])
    c = Codeome.from_list([:conjugate, :nop_0])
    state =
      State.new(energy: low_energy, pos: {0, 0}, dir: :n)
      |> Map.put(:plasmids, [plasmid])

    assert {:halt, :starvation, dead_state} = Interpreter.step(state, c)
    assert dead_state.energy <= 0
  end

  test ":sense_front returns :wait_world with action descriptor" do
    c = Codeome.from_list([:sense_front, :push0])
    state = State.new(energy: 100.0, pos: {10, 10}, dir: :e)
    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:sense_front, {10, 10}, :e}
    # IP advanced and cost paid even though world hasn't replied yet
    assert new_state.ip == 1
    assert_in_delta new_state.energy, 100.0 - 0.5, 0.0001
  end

  test ":move returns :wait_world with destination" do
    c = Codeome.from_list([:move, :push0])
    state = State.new(energy: 100.0, pos: {5, 5}, dir: :n)
    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:move, {5, 5}, :n}
    assert new_state.ip == 1
    assert_in_delta new_state.energy, 100.0 - 2.0, 0.0001
  end

  test ":eat returns :wait_world with cell coordinate (current cell)" do
    c = Codeome.from_list([:eat, :push0])
    state = State.new(energy: 100.0, pos: {7, 7})
    assert {:wait_world, action, new_state} = Interpreter.step(state, c)
    assert action == {:eat, {7, 7}}
    assert new_state.ip == 1
  end
end
