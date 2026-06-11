defmodule Lenies.Codeomes.Architect do
  @moduledoc """
  Rung 3 of the seed capability ladder — the structured, recursive organism.

  Same replicative capability as `Ancestor`, but reorganized as a **program of
  callable subroutines** via `call_t`/`ret`. The genome reads like a `main()`
  that calls `forage()` then `replicate()`, and `forage()` in turn calls a
  nested `steer()`. This is the first — and only — seed whose **call stack** is
  ever non-empty, directly visible in the stepper.

  No current seed uses `call_t`/`ret` at all, so the call stack is the
  distinguishing, demonstrably-novel idea of this rung.

  ## Structure

  ```
  MAIN:
    call_t FORAGE              ; gather energy, returns here
    call_t REPLICATE           ; copy + divide, returns here
    jmp_t MAIN

  FORAGE:                      ; bounded forage with steering
    <build 32> ; push0 ; store        ; slot0 = forage budget
    FLOOP:
      push0 ; load ; jz_t FEND        ; budget spent → return
      call_t STEER                     ; NESTED call (depth 2)
      eat ; move
      push0 ; load ; push1 ; sub ; push0 ; store   ; budget--
      jmp_t FLOOP
    FEND:
      ret

  STEER:                       ; turn away from a neighbour only
    sense_front ; push1 ; add         ; lenie(-1) → 0
    jz_t STURN                        ; neighbour ahead → turn
    ret
    STURN:
      turn_right ; ret

  REPLICATE:                   ; allocate + copy loop + divide, then return
    get_size ; push0 ; store          ; slot0 = N
    push0 ; load ; allocate ; jz_t RDONE   ; alloc failed → return
    push0 ; load ; push1 ; sub ; push0 ; store   ; slot0 = N-1
    RCOPY:
      push0 ; load ; dup ; read_self ; write_child ; drop
      push0 ; load ; jz_t RDIV         ; copied index 0 → divide
      push0 ; load ; push1 ; sub ; push0 ; store
      jmp_t RCOPY
    RDIV:
      divide ; turn_right
    RDONE:
      ret
  ```

  Call depth reaches 2 (`MAIN → FORAGE → STEER`); `STEER` has two return sites
  (the fall-through `ret` and `STURN`'s `ret`) sharing one frame.

  ## Stack-machine technique

  The **call stack** (`push_call`/`pop_call`) with **nested calls** and a
  two-exit subroutine — structured control flow rather than a flat goto loop.

  ## Template anchors (5-bit; complement = bit-flip)

  Ten labels need ten anchors. Each anchor is chosen from a **distinct
  5-bit complement-pair**, so the ten anchors (all `1xxxx`) and their ten
  templates (the integers `0..9` as 5-bit `0xxxx`) are twenty mutually-distinct
  patterns. Every search target then occurs exactly once in the ring, so each
  jump/call resolves to its intended anchor independent of scan order.

  | Label     | Anchor  | Template |
  |-----------|---------|----------|
  | MAIN      | 11111   | 00000    |
  | FORAGE    | 11110   | 00001    |
  | FLOOP     | 11101   | 00010    |
  | FEND      | 11100   | 00011    |
  | STEER     | 11011   | 00100    |
  | STURN     | 11010   | 00101    |
  | REPLICATE | 11001   | 00110    |
  | RCOPY     | 11000   | 00111    |
  | RDIV      | 10111   | 01000    |
  | RDONE     | 10110   | 01001    |

  `1` = `:nop_1`, `0` = `:nop_0`. `:push0`/`ret` separators keep every nop run
  exactly five long.

  ## References

  - E.W. Dijkstra, "Go To Statement Considered Harmful," *CACM*, 1968 — the
    case for structured (subroutine) control flow.
  - Modularity of biological gene-regulatory networks (the subroutine analogy).

  See `docs/superpowers/specs/2026-06-11-seed-codeomes-redesign-design.md` §3.
  """

  alias Lenies.Codeome

  @opcodes [
    # ═══ MAIN ════════════════════════════════════════════════════════════
    # pos 0..4: MAIN anchor 11111
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_1,
    # pos 5: call FORAGE
    :call_t,
    # pos 6..10: template_FORAGE 00001
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_1,
    # pos 11: call REPLICATE
    :call_t,
    # pos 12..16: template_REPLICATE 00110
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_0,
    # pos 17: loop
    :jmp_t,
    # pos 18..22: template_MAIN 00000
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,
    # pos 23: separator
    :push0,

    # ═══ FORAGE ══════════════════════════════════════════════════════════
    # pos 24..28: FORAGE anchor 11110
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_0,
    # pos 29..39: build 32 (push1 + 5×(dup,add))
    :push1,
    :dup,
    :add,
    :dup,
    :add,
    :dup,
    :add,
    :dup,
    :add,
    :dup,
    :add,
    # pos 40..41: slot0 = 32
    :push0,
    :store,
    # pos 42..46: FLOOP anchor 11101
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_1,
    # pos 47..48: load budget
    :push0,
    :load,
    # pos 49: exit if 0
    :jz_t,
    # pos 50..54: template_FEND 00011
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_1,
    # pos 55: nested call STEER
    :call_t,
    # pos 56..60: template_STEER 00100
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_0,
    :nop_0,
    # pos 61..62: forage
    :eat,
    :move,
    # pos 63..68: budget--
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,
    # pos 69: loop
    :jmp_t,
    # pos 70..74: template_FLOOP 00010
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_0,
    # pos 75: separator
    :push0,
    # pos 76..80: FEND anchor 11100
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_0,
    # pos 81: return to MAIN
    :ret,

    # ═══ STEER ═══════════════════════════════════════════════════════════
    # pos 82..86: STEER anchor 11011
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_1,
    :nop_1,
    # pos 87..89: v+1 (lenie -1 → 0)
    :sense_front,
    :push1,
    :add,
    # pos 90: turn if neighbour
    :jz_t,
    # pos 91..95: template_STURN 00101
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_0,
    :nop_1,
    # pos 96: no neighbour → return
    :ret,
    # pos 97..101: STURN anchor 11010
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_1,
    :nop_0,
    # pos 102..103: turn, then return
    :turn_right,
    :ret,

    # ═══ REPLICATE ═══════════════════════════════════════════════════════
    # pos 104..108: REPLICATE anchor 11001
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_1,
    # pos 109..111: slot0 = N
    :get_size,
    :push0,
    :store,
    # pos 112..114: allocate child of size N
    :push0,
    :load,
    :allocate,
    # pos 115: alloc failed → return
    :jz_t,
    # pos 116..120: template_RDONE 01001
    :nop_0,
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_1,
    # pos 121..126: slot0 = N-1
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,
    # pos 127..131: RCOPY anchor 11000
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_0,
    # pos 132..137: copy own[i] → child[i]
    :push0,
    :load,
    :dup,
    :read_self,
    :write_child,
    :drop,
    # pos 138..139: reload i
    :push0,
    :load,
    # pos 140: i==0 → divide
    :jz_t,
    # pos 141..145: template_RDIV 01000
    :nop_0,
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_0,
    # pos 146..151: i--
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,
    # pos 152: loop
    :jmp_t,
    # pos 153..157: template_RCOPY 00111
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_1,
    # pos 158: separator
    :push0,
    # pos 159..163: RDIV anchor 10111
    :nop_1,
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_1,
    # pos 164..165: bear child, step off
    :divide,
    :turn_right,
    # pos 166..170: RDONE anchor 10110
    :nop_1,
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_0,
    # pos 171: return to MAIN
    :ret,
    # pos 172: separator (wrap to MAIN at pos 0)
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging and tests)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
