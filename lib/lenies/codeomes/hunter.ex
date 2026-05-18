defmodule Lenies.Codeomes.Hunter do
  @moduledoc """
  Reactive predator. Inline sense-and-attack: every forage iteration the
  seed checks `sense_front` and attacks if it sees a Lenie (-1 wire
  marker), otherwise it eats and moves. Every 8 forage iterations a 360°
  sweep rotates four times left, sensing in each direction; the first
  Lenie detected interrupts the sweep and triggers `attack`. If no Lenie
  is found, the four turn_lefts bring the Hunter back to its starting
  facing.

  The post-divide turn is deterministic `turn_left` instead of MR's
  random `pushN`-mod-2 pick — this frees two anchor patterns that the
  in-forage logic needs.

  ## Anchors added vs MinimalReplicator

  | Label                  | Anchor           | Jump template     |
  |------------------------|------------------|-------------------|
  | LENIE_HANDLER_ANCHOR   | [n0,n0,n0,n1]    | [n1,n1,n1,n0]     |
  | INCR_COUNTER_ANCHOR    | [n0,n1,n1,n1]    | [n1,n0,n0,n0]     |
  | DO_SWEEP_ANCHOR        | [n0,n1,n0,n0]    | [n1,n0,n1,n1]     |
  | SWEEP_FOUND_ANCHOR     | [n0,n0,n1,n0]    | [n1,n1,n0,n1]     |

  ## Forage loop structure (decrement-first, K = 128)

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
    sense_front
    push 1; add                     ; value+1: 0 iff was -1 (lenie)
    jz_t LENIE_HANDLER              ; pops the (value+1)
    eat; move; jmp_t INCR_COUNTER
  LENIE_HANDLER:
    attack
  INCR_COUNTER:                     ; both paths converge
    counter := slot[3] + 1
    if (counter mod 8) != 0:
      slot[3] := counter; jmp_t FORAGE_LOOP_HEAD
    else:                                          (DO_SWEEP)
      slot[3] := 0
      4× { turn_left; sense_front; push 1; add; jz_t SWEEP_FOUND }
      jmp_t FORAGE_LOOP_HEAD
  SWEEP_FOUND:
    attack
    jmp_t FORAGE_LOOP_HEAD
  ```
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor ───────────────────────────────────────
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..6: get_size; store slot[0] ────────────────────────────────
    :get_size, :push0, :store,

    # ── pos 7..9: allocate(N) ────────────────────────────────────────────
    :push0, :load, :allocate,

    # ── pos 10..14: jz_t ABORT_TARGET ────────────────────────────────────
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

    # ── pos 15..17: init slot[1] = 0 ────────────────────────────────────
    :push0, :push1, :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor ────────────────────────────────
    :nop_1, :nop_0, :nop_0, :nop_1,

    # ── pos 22..29: copy body ────────────────────────────────────────────
    :push1, :load, :read_self,
    :push1, :load, :swap, :write_child, :drop,

    # ── pos 30..35: increment slot[1] ────────────────────────────────────
    :push1, :load, :push1, :add, :push1, :store,

    # ── pos 36..40: loop condition ───────────────────────────────────────
    :push0, :load, :push1, :load, :sub,

    # ── pos 41..45: jnz_t COPY_LOOP_HEAD ─────────────────────────────────
    :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

    # ── pos 46: divide ───────────────────────────────────────────────────
    :divide,

    # ── pos 47..50: ABORT_TARGET anchor ──────────────────────────────────
    :nop_1, :nop_1, :nop_0, :nop_0,

    # ── pos 51: post-divide deterministic turn ──────────────────────────
    :turn_left,

    # ── pos 52..65: build K=128 (push1 + 7 doublings) ───────────────────
    :push1, :dup, :add, :dup, :add, :dup, :add,
    :dup, :add, :dup, :add, :dup, :add, :dup, :add,

    # ── pos 66..67: K+1 = 129 ────────────────────────────────────────────
    :push1, :add,

    # ── pos 68..69: store K+1 in slot[0] ─────────────────────────────────
    :push0, :store,

    # ── pos 70..76: init slot[3] := 0 ────────────────────────────────────
    # Stack trace: push0[0]; push1[0,1]; push1[0,1,1]; push1[0,1,1,1];
    # add[0,1,2]; add[0,3]; store → slot[3] := 0. (7 opcodes.)
    :push0, :push1, :push1, :push1, :add, :add, :store,

    # ── pos 77..80: FORAGE_LOOP_HEAD anchor ──────────────────────────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 81..86: decrement slot[0] ────────────────────────────────────
    :push0, :load, :push1, :sub, :push0, :store,

    # ── pos 87..88: load slot[0] for exit check ──────────────────────────
    :push0, :load,

    # ── pos 89..93: jz_t LOOP_HEAD (exit forage when counter hits 0) ─────
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 94..96: sense_front; push 1; add; (value+1 on stack) ────────
    :sense_front, :push1, :add,

    # ── pos 97..101: jz_t LENIE_HANDLER (was -1, now 0) ─────────────────
    :jz_t, :nop_1, :nop_1, :nop_1, :nop_0,

    # ── (not a Lenie) eat; move; jmp_t INCR_COUNTER ──────────────────────
    :eat, :move,
    :jmp_t, :nop_1, :nop_0, :nop_0, :nop_0,        # template for INCR_COUNTER
    # NOTE: :push0 separator prevents 8-consecutive-nop template extraction (same role as MR pos 67 and pos 120).
    :push0,

    # ── LENIE_HANDLER_ANCHOR [n0,n0,n0,n1] ──────────────────────────────
    :nop_0, :nop_0, :nop_0, :nop_1,

    # ── attack; fall through to INCR_COUNTER ─────────────────────────────
    :attack,

    # ── INCR_COUNTER_ANCHOR [n0,n1,n1,n1] ───────────────────────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    # ── increment slot[3]; check mod 8 ───────────────────────────────────
    # NOTE: plan had :push1,:push1,:push1,:add,:load — fixed to two adds to actually build slot 3.
    :push1, :push1, :push1, :add, :add, :load,      # build slot idx 3, load
    :push1, :add,                                    # counter + 1
    :dup,                                            # [counter+1, counter+1]

    # ── push 8 = push1; dup; add; dup; add; dup; add (1,2,4,8) ──────────
    :push1, :dup, :add, :dup, :add, :dup, :add,
    :mod,                                            # [counter+1, mod_result]

    # ── jz_t DO_SWEEP ───────────────────────────────────────────────────
    :jz_t, :nop_1, :nop_0, :nop_1, :nop_1,          # template for DO_SWEEP

    # ── (mod != 0) store counter+1 to slot[3]; jmp_t FORAGE_LOOP_HEAD ──
    # NOTE: plan had :push1,:push1,:push1,:add,:store — fixed to two adds to actually build slot 3.
    :push1, :push1, :push1, :add, :add, :store,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,         # template for FORAGE_LOOP_HEAD
    # NOTE: :push0 separator prevents 8-consecutive-nop template extraction (same role as MR pos 67 and pos 120).
    :push0,

    # ── DO_SWEEP_ANCHOR [n0,n1,n0,n0] ───────────────────────────────────
    :nop_0, :nop_1, :nop_0, :nop_0,

    # ── reset slot[3] := 0 ───────────────────────────────────────────────
    :drop,                                           # drop counter+1
    :push0, :push1, :push1, :push1, :add, :add, :store,

    # ── Sweep iter 1: turn_left, sense_front, push 1, add, jz_t FOUND ──
    :turn_left, :sense_front, :push1, :add,
    :jz_t, :nop_1, :nop_1, :nop_0, :nop_1,          # template for SWEEP_FOUND

    # ── Sweep iter 2 ─────────────────────────────────────────────────────
    :turn_left, :sense_front, :push1, :add,
    :jz_t, :nop_1, :nop_1, :nop_0, :nop_1,

    # ── Sweep iter 3 ─────────────────────────────────────────────────────
    :turn_left, :sense_front, :push1, :add,
    :jz_t, :nop_1, :nop_1, :nop_0, :nop_1,

    # ── Sweep iter 4 ─────────────────────────────────────────────────────
    :turn_left, :sense_front, :push1, :add,
    :jz_t, :nop_1, :nop_1, :nop_0, :nop_1,

    # ── No prey found — back to FORAGE_LOOP_HEAD ─────────────────────────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,
    # NOTE: :push0 separator prevents 8-consecutive-nop template extraction (same role as MR pos 67 and pos 120).
    :push0,

    # ── SWEEP_FOUND_ANCHOR [n0,n0,n1,n0] ────────────────────────────────
    :nop_0, :nop_0, :nop_1, :nop_0,

    :attack,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,         # template for FORAGE_LOOP_HEAD

    # ── separator (final wrap protection) ───────────────────────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
