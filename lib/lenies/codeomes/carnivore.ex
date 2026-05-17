defmodule Lenies.Codeomes.Carnivore do
  @moduledoc """
  Predatory variant of the minimal_replicator. The foraging phase inserts :attack
  before :eat. Same replication procedure (4-bit template anchors).

  If a Lenie is in front, :attack transfers energy directly. If the cell ahead
  is empty or contains only food, :attack returns :no_target (no-op) but still
  costs 5 energy.
  """

  alias Lenies.Codeome

  def codeome do
    base_opcodes = Lenies.Codeomes.MinimalReplicator.opcodes()
    patched = inject_attack_before_eat(base_opcodes)
    Codeome.from_list(patched)
  end

  defp inject_attack_before_eat(opcodes) do
    inject_attack(opcodes, [])
  end

  defp inject_attack([], acc), do: Enum.reverse(acc)

  defp inject_attack([:eat | rest], acc) do
    # Found the first :eat — inject :attack before it and return the rest unchanged
    Enum.reverse(acc) ++ [:attack, :eat | rest]
  end

  defp inject_attack([op | rest], acc) do
    inject_attack(rest, [op | acc])
  end
end
