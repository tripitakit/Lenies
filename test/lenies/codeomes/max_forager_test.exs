defmodule Lenies.Codeomes.MaxForagerTest do
  use ExUnit.Case, async: false

  alias Lenies.{Interpreter, Stepper}
  alias Lenies.Codeomes.MaxForager

  @moduletag timeout: 60_000

  describe "structure (pure)" do
    test "validates and is a reasonable length" do
      ops = MaxForager.opcodes()
      assert {:ok, %{len: len, non_nops: non_nops}} = LeniesWeb.CodeomeBuffer.validate(ops)
      assert len == length(ops)
      assert non_nops >= 10
    end

    test "every template jump resolves to an intended anchor (none :not_found)" do
      index = Interpreter.index_jumps(MaxForager.codeome()).jump_index

      # jz_t/jmp_t/jgt_t across replication + forage loop + argmax
      assert map_size(index) == 14

      for {_ip, {tlen, result}} <- index do
        assert tlen == 5, "MaxForager uses 5-bit templates"
        assert match?({:ok, _}, result), "every jump must resolve"
      end
    end

    test "uses the replication machinery, the scan, and the sign-compare opcode" do
      ops = MaxForager.opcodes()

      for required <- [:get_size, :allocate, :read_self, :write_child, :divide, :sense_front, :jgt_t] do
        assert required in ops, "MaxForager must use #{required}"
      end
    end
  end

  describe "behaviour (stepper mini-world)" do
    setup do
      prev = Application.get_env(:lenies, :eat_amount, 50)
      Application.put_env(:lenies, :eat_amount, 50)
      on_exit(fn -> Application.put_env(:lenies, :eat_amount, prev) end)
      :ok
    end

    test "forages and replicates: produces a child while staying alive" do
      session =
        Stepper.start_session(MaxForager.codeome(),
          energy: 50_000.0,
          pos: {8, 8},
          dir: :n,
          resource_seed: 7
        )

      final =
        Enum.reduce(1..8_000, session, fn _, s ->
          {:ok, s2} = Stepper.step(s)
          s2
        end)

      children = map_size(final.world.lenies) - 1

      assert final.status != :halted, "should not starve from the 50k buffer"
      assert children >= 1, "should divide at least once (got #{children} children)"
      assert final.interp.energy > 0
    end
  end
end
