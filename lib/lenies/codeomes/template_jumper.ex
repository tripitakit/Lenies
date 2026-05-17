defmodule Lenies.Codeomes.TemplateJumper do
  @moduledoc """
  Test Codeome that exercises template addressing.

  Independently verifies both branches of the jump:
  - IF the jump succeeds, `slot[0]` is set to `1` (SUCCESS)
  - IF the jump fails (fall-through), `slot[0]` is set to `2` (FAILURE)

  The test asserts `slot[0] == 1`, observable only if template addressing
  actually works.

  Layout:
  ```
  pre:
    0  :push0       # stack = [0]
    1  :push0       # stack = [0, 0]
    2  :store       # slot[0] = 0; stack = []
    3  :jmp_t       # jump opcode
    4  :nop_0       # template = [:nop_0, :nop_1]; complement = [:nop_1, :nop_0]
    5  :nop_1
  fail (fall-through if no match):
    6  :push1
    7  :dup         # stack = [1, 1]
    8  :add         # stack = [2]
    9  :push0
   10  :store       # slot[0] = 2; stack = []
   11  :nop_0       # filler so backward search lands the success-branch correctly
   12  :nop_0
  success (complement of jump's template lands here):
   13  :nop_1       # complement starts at 13: [:nop_1, :nop_0]
   14  :nop_0       # after match, IP = 13 + 2 = 15
   15  :push1
   16  :push0
   17  :store       # slot[0] = 1; stack = []
  spin:
   18  :nop_0       # idle
   19  :nop_0
   20  :nop_0
  ```

  Stack semantics reminder: `:store` pops slot_idx (top), then value.
  The "push value, push slot_idx, store" sequences used here are:
  `:push0, :push0, :store` → `slot[0] = 0`
  `:push1, :push0, :store` → `slot[0] = 1`
  `:push1, :dup, :add, :push0, :store` → `slot[0] = 2`
  """

  alias Lenies.Codeome

  @opcodes [
    # pre
    # 0
    :push0,
    # 1
    :push0,
    # 2  slot[0] = 0
    :store,
    # 3  jump opcode
    :jmp_t,
    # 4  template[0]
    :nop_0,
    # 5  template[1] → template = [:nop_0, :nop_1]
    :nop_1,
    # fail path
    # 6
    :push1,
    # 7
    :dup,
    # 8
    :add,
    # 9
    :push0,
    # 10 slot[0] = 2 (proves jump fell through)
    :store,
    # 11 filler
    :nop_0,
    # 12 filler
    :nop_0,
    # success path (jump target)
    # 13 complement[0]
    :nop_1,
    # 14 complement[1] → match for [:nop_1, :nop_0] starts at 13
    :nop_0,
    # 15
    :push1,
    # 16
    :push0,
    # 17 slot[0] = 1 (proves jump succeeded)
    :store,
    # spin tail
    # 18
    :nop_0,
    # 19
    :nop_0,
    # 20
    :nop_0
  ]

  def codeome, do: Codeome.from_list(@opcodes)
end
