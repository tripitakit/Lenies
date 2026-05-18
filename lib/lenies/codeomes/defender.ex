defmodule Lenies.Codeomes.Defender do
  @moduledoc """
  Pacifist herbivore with a pseudo-random walk. Inherits MinimalReplicator's
  replication skeleton; the forage loop body inserts a counter that fires
  a random `turn_left` or `turn_right` every 5 forage iterations.

  Visible behaviour: short straight runs (~5 cells) interrupted by 90°
  random turns, making the Lenie hard to track for a directional predator.
  K = 64 (half of MR's 128) keeps the per-cycle energy balance comparable
  to MR despite the extra ~12 opcodes the counter machinery adds per iter.

  ## Anchors added vs MinimalReplicator

  | Label             | Anchor           | Jump template     |
  |-------------------|------------------|-------------------|
  | DO_TURN_ANCHOR    | [n0,n0,n0,n1]    | [n1,n1,n1,n0]     |
  | TURN_LEFT_BR_ANCHOR | [n0,n1,n1,n1]  | [n1,n0,n0,n0]     |

  ## Forage loop structure (decrement-first)

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
    sense_front; drop; eat; move
    counter := slot[3] + 1
    if (counter mod 5) != 0:
      slot[3] := counter; jmp_t FORAGE_LOOP_HEAD
    else:                                        (DO_TURN_ANCHOR)
      slot[3] := 0
      if (pushN mod 2) == 0:                     (jz_t TURN_LEFT_BR_ANCHOR)
        turn_right
      else:                                      (TURN_LEFT_BR_ANCHOR)
        turn_left
      jmp_t FORAGE_LOOP_HEAD
  ```

  Slot[0] is reused for the forage countdown after holding `N` during the
  copy phase, exactly as in MinimalReplicator. Slot[3] is the new
  step-counter; the slot is otherwise untouched.
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──────────────────────
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..6: get own size N, store in slot[0] ───────────────────────
    :get_size, :push0, :store,

    # ── pos 7..9: allocate child slot of size N in front cell ────────────
    :push0, :load, :allocate,

    # ── pos 10..14: jz_t → ABORT_TARGET if allocate failed ───────────────
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

    # ── pos 15..17: init copy counter slot[1] = 0 ────────────────────────
    :push0, :push1, :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor [n1, n0, n0, n1] ───────────────
    :nop_1, :nop_0, :nop_0, :nop_1,

    # ── pos 22..29: copy body (read self, write child) ───────────────────
    :push1, :load, :read_self,
    :push1, :load, :swap, :write_child, :drop,

    # ── pos 30..35: increment counter ────────────────────────────────────
    :push1, :load, :push1, :add, :push1, :store,

    # ── pos 36..40: loop condition (N - (counter+1) != 0?) ───────────────
    :push0, :load, :push1, :load, :sub,

    # ── pos 41..45: jnz_t back to COPY_LOOP_HEAD ─────────────────────────
    :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

    # ── pos 46: divide ───────────────────────────────────────────────────
    :divide,

    # ── pos 47..50: ABORT_TARGET anchor [n1, n1, n0, n0] ─────────────────
    :nop_1, :nop_1, :nop_0, :nop_0,

    # ── pos 51..55: r := pushN; (r mod 2) on stack ───────────────────────
    :pushN, :push1, :push1, :add, :mod,

    # ── pos 56..60: jz_t → TURN_LEFT_ANCHOR (post-divide random turn) ────
    :jz_t, :nop_1, :nop_0, :nop_1, :nop_1,

    # ── pos 61: turn_right (r mod 2 == 1) ────────────────────────────────
    :turn_right,

    # ── pos 62..66: jmp_t → SKIP_TURN_ANCHOR ─────────────────────────────
    :jmp_t, :nop_1, :nop_1, :nop_0, :nop_1,

    # ── pos 67: separator (dead code) ────────────────────────────────────
    :push0,

    # ── pos 68..71: TURN_LEFT_ANCHOR [n0, n1, n0, n0] ────────────────────
    :nop_0, :nop_1, :nop_0, :nop_0,

    # ── pos 72: turn_left ────────────────────────────────────────────────
    :turn_left,

    # ── pos 73..76: SKIP_TURN_ANCHOR [n0, n0, n1, n0] ────────────────────
    :nop_0, :nop_0, :nop_1, :nop_0,

    # ── pos 77..89: build K=64 on stack (push1 + 6 doublings) ────────────
    :push1, :dup, :add, :dup, :add, :dup, :add, :dup, :add, :dup, :add, :dup, :add,

    # ── pos 90..91: K+1 = 65 (decrement-first loop overshoots by 1) ──────
    :push1, :add,

    # ── pos 92..93: store K+1 in slot[0] ─────────────────────────────────
    :push0, :store,

    # ── init slot[3] := 0 (step counter for random turn) ────────────────
    # Stack trace: push0 [0]; push1 [0,1]; push1 [0,1,1]; push1 [0,1,1,1];
    # add [0,1,2]; add [0,3]; store → slot[3] := 0. (7 opcodes.)
    :push0, :push1, :push1, :push1, :add, :add, :store,

    # ── pos 101..104: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ───────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 105..110: decrement slot[0]; load and test ──────────────────
    # slot[0] -= 1; then push slot[0] onto stack
    :push0, :load, :push1, :sub, :push0, :store,
    :push0, :load,

    # ── pos 113..117: jz_t LOOP_HEAD (exit forage when counter is 0) ────
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 118..121: forage body — sense, drop, eat, move ──────────────
    :sense_front, :drop, :eat, :move,

    # ── pos 122..128: increment slot[3] counter ─────────────────────────
    # load slot[3]; push 1; add; dup; push 5; mod
    # NOTE: plan had :push1,:push1,:push1,:add,:load (builds 2, not 3).
    # Correct: push1+push1+push1+add+add=3 (two adds, matching the init pattern).
    :push1, :push1, :push1, :add, :add, :load,   # build slot idx 3 then load
    :push1, :add,                                  # counter + 1
    :dup,                                          # [counter+1, counter+1]
    # push 5 = push1; dup; add; dup; add; push1; add = 1, 2, 4, 5 (5 ops)
    :push1, :dup, :add, :dup, :add, :push1, :add,
    :mod,                                          # [counter+1, (counter+1) mod 5]

    # ── jz_t DO_TURN_ANCHOR — if (counter+1) mod 5 == 0, jump to turn ───
    :jz_t, :nop_1, :nop_1, :nop_1, :nop_0,

    # ── (mod != 0) store counter+1 → slot[3]; jmp_t FORAGE_LOOP_HEAD ───
    # stack here is [counter+1]
    # NOTE: plan had :push1,:push1,:push1,:add,:store (stores into slot 2).
    # Correct: push1+push1+push1+add+add=3 (two adds, matching the init pattern).
    :push1, :push1, :push1, :add, :add, :store,  # build slot idx 3, store
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,      # template for FORAGE_LOOP_HEAD
    # ── separator: prevents template extractor reading into DO_TURN_ANCHOR ──
    :push0,

    # ── DO_TURN_ANCHOR [n0,n0,n0,n1] ────────────────────────────────────
    :nop_0, :nop_0, :nop_0, :nop_1,

    # ── stack on entry: [counter+1]. Reset slot[3] := 0. ─────────────────
    :drop,                                          # drop counter+1, []
    :push0, :push1, :push1, :push1, :add, :add, :store,   # slot[3]=0

    # ── Random direction: pushN mod 2 → jz_t TURN_LEFT_BR ───────────────
    :pushN, :push1, :push1, :add, :mod,

    :jz_t, :nop_1, :nop_0, :nop_0, :nop_0,        # template for TURN_LEFT_BR

    # ── turn_right path ────────────────────────────────────────────────
    :turn_right,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,       # template for FORAGE_LOOP_HEAD
    # ── separator: prevents template extractor reading into TURN_LEFT_BR_ANCHOR
    :push0,

    # ── TURN_LEFT_BR_ANCHOR [n0,n1,n1,n1] ───────────────────────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    :turn_left,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,       # template for FORAGE_LOOP_HEAD

    # ── separator (final wrap protection) ───────────────────────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
