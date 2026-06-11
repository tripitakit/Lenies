defmodule Lenies.Codeomes.Reflex do
  @moduledoc """
  Rung 1 of the seed capability ladder — the simplest organism.

  A pure **sensor → motor reflex**: one loop, no memory slots, no call stack,
  no replication. The smallest Codeome that still exhibits *adaptive* behaviour.
  It is Core War's *Imp* given a sense organ, or a one-neuron Braitenberg
  vehicle. Because it never divides it is mortal — its population decays. That
  is intentional: it is the honest baseline rung and the cleanest organism to
  single-step in the stepper.

  ## Behaviour

  Each iteration reads the cell ahead (`sense_front` pushes `-1` for a Lenie,
  `0` for empty, `n > 0` for food) and reacts:

  - **food ahead** (`> 0`) → `eat`, then `move`;
  - **empty** (`== 0`) → `move` (cruise);
  - **Lenie ahead** (`== -1`) → `turn_right` (avoid the obstacle).

  ## Algorithm

  ```
  LOOP:
    sense_front            ; [v]      v ∈ {-1, 0, >0}
    dup                    ; [v, v]
    jz_t EMPTY             ; pop top; if v==0 → EMPTY, leaving [0]
    push1 ; add            ; [v+1]    lenie→0, food→≥2
    jz_t AVOID             ; pop; if 0 → lenie ahead → AVOID
    eat                    ; food ahead
    move
    jmp_t LOOP
  EMPTY:                   ; arrived with the leftover dup'd 0 on the stack
    drop
    move
    jmp_t LOOP
  AVOID:
    turn_right
    jmp_t LOOP
  ```

  The only branch that arrives with a value still on the stack is `EMPTY`
  (the un-popped `dup`), which immediately `drop`s it, so the stack is balanced
  on every path.

  ## Stack-machine technique

  A **three-valued sense used directly as a branch predicate**, discriminated by
  sign with `dup` + `jz_t` + a `+1` trick — the most fundamental control-flow
  idiom of a stack VM, achieved with zero auxiliary state.

  ## Template anchors (4-bit, Tierra-style; complement = bit-flip)

  | Label | Anchor          | Jump template     |
  |-------|-----------------|-------------------|
  | LOOP  | [n1,n1,n1,n1]   | [n0,n0,n0,n0]     |
  | EMPTY | [n0,n1,n1,n0]   | [n1,n0,n0,n1]     |
  | AVOID | [n1,n1,n0,n0]   | [n0,n0,n1,n1]     |

  The three anchors are mutually distinct, and the complement that each jump
  searches for (LOOP→`1111`, EMPTY→`0110`, AVOID→`1100`) first occurs — scanning
  forward from the jump — at the intended anchor and nowhere earlier. `:push0`
  separators sit after every jump template so the extractor never merges a
  template with the anchor that follows it (the standard separator rule).

  ## References

  - A.K. Dewdney, "Computer Recreations: In the game called Core War…",
    *Scientific American*, May 1984 (the Imp, `MOV 0,1`).
  - V. Braitenberg, *Vehicles: Experiments in Synthetic Psychology*, MIT
    Press, 1984 (reflexive sensor-motor coupling).
  - H.C. Berg, run-and-tumble bacterial chemotaxis.

  See `docs/superpowers/specs/2026-06-11-seed-codeomes-redesign-design.md` §3.
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP anchor [n1,n1,n1,n1] ──────────────────────────────
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_1,

    # ── pos 4..5: sense the cell ahead, duplicate it ─────────────────────
    :sense_front,
    :dup,

    # ── pos 6..10: jz_t EMPTY — if v==0 (empty) → cruise ─────────────────
    :jz_t,
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_1,

    # ── pos 11..12: v+1 (lenie -1 → 0; food >0 → ≥2) ─────────────────────
    :push1,
    :add,

    # ── pos 13..17: jz_t AVOID — if 0 (lenie ahead) → turn ───────────────
    :jz_t,
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_1,

    # ── pos 18..19: food ahead — eat, then advance ───────────────────────
    :eat,
    :move,

    # ── pos 20..24: jmp_t LOOP ───────────────────────────────────────────
    :jmp_t,
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,

    # ── pos 25: separator (keeps the template above off the EMPTY anchor) ─
    :push0,

    # ── pos 26..29: EMPTY anchor [n0,n1,n1,n0] ───────────────────────────
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_0,

    # ── pos 30..31: cruise — drop the leftover 0, then advance ───────────
    :drop,
    :move,

    # ── pos 32..36: jmp_t LOOP ───────────────────────────────────────────
    :jmp_t,
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,

    # ── pos 37: separator ────────────────────────────────────────────────
    :push0,

    # ── pos 38..41: AVOID anchor [n1,n1,n0,n0] ───────────────────────────
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_0,

    # ── pos 42: turn away from the neighbour ─────────────────────────────
    :turn_right,

    # ── pos 43..47: jmp_t LOOP ───────────────────────────────────────────
    :jmp_t,
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,

    # ── pos 48: separator (breaks the wrap into the LOOP anchor at pos 0) ─
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging and tests)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
