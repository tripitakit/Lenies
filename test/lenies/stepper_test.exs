defmodule Lenies.StepperTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Plasmid, Stepper}

  describe "start_session/2" do
    test "initialises interp with default energy=5000, pos=(32,32), dir=:n" do
      codeome = Codeome.from_list([:push1, :dup, :add])
      session = Stepper.start_session(codeome, [])

      assert session.codeome == codeome
      assert session.interp.energy == 5000.0
      assert session.interp.pos == {32, 32}
      assert session.interp.dir == :n
      assert session.interp.ip == 0
      assert session.interp.stack == []
      assert session.interp.slots == %{0 => 0, 1 => 0, 2 => 0, 3 => 0}
      assert session.history == []
      assert session.breakpoints == MapSet.new()
      assert session.step_count == 0
      assert session.status == :ready
      assert session.halt_reason == nil
    end

    test "world has the debug Lenie placed at the starting position" do
      codeome = Codeome.from_list([:push1])
      session = Stepper.start_session(codeome, [])

      assert session.world.cells[{32, 32}].lenie_id == "debug"
      assert session.world.lenies["debug"].codeome == codeome
      assert session.world.lenies["debug"].kind == :debug
    end

    test "accepts overrides for energy / pos / dir" do
      codeome = Codeome.from_list([:push1])
      session = Stepper.start_session(codeome, energy: 200.0, pos: {0, 0}, dir: :e)

      assert session.interp.energy == 200.0
      assert session.interp.pos == {0, 0}
      assert session.interp.dir == :e
      assert session.world.cells[{0, 0}].lenie_id == "debug"
    end
  end

  describe "step/1" do
    test "single step advances IP and updates stack" do
      codeome = Codeome.from_list([:push1, :dup, :add])
      session = Stepper.start_session(codeome, [])

      {:ok, s1} = Stepper.step(session)
      assert s1.interp.ip == 1
      assert s1.interp.stack == [1]
      assert s1.step_count == 1
      assert s1.status == :ready
      assert length(s1.history) == 1
    end

    test "stepping through push1 / dup / add yields stack [2]" do
      codeome = Codeome.from_list([:push1, :dup, :add])
      session = Stepper.start_session(codeome, [])

      {:ok, s1} = Stepper.step(session)
      {:ok, s2} = Stepper.step(s1)
      {:ok, s3} = Stepper.step(s2)

      assert s3.interp.stack == [2]
      assert s3.step_count == 3
    end

    test "step resolves :wait_world via Stepper.World" do
      codeome = Codeome.from_list([:move])
      session = Stepper.start_session(codeome, pos: {10, 10}, dir: :n)

      {:ok, s1} = Stepper.step(session)
      assert s1.interp.pos == {10, 9}
      assert s1.world.cells[{10, 9}].lenie_id == "debug"
    end

    test "step on starvation yields :halted with :starvation" do
      codeome = Codeome.from_list([:push1])
      session = Stepper.start_session(codeome, energy: 0.05)

      {:ok, s1} = Stepper.step(session)
      assert s1.status == :halted
      assert s1.halt_reason == :starvation
    end

    test "step on already-halted session is a no-op" do
      codeome = Codeome.from_list([:push1])
      session = Stepper.start_session(codeome, energy: 0.05)
      {:ok, s1} = Stepper.step(session)
      {:ok, s2} = Stepper.step(s1)
      assert s1 == s2
    end
  end

  describe "step_back/1" do
    test "single step then step_back restores original state" do
      codeome = Codeome.from_list([:push1, :dup, :add])
      s0 = Stepper.start_session(codeome, [])

      {:ok, s1} = Stepper.step(s0)
      assert s1.interp.stack == [1]

      {:ok, s2} = Stepper.step_back(s1)
      assert s2.interp.stack == s0.interp.stack
      assert s2.interp.ip == s0.interp.ip
      assert s2.step_count == 0
      assert s2.history == []
    end

    test "step_back with empty history is a no-op (returns same session)" do
      codeome = Codeome.from_list([:push1])
      s0 = Stepper.start_session(codeome, [])
      {:ok, s1} = Stepper.step_back(s0)
      assert s1 == s0
    end

    test "history is capped at 50 entries" do
      codeome = Codeome.from_list([:push1])

      s =
        Enum.reduce(1..60, Stepper.start_session(codeome, energy: 100_000.0), fn _, acc ->
          {:ok, n} = Stepper.step(acc)
          n
        end)

      assert length(s.history) == 50
      assert s.step_count == 60
    end
  end

  describe "run/2 + breakpoints + safety cap" do
    test "run/2 with no breakpoints runs until halt" do
      codeome = Codeome.from_list([:push1])
      s = Stepper.start_session(codeome, energy: 1.0)
      {:ok, s1} = Stepper.run(s, max_steps: 100)
      assert s1.status == :halted
      assert s1.halt_reason == :starvation
    end

    test "run/2 with a breakpoint at IP 2 stops there" do
      codeome = Codeome.from_list([:push1, :dup, :push1, :add])
      s0 = Stepper.start_session(codeome, energy: 1000.0)
      s1 = Stepper.toggle_breakpoint(s0, 2)
      {:ok, s2} = Stepper.run(s1, max_steps: 100)
      assert s2.status == :breakpoint_hit
      assert s2.interp.ip == 2
    end

    test "run/2 with max_steps respects the cap" do
      codeome = Codeome.from_list([:nop_0])
      s0 = Stepper.start_session(codeome, energy: 1_000_000.0)
      {:ok, s1} = Stepper.run(s0, max_steps: 5)
      assert s1.step_count == 5
      assert s1.status == :paused
    end
  end

  describe "toggle_breakpoint/2" do
    test "toggles a breakpoint at the given IP" do
      codeome = Codeome.from_list([:push1, :dup])
      s = Stepper.start_session(codeome, [])

      s1 = Stepper.toggle_breakpoint(s, 1)
      assert MapSet.member?(s1.breakpoints, 1)

      s2 = Stepper.toggle_breakpoint(s1, 1)
      refute MapSet.member?(s2.breakpoints, 1)
    end
  end

  describe "reset/1" do
    test "reset restores the session to step 0 but preserves seeds and breakpoints" do
      codeome = Codeome.from_list([:push1])
      s0 = Stepper.start_session(codeome, [])
      seed_codeome = Codeome.from_list([:nop_0])
      {:ok, s1} = Stepper.place_seed(s0, %{codeome: seed_codeome, plasmids: []}, {10, 10})
      s2 = Stepper.toggle_breakpoint(s1, 0)
      {:ok, s3} = Stepper.step(s2)

      s4 = Stepper.reset(s3)

      assert s4.step_count == 0
      assert s4.history == []
      assert MapSet.member?(s4.breakpoints, 0)
      assert Map.has_key?(s4.world.lenies, "debug")
      seed_id = s4.world.lenies |> Map.keys() |> Enum.find(&String.starts_with?(&1, "seed-"))
      assert seed_id != nil
    end
  end

  describe "place_seed/3" do
    test "places a seed Lenie at the given cell" do
      codeome = Codeome.from_list([:push1])
      s0 = Stepper.start_session(codeome, [])
      seed = %{codeome: Codeome.from_list([:nop_0]), plasmids: []}

      {:ok, s1} = Stepper.place_seed(s0, seed, {20, 20})

      assert s1.world.cells[{20, 20}].lenie_id != nil
      assert s1.world.cells[{20, 20}].lenie_id |> String.starts_with?("seed-")
    end

    test "place_seed refuses to overwrite an occupied cell" do
      codeome = Codeome.from_list([:push1])
      s0 = Stepper.start_session(codeome, pos: {20, 20})
      seed = %{codeome: Codeome.from_list([:nop_0]), plasmids: []}

      assert {:error, :cell_occupied} = Stepper.place_seed(s0, seed, {20, 20})
    end
  end

  describe "set_place_seed_mode/2" do
    test "enters and exits place-seed mode" do
      codeome = Codeome.from_list([:push1])
      s0 = Stepper.start_session(codeome, [])

      s1 = Stepper.set_place_seed_mode(s0, :minimal_replicator)
      assert s1.place_seed_mode == %{seed_id: :minimal_replicator}

      s2 = Stepper.set_place_seed_mode(s1, nil)
      assert s2.place_seed_mode == nil
    end
  end

  describe "delay_ms_for/1" do
    test "converts opcodes/sec to a tick delay, clamping at >= 1/sec" do
      assert Lenies.Stepper.delay_ms_for(1) == 1000
      assert Lenies.Stepper.delay_ms_for(100) == 10
      assert Lenies.Stepper.delay_ms_for(0) == 1000
      assert Lenies.Stepper.delay_ms_for(-5) == 1000
    end
  end

  describe "world_ops_per_sec/0" do
    test "returns a positive opcode rate" do
      assert Lenies.Stepper.world_ops_per_sec() > 0
    end
  end

  describe "exec_codeome (extra-chromosomal)" do
    test "with no plasmids exec_codeome matches the chromosome size" do
      codeome = Codeome.from_list([:nop_0, :nop_1, :nop_1])
      session = Stepper.start_session(codeome, [])
      assert session.codeome == codeome
      assert Codeome.size(session.exec_codeome) == 3
    end

    test "with :plasmids opt exec_codeome appends plasmid opcodes after the chromosome" do
      codeome = Codeome.from_list([:nop_0])
      session = Stepper.start_session(codeome, plasmids: [Plasmid.new([:turn_left, :turn_left])])

      assert session.codeome == codeome
      assert Codeome.to_list(session.exec_codeome) == [:nop_0, :turn_left, :turn_left]
      assert session.interp.plasmids == [Plasmid.new([:turn_left, :turn_left])]
    end

    test "plasmid_region_starts/1 returns the start offset of each plasmid region" do
      codeome = Codeome.from_list([:nop_0, :nop_1, :nop_1])

      assert Stepper.plasmid_region_starts(Stepper.start_session(codeome, [])) == []

      session =
        Stepper.start_session(codeome,
          plasmids: [Plasmid.new([:turn_left, :turn_left]), Plasmid.new([:add])]
        )

      # chromosome length 3 → first plasmid starts at 3, second at 3+2=5
      assert Stepper.plasmid_region_starts(session) == [3, 5]
    end
  end
end
