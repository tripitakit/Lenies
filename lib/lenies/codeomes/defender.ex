defmodule Lenies.Codeomes.Defender do
  @moduledoc """
  Defensive herbivore that builds tight clusters. Replicates often (K=32),
  defends every forage iteration, and uses a deterministic post-divide
  `turn_left` instead of a random branch. Cluster shape emerges from the
  short forage runs (~32 cells before each replication) combined with the
  deterministic 90° turn after every divide — descendants spiral outward
  in a fractal pattern.

  ## Forage body

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit forage)
    defend
    eat
    move
    jmp_t FORAGE_LOOP_HEAD
  ```

  ## Anchors

  | Label             | Anchor             | Jump template      |
  |-------------------|--------------------|--------------------|
  | LOOP_HEAD         | [n1, n1, n1, n1]   | [n0, n0, n0, n0]   |
  | COPY_LOOP_HEAD    | [n1, n0, n0, n1]   | [n0, n1, n1, n0]   |
  | ABORT_TARGET      | [n1, n1, n0, n0]   | [n0, n0, n1, n1]   |
  | FORAGE_LOOP_HEAD  | [n0, n1, n0, n1]   | [n1, n0, n1, n0]   |

  Four anchors total — a strict subset of MR's six. The two MR anchors
  for the post-divide random branch (`TURN_LEFT_ANCHOR`, `SKIP_TURN_ANCHOR`)
  are dropped because this seed uses an unconditional `turn_left` after
  `divide`.

  ## Energy

  - Codeome length: 93 opcodes
  - Replication cost ≈ 526 energy (copy 93 × ~5.4 + setup + divide)
  - Per-iter forage cost ≈ 8.9 energy (defend 2.0 + eat 2.0 + move 2.0 +
    counter ~1.5 + load+jz_t+jmp_t ~1.4)
  - Eat gain at default `eat_amount: 20` ≈ +11.1 per iter
  - Steady state at K=32: E_ss = 2 × 32 × 11.1 - 526 ≈ +184 (sustainable).
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──────────────────────
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..6: get own size N, store in slot[0] ───────────────────────
    :get_size, :push0, :store,

    # ── pos 7..9: allocate child slot of size N in front cell ────────────
    :push0, :load, :allocate,

    # ── pos 10..14: jz_t ABORT_TARGET if allocate failed (template [n0,n0,n1,n1]) ──
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

    # ── pos 15..17: init copy counter slot[1] = 0 ────────────────────────
    :push0, :push1, :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor [n1, n0, n0, n1] ───────────────
    :nop_1, :nop_0, :nop_0, :nop_1,

    # ── pos 22..29: copy body — read self at slot[1], write to child ────
    :push1, :load, :read_self,
    :push1, :load, :swap, :write_child, :drop,

    # ── pos 30..35: increment slot[1] (copy counter) ─────────────────────
    :push1, :load, :push1, :add, :push1, :store,

    # ── pos 36..40: loop condition (N - (counter+1)) ─────────────────────
    :push0, :load, :push1, :load, :sub,

    # ── pos 41..45: jnz_t COPY_LOOP_HEAD (template [n0,n1,n1,n0]) ───────
    :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

    # ── pos 46: divide ───────────────────────────────────────────────────
    :divide,

    # ── pos 47..50: ABORT_TARGET anchor [n1, n1, n0, n0] ─────────────────
    :nop_1, :nop_1, :nop_0, :nop_0,

    # ── pos 51: deterministic post-divide turn ───────────────────────────
    :turn_left,

    # ── pos 52..62: build K=32 on stack (push1 + 5×(dup,add) = 32) ─────
    # push1 [1]; dup [1,1]; add [2]; dup [2,2]; add [4]; ... → 32 (11 ops)
    :push1, :dup, :add, :dup, :add, :dup, :add, :dup, :add, :dup, :add,

    # ── pos 63..64: K+1 = 33 (decrement-first loop overshoots by 1) ─────
    :push1, :add,

    # ── pos 65..66: store K+1 in slot[0] (forage counter) ────────────────
    :push0, :store,

    # ── pos 67..70: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 71..76: decrement slot[0] (slot[0] -= 1) ─────────────────────
    :push0, :load, :push1, :sub, :push0, :store,

    # ── pos 77..78: load slot[0] for exit check ──────────────────────────
    :push0, :load,

    # ── pos 79..83: jz_t LOOP_HEAD (template [n0,n0,n0,n0]) — exit forage ─
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 84..86: forage body — defend, eat, move ──────────────────────
    :defend, :eat, :move,

    # ── pos 87..91: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ─────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 92: separator — prevents template extractor from reading ────
    # 4 nops of the final template + 4 nops of LOOP_HEAD across wrap.
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
