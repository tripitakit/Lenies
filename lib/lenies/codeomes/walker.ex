defmodule Lenies.Codeomes.Walker do
  @moduledoc """
  Codeome scritto a mano per testare il loop Lenie. Non si replica.
  Cicla all'infinito: sense_front, eat, move forward.

  ```
  loop:
    :sense_front   # → stack: [content]
    :drop          # discard sense result (eat blindly)
    :eat
    :move
    :jmp_t :nop_0  # back to start
  loop_target:
    :nop_1         # complement of [:nop_0]
  ```
  """

  alias Lenies.Codeome

  @opcodes [
    # 0: complement marker (where :jmp_t will land)
    :nop_1,
    # 1: sense front cell
    :sense_front,
    # 2: discard sense result
    :drop,
    # 3: eat current cell
    :eat,
    # 4: try to move forward
    :move,
    # 5: jump
    :jmp_t,
    # 6: template (complement = :nop_1 at position 0)
    :nop_0
  ]

  def codeome, do: Codeome.from_list(@opcodes)
end
