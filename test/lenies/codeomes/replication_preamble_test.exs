defmodule Lenies.Codeomes.ReplicationPreambleTest do
  use ExUnit.Case, async: true

  alias Lenies.Codeomes.{Defender, Forager, Hunter, MinimalReplicator}

  @preamble_length 52

  test "replication_preamble/0 has the expected length" do
    assert length(MinimalReplicator.replication_preamble()) == @preamble_length
  end

  test "Defender's first #{@preamble_length} opcodes equal replication_preamble/0" do
    preamble = MinimalReplicator.replication_preamble()
    assert Enum.take(Defender.opcodes(), @preamble_length) == preamble
  end

  test "Forager's first #{@preamble_length} opcodes equal replication_preamble/0" do
    preamble = MinimalReplicator.replication_preamble()
    assert Enum.take(Forager.opcodes(), @preamble_length) == preamble
  end

  test "Hunter's first #{@preamble_length} opcodes equal replication_preamble/0" do
    preamble = MinimalReplicator.replication_preamble()
    assert Enum.take(Hunter.opcodes(), @preamble_length) == preamble
  end

  test "Defender total opcode count is unchanged (93)" do
    assert length(Defender.opcodes()) == 93
  end

  test "Forager total opcode count is unchanged (139)" do
    assert length(Forager.opcodes()) == 139
  end

  test "Hunter total opcode count is unchanged (164)" do
    assert length(Hunter.opcodes()) == 164
  end
end
