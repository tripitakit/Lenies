defmodule Lenies.Codeomes.Hunter do
  @moduledoc """
  Predator with a diagonal staircase advance and lock-on attack.

  Each forage iteration:
  - `sense_front`. If -1 (Lenie ahead), jump to LENIE_HANDLER → attack
    once, do NOT move, do NOT turn. Next iteration faces the same cell;
    if prey is still there, attack again. This "lock-on" amplifies kill
    probability without explicit pursuit logic.
  - Otherwise, `eat` + `move`, then alternate `turn_left`/`turn_right`
    via slot[3] parity. The alternation produces a deterministic
    diagonal staircase advance (face east → step east → turn south →
    step south → turn east → step east → …) covering both axes.

  The diagonal advance is the visual signature that distinguishes
  Hunter from MR/Carnivore (cardinal-direction straight runs) and from
  Forager (random walk).

  ## Forage body

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
    sense_front; push1; add        ; value+1: 0 iff was -1 (lenie)
    jz_t LENIE_HANDLER             ; pops; if was -1
    eat; move
    ; alternate L/R via slot[3] parity
    load slot[3]; push1; add        ; counter+1
    dup
    push 2; mod                    ; (counter+1) mod 2
    jz_t TURN_LEFT_BR              ; pops; if 0
    turn_right
    store slot[3] := counter+1
    jmp_t FORAGE_LOOP_HEAD

  LENIE_HANDLER:
    attack
    jmp_t FORAGE_LOOP_HEAD         ; no move/turn — lock on

  TURN_LEFT_BR:
    turn_left
    store slot[3] := counter+1
    jmp_t FORAGE_LOOP_HEAD
  ```

  ## Anchors

  | Label             | Anchor             | Jump template      |
  |-------------------|--------------------|--------------------|
  | LOOP_HEAD         | [n1, n1, n1, n1]   | [n0, n0, n0, n0]   |
  | COPY_LOOP_HEAD    | [n1, n0, n0, n1]   | [n0, n1, n1, n0]   |
  | ABORT_TARGET      | [n1, n1, n0, n0]   | [n0, n0, n1, n1]   |
  | FORAGE_LOOP_HEAD  | [n0, n1, n0, n1]   | [n1, n0, n1, n0]   |
  | LENIE_HANDLER     | [n0, n0, n0, n1]   | [n1, n1, n1, n0]   |
  | TURN_LEFT_BR      | [n0, n1, n1, n1]   | [n1, n0, n0, n0]   |

  ## K=96 build

  K=96 = 32 + 64. Build stack-style:
  - Phase 1 (11 ops): push1 + 5×(dup, add) → 32 on stack
  - Phase 2 (4 ops): dup [32,32]; dup [32,32,32]; add → [32,64];
    add → [96]

  Same total opcode count as K=128 (15 ops) — no efficiency cost
  vs matching the spec's K=96.

  ## Energy

  - Codeome length: ~164 opcodes
  - Replication cost ≈ 164 × 6.8 + 29 ≈ 1144 energy
  - Per-iter normal-path cost ≈ 12.4 energy (sense+test 1.2 + eat+move 4.0 +
    alternation overhead ~5.2 + counter/jmp ~2.0)
  - Eat gain at default eat_amount=20 ≈ +7.6 per iter
  - Steady state at K=96: E_ss ≈ 2 × 96 × 7.6 − 1144 ≈ +315 (sustainable).
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

    # ── pos 52..66: build K=96 = 32 + 64 ────────────────────────────────
    # Phase 1 (pos 52..62, 11 ops): push1 + 5×(dup, add) → stack=[32]
    # Phase 2 (pos 63..66, 4 ops): dup→[32,32]; dup→[32,32,32];
    # add→[32,64]; add→[96]
    :push1, :dup, :add, :dup, :add, :dup, :add, :dup, :add, :dup, :add,
    :dup, :dup, :add, :add,

    # ── pos 67..68: K+1 = 97 ─────────────────────────────────────────────
    :push1, :add,

    # ── pos 69..70: store K+1 in slot[0] ─────────────────────────────────
    :push0, :store,

    # ── pos 71..77: init slot[3] := 0 ────────────────────────────────────
    # push0 [0]; push1+push1+push1 [0,1,1,1]; add [0,1,2]; add [0,3];
    # store → slot[3] := 0. (7 ops, two adds to build slot idx 3.)
    :push0, :push1, :push1, :push1, :add, :add, :store,

    # ── pos 78..81: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 82..87: decrement slot[0] ────────────────────────────────────
    :push0, :load, :push1, :sub, :push0, :store,

    # ── pos 88..89: load slot[0] for exit check ──────────────────────────
    :push0, :load,

    # ── pos 90..94: jz_t LOOP_HEAD (template [n0,n0,n0,n0]) — exit forage ─
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── pos 95..97: sense_front; push1; add — value+1 ────────────────────
    :sense_front, :push1, :add,

    # ── pos 98..102: jz_t LENIE_HANDLER (template [n1,n1,n1,n0]) ────────
    # Pops the value+1. If was -1 (now 0) → jump.
    :jz_t, :nop_1, :nop_1, :nop_1, :nop_0,

    # ── pos 103..104: not prey — eat, move ───────────────────────────────
    :eat, :move,

    # ── pos 105..110: build slot idx 3 and load slot[3] ──────────────────
    # push1 [1]; push1 [1,1]; push1 [1,1,1]; add [1,2]; add [3]; load [slot[3]]
    :push1, :push1, :push1, :add, :add, :load,

    # ── pos 111..112: counter + 1 ────────────────────────────────────────
    :push1, :add,

    # ── pos 113: dup (value needed for parity check AND for storing back) ─
    :dup,

    # ── pos 114..116: build 2 on stack ───────────────────────────────────
    # push1 [c+1, c+1, 1]; push1 [c+1, c+1, 1, 1]; add [c+1, c+1, 2]
    :push1, :push1, :add,

    # ── pos 117: mod — (counter+1) mod 2 ─────────────────────────────────
    :mod,

    # ── pos 118..122: jz_t TURN_LEFT_BR (template [n1,n0,n0,n0]) ────────
    # Pops the mod result. If 0 → jump to TURN_LEFT_BR.
    :jz_t, :nop_1, :nop_0, :nop_0, :nop_0,

    # ── pos 123: turn_right (mod was 1) ──────────────────────────────────
    :turn_right,

    # ── pos 124..129: store counter+1 → slot[3] ──────────────────────────
    # Stack here has [counter+1]. Build slot idx 3 and store.
    :push1, :push1, :push1, :add, :add, :store,

    # ── pos 130..134: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ───
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 135: separator (prevents 8-nop misread between this jmp_t
    # template and LENIE_HANDLER anchor) ─────────────────────────────────
    :push0,

    # ── pos 136..139: LENIE_HANDLER anchor [n0, n0, n0, n1] ─────────────
    :nop_0, :nop_0, :nop_0, :nop_1,

    # ── pos 140: attack (no move, no turn — lock on) ─────────────────────
    :attack,

    # ── pos 141..145: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 146: separator (prevents 8-nop misread between this jmp_t
    # template and TURN_LEFT_BR anchor) ──────────────────────────────────
    :push0,

    # ── pos 147..150: TURN_LEFT_BR anchor [n0, n1, n1, n1] ──────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    # ── pos 151: turn_left ───────────────────────────────────────────────
    :turn_left,

    # ── pos 152..157: store counter+1 → slot[3] ──────────────────────────
    :push1, :push1, :push1, :add, :add, :store,

    # ── pos 158..162: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 163: separator (final wrap protection) ───────────────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
