defmodule Lenies.Codeomes.Forager do
  @moduledoc """
  Wandering herbivore. Each forage iteration: eat, move, then a 3-way
  random branch via `pushN mod 3` — 33% no turn, 33% turn_left, 33%
  turn_right. The direction performs a random walk on {N, E, S, W},
  so the position drifts as a 2D random walk and fills space rather
  than tracing straight lines.

  ## Forage body

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
    eat
    move
    pushN; mod 3                  ; val ∈ {0, 1, 2}
    dup; jz_t NO_TURN_BR          ; pops dup; if val == 0
    push1; sub                    ; val=1 → 0; val=2 → 1
    jz_t TURN_LEFT_BR             ; pops; if was 1
    ; val was 2
    turn_right
    jmp_t FORAGE_LOOP_HEAD

  NO_TURN_BR:
    drop                          ; drop the duplicated 0
    jmp_t FORAGE_LOOP_HEAD

  TURN_LEFT_BR:
    turn_left
    jmp_t FORAGE_LOOP_HEAD
  ```

  ## Anchors

  | Label             | Anchor             | Jump template      |
  |-------------------|--------------------|--------------------|
  | LOOP_HEAD         | [n1, n1, n1, n1]   | [n0, n0, n0, n0]   |
  | COPY_LOOP_HEAD    | [n1, n0, n0, n1]   | [n0, n1, n1, n0]   |
  | ABORT_TARGET      | [n1, n1, n0, n0]   | [n0, n0, n1, n1]   |
  | FORAGE_LOOP_HEAD  | [n0, n1, n0, n1]   | [n1, n0, n1, n0]   |
  | NO_TURN_BR        | [n0, n0, n0, n1]   | [n1, n1, n1, n0]   |
  | TURN_LEFT_BR      | [n0, n1, n1, n1]   | [n1, n0, n0, n0]   |

  The deterministic post-divide `turn_left` (vs MR's random branch)
  drops `TURN_LEFT_ANCHOR` and `SKIP_TURN_ANCHOR`, freeing the
  pattern budget for the two new in-forage anchors.

  ## `pushN mod 3` bias

  `pushN` returns 0..255. 256 mod 3 = 1, so values 0 and 1 appear 86
  times in a perfect sample while value 2 appears 84 times. Relative
  bias ≈ 2.4%. Behaviorally negligible.

  ## Energy

  - Codeome length: 139 opcodes
  - Replication cost ≈ 974 energy (copy 139 × ~6.8 + setup + divide ≈ 29)
  - Per-iter forage cost ≈ 9.22 energy (average across the 3 paths)
  - Eat gain at default eat_amount=20 ≈ +10.78 per iter
  - Steady state at K=128: E_ss ≈ 2 × 128 × 10.78 − 974 ≈ +1786 (sustainable).

  ## Separators

  Three `:push0` separators prevent the template-extractor from
  reading 8 consecutive nops. Two sit between a `jmp_t` template
  (4 nops) and the following anchor (4 nops); the third sits at the
  end of the codeome to break the wrap-around from the final `jmp_t`
  template into LOOP_HEAD.
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──────────────────────
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..6: get_size; store slot[0] ────────────────────────────────
    :get_size, :push0, :store,

    # ── pos 7..9: allocate(N) ────────────────────────────────────────────
    :push0, :load, :allocate,

    # ── pos 10..14: jz_t ABORT_TARGET (template [n0,n0,n1,n1]) ──────────
    :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,

    # ── pos 15..17: init slot[1] = 0 ─────────────────────────────────────
    :push0, :push1, :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor [n1, n0, n0, n1] ───────────────
    :nop_1, :nop_0, :nop_0, :nop_1,

    # ── pos 22..29: copy body ────────────────────────────────────────────
    :push1, :load, :read_self,
    :push1, :load, :swap, :write_child, :drop,

    # ── pos 30..35: increment slot[1] ────────────────────────────────────
    :push1, :load, :push1, :add, :push1, :store,

    # ── pos 36..40: loop condition (N - (counter+1) != 0?) ──────────────
    :push0, :load, :push1, :load, :sub,

    # ── pos 41..45: jnz_t COPY_LOOP_HEAD (template [n0,n1,n1,n0]) ───────
    :jnz_t, :nop_0, :nop_1, :nop_1, :nop_0,

    # ── pos 46: divide ───────────────────────────────────────────────────
    :divide,

    # ── pos 47..50: ABORT_TARGET anchor [n1, n1, n0, n0] ─────────────────
    # Landing pad for both jz_t (allocate failed) and post-divide fall-through.
    :nop_1, :nop_1, :nop_0, :nop_0,

    # ── pos 51: deterministic post-divide turn ───────────────────────────
    :turn_left,

    # ── pos 52..65: build K=128 (push1 + 7×(dup,add)) ────────────────────
    :push1, :dup, :add, :dup, :add, :dup, :add,
    :dup, :add, :dup, :add, :dup, :add, :dup, :add,

    # ── pos 66..67: K+1 = 129 (decrement-first loop overshoots by 1) ────
    :push1, :add,

    # ── pos 68..69: store K+1 in slot[0] ─────────────────────────────────
    :push0, :store,

    # ── pos 70..73: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 74..79: decrement slot[0] ────────────────────────────────────
    :push0, :load, :push1, :sub, :push0, :store,

    # ── pos 80..81: load slot[0] for exit check ──────────────────────────
    :push0, :load,

    # ── pos 82..86: jz_t LOOP_HEAD (template [n0,n0,n0,n0]) — exit forage ─
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 87..88: forage body — eat, move ──────────────────────────────
    :eat, :move,

    # ── pos 89..95: pushN; build 3; mod (pushN mod 3) ────────────────────
    # pushN [r]; push1 [r,1]; push1 [r,1,1]; push1 [r,1,1,1]; add [r,1,2];
    # add [r,3]; mod [r mod 3].
    :pushN, :push1, :push1, :push1, :add, :add, :mod,

    # ── pos 96: dup the result ───────────────────────────────────────────
    :dup,

    # ── pos 97..101: jz_t NO_TURN_BR (template [n1,n1,n1,n0]) ───────────
    # Pops top dup. If 0 → jump to NO_TURN_BR. Else stack still has [val].
    :jz_t, :nop_1, :nop_1, :nop_1, :nop_0,

    # ── pos 102..103: val - 1 (val was 1 or 2) ───────────────────────────
    :push1, :sub,

    # ── pos 104..108: jz_t TURN_LEFT_BR (template [n1,n0,n0,n0]) ────────
    # Pops top. If 0 (val was 1) → jump. Else (val was 2) fall through.
    :jz_t, :nop_1, :nop_0, :nop_0, :nop_0,

    # ── pos 109: turn_right (val was 2) ──────────────────────────────────
    :turn_right,

    # ── pos 110..114: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ───
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 115: separator (prevents 8-consecutive-nop misread) ──────────
    :push0,

    # ── pos 116..119: NO_TURN_BR anchor [n0, n0, n0, n1] ─────────────────
    :nop_0, :nop_0, :nop_0, :nop_1,

    # ── pos 120: drop remaining val (= 0) ────────────────────────────────
    :drop,

    # ── pos 121..125: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ───
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 126: separator ───────────────────────────────────────────────
    :push0,

    # ── pos 127..130: TURN_LEFT_BR anchor [n0, n1, n1, n1] ──────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    # ── pos 131: turn_left ───────────────────────────────────────────────
    :turn_left,

    # ── pos 132..136: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ───
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 137: separator (final wrap protection) ───────────────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
