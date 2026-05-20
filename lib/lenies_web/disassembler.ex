defmodule LeniesWeb.Disassembler do
  @moduledoc """
  Formats a Codeome for HTML display: position/opcode listing with the current
  IP optionally highlighted, plus per-opcode category classes for syntax
  highlighting in CSS.

  Vedi spec §7.2 (Codeome disassemblato).
  """

  alias Lenies.Codeome

  @type line :: %{
          index: non_neg_integer(),
          opcode: atom(),
          is_current: boolean()
        }

  @doc """
  Convert a Codeome into a list of line records, marking the current IP line.

  `current_ip` may be `nil` (no highlight). Out-of-range IP also produces no highlight.
  """
  @spec disassemble(Codeome.t(), non_neg_integer() | nil) :: [line()]
  def disassemble(%Codeome{} = c, current_ip) do
    opcodes = Codeome.to_list(c)

    opcodes
    |> Enum.with_index()
    |> Enum.map(fn {op, idx} ->
      %{index: idx, opcode: op, is_current: idx == current_ip}
    end)
  end

  @doc "Categorize an opcode for syntax highlighting."
  @spec opcode_class(atom()) :: atom()
  def opcode_class(op) when op in [:nop_0, :nop_1], do: :template
  def opcode_class(op) when op in [:push0, :push1, :pushN, :dup, :drop, :swap], do: :stack
  def opcode_class(op) when op in [:add, :sub, :mul, :mod], do: :arith
  def opcode_class(op) when op in [:jmp_t, :jz_t, :jnz_t, :call_t, :ret], do: :control

  def opcode_class(op)
      when op in [:sense_front, :sense_self, :sense_energy, :sense_age, :sense_size],
      do: :sense

  def opcode_class(op) when op in [:move, :turn_left, :turn_right, :eat], do: :action
  def opcode_class(op) when op in [:attack, :defend], do: :predation
  def opcode_class(op) when op in [:get_ip, :get_size, :read_self], do: :self_inspect
  def opcode_class(op) when op in [:allocate, :write_child, :divide], do: :replication
  def opcode_class(op) when op in [:store, :load], do: :memory
  def opcode_class(op) when op in [:make_plasmid, :conjugate], do: :hgt
  def opcode_class(_), do: :unknown
end
