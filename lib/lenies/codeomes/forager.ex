defmodule Lenies.Codeomes.Forager do
  @moduledoc """
  Adaptive herbivore that abandons resource-empty patches. Each forage
  iteration the seed checks `sense_front`; if the cell directly in front
  is empty (the wire format pushes 0), a slot[3] counter increments. On
  the 5th consecutive empty sighting, the seed fires a random
  turn_left or turn_right and resets the counter. Non-empty sightings
  reset the counter immediately.

  ## VM-side relaxation

  The spec specified "low energy = sense_front < 20" but the Lenies VM
  has no less-than opcode — emulating `< 20` would cost ~16 energy per
  forage iteration. The implementation uses **T = 0** (count only
  truly empty cells via `jz_t` on the sense_front result). Behaviour
  is qualitatively the same — the seed walks away from exhausted
  patches — just at the absolute exhaustion point rather than a soft
  20-unit threshold.

  Like Hunter, Forager replaces MR's post-divide random turn with a
  deterministic `turn_left` so the three new in-forage anchors fit in
  the 4-bit template namespace.

  ## Anchors added vs MinimalReplicator

  | Label               | Anchor           | Jump template     |
  |---------------------|------------------|-------------------|
  | EMPTY_ANCHOR        | [n0,n0,n0,n1]    | [n1,n1,n1,n0]     |
  | DO_TURN_ANCHOR      | [n0,n1,n1,n1]    | [n1,n0,n0,n0]     |
  | TURN_LEFT_BR_ANCHOR | [n0,n1,n0,n0]    | [n1,n0,n1,n1]     |

  ## Forage loop structure (decrement-first, K = 128)

  ```
  FORAGE_LOOP_HEAD:
    decrement slot[0]; if 0 → jz_t LOOP_HEAD (exit)
    sense_front
    dup; jz_t EMPTY              ; pops the dup, jumps if value == 0
    drop                          ; non-empty: drop the remaining value
    eat; move
    slot[3] := 0                  ; reset low-energy counter
    jmp_t FORAGE_LOOP_HEAD
  EMPTY:
    drop                          ; drop the leftover value (= 0)
    eat; move                     ; eat is a no-op cost-wise (still pays 2)
    counter := slot[3] + 1
    if (counter mod 5) != 0:
      slot[3] := counter; jmp_t FORAGE_LOOP_HEAD
    else:                                          (DO_TURN)
      slot[3] := 0
      if (pushN mod 2) == 0:                       (jz_t TURN_LEFT_BR)
        turn_right
      else:                                        (TURN_LEFT_BR)
        turn_left
      jmp_t FORAGE_LOOP_HEAD
  ```

  ## Separators `push0`

  The template-extractor reads up to `template_max_len` (default 8) consecutive
  nops. Three sites in this codeome have a `jmp_t` template (4 nops) immediately
  before an anchor (4 nops), totalling 8 consecutive nops. A `:push0` is inserted
  between each pair to prevent mis-extraction.
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

    # ── pos 15..17: init slot[1] = 0 ─────────────────────────────────────
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

    # ── K+1 = 129 (decrement-first loop overshoots by 1) ─────────────────
    :push1, :add,

    # ── store K+1 in slot[0] ─────────────────────────────────────────────
    :push0, :store,

    # ── init slot[3] := 0 ────────────────────────────────────────────────
    # Stack trace: push0[0]; push1[0,1]; push1[0,1,1]; push1[0,1,1,1];
    # add[0,1,2]; add[0,3]; store → slot[3] := 0. (7 opcodes, two adds.)
    :push0, :push1, :push1, :push1, :add, :add, :store,

    # ── FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────────────────
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── decrement slot[0]; load result for exit check ────────────────────
    :push0, :load, :push1, :sub, :push0, :store,
    :push0, :load,

    # ── jz_t LOOP_HEAD (exit forage when counter is 0) ───────────────────
    :jz_t, :nop_0, :nop_0, :nop_0, :nop_0,

    # ── sense_front; dup; jz_t EMPTY_ANCHOR ──────────────────────────────
    :sense_front,
    :dup,
    :jz_t, :nop_1, :nop_1, :nop_1, :nop_0,

    # ── (non-empty path) drop remaining value; eat; move; reset slot[3] ──
    :drop,
    :eat, :move,
    # NOTE: plan had :push1,:push1,:push1,:add,:store — fixed to two adds to actually build slot 3.
    :push0, :push1, :push1, :push1, :add, :add, :store,    # slot[3] := 0
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,                # template for FORAGE_LOOP_HEAD
    # NOTE: :push0 separator prevents 8-consecutive-nop template extraction (same role as MR pos 67 and pos 120).
    :push0,

    # ── EMPTY_ANCHOR [n0,n0,n0,n1] ──────────────────────────────────────
    :nop_0, :nop_0, :nop_0, :nop_1,

    # ── (empty path) drop leftover 0; eat; move ──────────────────────────
    :drop,
    :eat, :move,

    # ── increment slot[3]; check mod 5 ───────────────────────────────────
    # NOTE: plan had :push1,:push1,:push1,:add,:load — fixed to two adds to actually build slot 3.
    :push1, :push1, :push1, :add, :add, :load,             # build slot idx 3, load
    :push1, :add,                                           # counter + 1
    :dup,                                                   # [counter+1, counter+1]
    # build 5 = push1(1); dup+add(2); dup+add(4); push1+add(5)
    :push1, :dup, :add, :dup, :add, :push1, :add,
    :mod,

    # ── jz_t DO_TURN_ANCHOR — if (counter+1) mod 5 == 0 ─────────────────
    :jz_t, :nop_1, :nop_0, :nop_0, :nop_0,

    # ── (mod != 0) store counter+1 to slot[3]; jmp_t FORAGE_LOOP_HEAD ───
    # NOTE: plan had :push1,:push1,:push1,:add,:store — fixed to two adds to actually build slot 3.
    :push1, :push1, :push1, :add, :add, :store,            # build slot idx 3, store
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,               # template for FORAGE_LOOP_HEAD
    # NOTE: :push0 separator prevents 8-consecutive-nop template extraction (same role as MR pos 67 and pos 120).
    :push0,

    # ── DO_TURN_ANCHOR [n0,n1,n1,n1] ────────────────────────────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    # ── (mod == 0) drop counter+1; reset slot[3] := 0 ───────────────────
    :drop,
    :push0, :push1, :push1, :push1, :add, :add, :store,   # slot[3] := 0

    # ── random turn: pushN mod 2; jz_t TURN_LEFT_BR_ANCHOR ───────────────
    :pushN, :push1, :push1, :add, :mod,
    :jz_t, :nop_1, :nop_0, :nop_1, :nop_1,                # template for TURN_LEFT_BR

    # ── turn_right path ──────────────────────────────────────────────────
    :turn_right,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,               # template for FORAGE_LOOP_HEAD
    # NOTE: :push0 separator prevents 8-consecutive-nop template extraction (same role as MR pos 67 and pos 120).
    :push0,

    # ── TURN_LEFT_BR_ANCHOR [n0,n1,n0,n0] ───────────────────────────────
    :nop_0, :nop_1, :nop_0, :nop_0,

    # ── turn_left path ───────────────────────────────────────────────────
    :turn_left,
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,               # template for FORAGE_LOOP_HEAD

    # ── separator (final wrap protection) ───────────────────────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
