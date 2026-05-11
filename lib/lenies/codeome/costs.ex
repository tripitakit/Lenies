defmodule Lenies.Codeome.Costs do
  @moduledoc """
  Costi energetici degli opcode. Vedi spec §4.3.

  `cost/2` accetta `template_len` per gli opcode di salto (`:jmp_t`, ecc.)
  che pagano `0.2 + 0.05 * template_len`. Per gli altri opcode il parametro
  è ignorato.
  """

  @doc "Costo energetico per un'esecuzione dell'opcode."
  @spec cost(atom(), non_neg_integer()) :: float()
  def cost(opcode, template_len \\ 0)

  # Stack/template (cheap)
  def cost(op, _) when op in [:nop_0, :nop_1, :push0, :push1, :pushN, :dup, :drop, :swap], do: 0.1

  # Aritmetica
  def cost(op, _) when op in [:add, :sub, :mul, :mod], do: 0.2

  # Salti template-based: 0.2 + 0.05 * template_len
  def cost(op, template_len) when op in [:jmp_t, :jz_t, :jnz_t, :call_t, :ret] do
    Float.round(0.2 + 0.05 * template_len, 10)
  end

  # Sense + turn + memoria
  def cost(op, _)
      when op in [
             :sense_front,
             :sense_self,
             :sense_energy,
             :sense_age,
             :sense_size,
             :turn_left,
             :turn_right,
             :store,
             :load
           ],
      do: 0.5

  # Self-inspection
  def cost(op, _) when op in [:get_ip, :get_size, :read_self], do: 0.3

  # Azione mondo: movimento/mangiare
  def cost(op, _) when op in [:move, :eat], do: 2.0

  # Opcode sconosciuto → trattato come :nop_0
  def cost(_, _), do: 0.1
end
