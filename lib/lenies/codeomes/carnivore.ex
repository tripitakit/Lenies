defmodule Lenies.Codeomes.Carnivore do
  @moduledoc """
  Variante predatoria del minimal_replicator. La fase di foraggio inserisce :attack
  prima di :eat. Stessa procedura di replicazione (4-bit template anchors).

  Se davanti c'è un Lenie, :attack trasferisce energia direttamente. Se la cella
  davanti è vuota o ha solo cibo, :attack ritorna :no_target (no-op) ma costa
  comunque 5 energia.
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
