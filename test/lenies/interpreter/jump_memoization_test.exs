defmodule Lenies.Interpreter.JumpMemoizationTest do
  @moduledoc """
  The precomputed `jump_index` on a Codeome is a pure performance cache: running
  any program with the index MUST be byte-for-byte identical to running it
  without. These tests pin that invariant down across hand-built control-flow
  programs, the shipped reference codeomes, and randomly generated opcode soup.
  """
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Interpreter}
  alias Lenies.Interpreter.State

  @opcodes Lenies.Codeome.Opcodes.all()

  defp run(codeome, steps) do
    # Re-seed identically before each run so the non-deterministic `:pushN`
    # opcode produces the same sequence in both — otherwise the comparison
    # diverges on randomness, not on the cache under test.
    :rand.seed(:exsss, {101, 202, 303})
    Interpreter.run_k_instructions(State.new(energy: 1_000_000.0), codeome, steps)
  end

  defp assert_equivalent(opcodes, steps) do
    plain = Codeome.from_list(opcodes)
    indexed = Interpreter.index_jumps(plain)

    # The index must not change the opcodes themselves.
    assert Codeome.to_list(indexed) == Codeome.to_list(plain)
    assert run(plain, steps) == run(indexed, steps)
  end

  test "index_jumps sets a jump_index without touching opcodes" do
    c = Codeome.from_list([:jmp_t, :nop_0, :push0, :nop_1, :sub])
    indexed = Interpreter.index_jumps(c)

    assert is_map(indexed.jump_index)
    assert Codeome.to_list(indexed) == Codeome.to_list(c)
    # from_list always produces a fresh (un-indexed) codeome.
    assert c.jump_index == nil
  end

  test "equivalent execution on hand-built control-flow programs" do
    programs = [
      [:jmp_t, :nop_0, :push0, :push1, :nop_1, :sub],
      [:jz_t, :nop_0, :push0, :nop_1, :sub],
      [:jnz_t, :nop_0, :push1, :nop_1, :drop],
      [:call_t, :nop_0, :nop_1, :ret, :nop_1, :nop_0, :push1],
      # jump with no template (falls through)
      [:jmp_t, :push0, :push1],
      # template not found (falls through past template)
      [:jmp_t, :nop_0, :push0, :push1],
      # tight backward loop
      [:nop_1, :push1, :jmp_t, :nop_0]
    ]

    for prog <- programs, do: assert_equivalent(prog, 200)
  end

  test "equivalent execution on the shipped reference codeomes" do
    for mod <- [
          Lenies.Codeomes.Walker,
          Lenies.Codeomes.Forager,
          Lenies.Codeomes.Hunter,
          Lenies.Codeomes.Defender,
          Lenies.Codeomes.TemplateJumper,
          Lenies.Codeomes.MinimalReplicator
        ] do
      assert_equivalent(Codeome.to_list(mod.codeome()), 500)
    end
  end

  test "equivalent execution on random opcode soup" do
    for seed <- 1..50 do
      :rand.seed(:exsss, {seed, seed * 7, seed * 13})
      len = :rand.uniform(60) + 5
      prog = for _ <- 1..len, do: Enum.random(@opcodes)
      assert_equivalent(prog, 300)
    end
  end
end
