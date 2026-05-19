defmodule Lenies.Codeome.Costs do
  @moduledoc """
  Energy costs for opcodes. See spec §4.3.

  `cost/2` accepts a context-dependent second parameter:
  - For jump opcodes (`:jmp_t`, etc.) it is `template_len`; cost is
    `0.2 + 0.05 * template_len`.
  - For `:make_plasmid` it is the `length` argument popped from the
    stack; cost is `2.0 + 0.05 * length`.
  - For `:conjugate` it is the donor's `plasmid_size`; cost is
    `4.0 + 0.05 * plasmid_size`.
  - For all other opcodes the parameter is ignored.
  """

  @doc "Energy cost for a single execution of the opcode."
  @spec cost(atom(), non_neg_integer()) :: float()
  def cost(opcode, template_len \\ 0)

  # Stack/template (cheap)
  def cost(op, _) when op in [:nop_0, :nop_1, :push0, :push1, :pushN, :dup, :drop, :swap], do: 0.1

  # Arithmetic
  def cost(op, _) when op in [:add, :sub, :mul, :mod], do: 0.2

  # Template-based jumps: 0.2 + 0.05 * template_len
  def cost(op, template_len) when op in [:jmp_t, :jz_t, :jnz_t, :call_t, :ret] do
    Float.round(0.2 + 0.05 * template_len, 10)
  end

  # Sense + turn + memory
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

  # World actions: movement/eating
  def cost(op, _) when op in [:move, :eat], do: 2.0

  # Predation
  def cost(:attack, _), do: 5.0
  def cost(:defend, _), do: 2.0

  # Replication
  def cost(:allocate, size_arg), do: 5.0 + 0.05 * size_arg
  def cost(:write_child, _), do: 1.0
  def cost(:divide, _), do: 10.0

  # Plasmid creation: 2.0 base + 0.05 per opcode copied.
  # The `template_len` parameter is repurposed by the interpreter to carry
  # the actual length argument (top of stack at dispatch time).
  def cost(:make_plasmid, length) when is_integer(length) and length > 0 do
    Float.round(2.0 + 0.05 * length, 10)
  end

  def cost(:make_plasmid, _), do: 2.0

  # Conjugation: 4.0 base + 0.05 per opcode transferred. Same parameter
  # repurposing.
  def cost(:conjugate, plasmid_size) when is_integer(plasmid_size) and plasmid_size > 0 do
    Float.round(4.0 + 0.05 * plasmid_size, 10)
  end

  def cost(:conjugate, _), do: 4.0

  # Unknown opcode → treated as :nop_0
  def cost(_, _), do: 0.1
end
