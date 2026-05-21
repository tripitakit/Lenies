defmodule Lenies.Interpreter.MakePlasmidTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter, Plasmid}
  alias Lenies.Interpreter.State

  defp run_one(state, codeome) do
    {:cont, new_state} = Interpreter.run_k_instructions(state, codeome, 1)
    new_state
  end

  test ":make_plasmid with valid args creates plasmid and pushes 1" do
    # Build a 10-opcode codeome ending with :make_plasmid; jump IP to it
    # with [start=0, length=4] on the stack.
    codeome = Codeome.from_list([
      :eat, :move, :turn_left, :turn_right, :defend,
      :sense_front, :drop, :eat, :move, :make_plasmid
    ])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> State.push(0)
      |> State.push(4)
      |> Map.put(:ip, 9)

    new_state = run_one(state, codeome)

    assert [1 | _] = new_state.stack
    assert [%Plasmid{opcodes: [:eat, :move, :turn_left, :turn_right]}] = new_state.plasmids
    expected_energy = 100.0 - (2.0 + 0.05 * 4)
    assert_in_delta new_state.energy, expected_energy, 0.001
  end

  test ":make_plasmid with length=0 pushes 0 and does not create plasmid" do
    codeome = Codeome.from_list([:eat, :move, :make_plasmid])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> State.push(0)
      |> State.push(0)
      |> Map.put(:ip, 2)

    new_state = run_one(state, codeome)

    assert [0 | _] = new_state.stack
    assert new_state.plasmids == []
    assert_in_delta new_state.energy, 100.0 - 2.0, 0.001
  end

  test ":make_plasmid with length=65 pushes 0 and pays base cost" do
    codeome = Codeome.from_list([:eat, :move, :make_plasmid])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> State.push(0)
      |> State.push(65)
      |> Map.put(:ip, 2)

    new_state = run_one(state, codeome)

    assert [0 | _] = new_state.stack
    assert new_state.plasmids == []
    assert_in_delta new_state.energy, 100.0 - 2.0, 0.001
  end

  test ":make_plasmid wraps start_addr toroidally (start_addr at exact size)" do
    codeome = Codeome.from_list([:eat, :move, :turn_left, :make_plasmid])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> State.push(4)
      |> State.push(2)
      |> Map.put(:ip, 3)

    new_state = run_one(state, codeome)

    assert [%Plasmid{opcodes: [:eat, :move]}] = new_state.plasmids
  end

  test ":make_plasmid toroidal wrap reads across the codeome seam" do
    # 4-op codeome; start_addr=3, length=3 should read indices 3, 0, 1
    # (wrapping from end to beginning).
    codeome = Codeome.from_list([:eat, :move, :turn_left, :defend, :make_plasmid])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> State.push(3)
      |> State.push(3)
      |> Map.put(:ip, 4)

    new_state = run_one(state, codeome)

    assert [%Plasmid{opcodes: [:defend, :make_plasmid, :eat]}] = new_state.plasmids
  end

  test ":make_plasmid appends to an existing single plasmid (does not replace)" do
    # I3 fix: make_plasmid must append, not overwrite
    codeome = Codeome.from_list([:eat, :move, :make_plasmid])
    existing = Plasmid.new([:turn_left, :turn_right])

    state =
      State.new(
        energy: 100.0,
        pos: {0, 0},
        dir: :n,
        plasmids: [existing]
      )
      |> State.push(0)
      |> State.push(2)
      |> Map.put(:ip, 2)

    new_state = run_one(state, codeome)

    # Length increases by 1; existing plasmid is still first
    assert length(new_state.plasmids) == 2
    assert Enum.at(new_state.plasmids, 0) == existing
    assert %Plasmid{opcodes: [:eat, :move]} = Enum.at(new_state.plasmids, 1)
  end

  test ":make_plasmid appends when carrying multiple plasmids" do
    # I3 fix: works for N > 1 pre-existing plasmids
    codeome = Codeome.from_list([:eat, :move, :make_plasmid])
    p1 = Plasmid.new([:turn_left])
    p2 = Plasmid.new([:turn_right])

    state =
      State.new(
        energy: 100.0,
        pos: {0, 0},
        dir: :n,
        plasmids: [p1, p2]
      )
      |> State.push(0)
      |> State.push(2)
      |> Map.put(:ip, 2)

    new_state = run_one(state, codeome)

    assert length(new_state.plasmids) == 3
    assert Enum.at(new_state.plasmids, 0) == p1
    assert Enum.at(new_state.plasmids, 1) == p2
    assert %Plasmid{opcodes: [:eat, :move]} = Enum.at(new_state.plasmids, 2)
  end

  test ":make_plasmid with no prior plasmids yields exactly one" do
    # Regression guard: empty start still yields exactly one plasmid
    codeome = Codeome.from_list([:eat, :move, :make_plasmid])

    state =
      State.new(energy: 100.0, pos: {0, 0}, dir: :n)
      |> State.push(0)
      |> State.push(2)
      |> Map.put(:ip, 2)

    new_state = run_one(state, codeome)

    assert length(new_state.plasmids) == 1
    assert %Plasmid{opcodes: [:eat, :move]} = hd(new_state.plasmids)
  end
end
