defmodule Lenies.Codeomes.MinimalReplicator do
  @moduledoc """
  Hand-written Codeome for sustainable emergent replication.

  Key difference from a "minimal test" replicator (1 forage between divides):
  after each `:divide` the cell turns right **or** left at random (50/50 via
  `:pushN` + `:mod 2`), to escape from behind the newly born child that would
  block `:move`. It then runs K=128 forage cycles before retrying replication.
  This amortises the cost of the copy loop (~6 energy units per opcode copied)
  over many forage iterations, yielding a positive energetic steady state.

  ## Algorithm

  ```
  LOOP_HEAD:
    1. Get own size N, store in slot[0]
    2. Allocate child slot of size N in front cell
    3. If allocate fails → jump to ABORT_TARGET
    4. Init copy counter slot[1] = 0
  COPY_LOOP_HEAD:
    5. Read opcode at counter, write to child at counter; increment counter
    6. When counter == N, exit loop → divide
  ABORT_TARGET (landing for both abort and post-divide fallthrough):
    7. random := pushN; if (random mod 2) == 0 turn_left else turn_right
    8. Build K=128 on stack via push1 + 7×(dup,add); store in slot[0]
  FORAGE_LOOP_HEAD:
    9. sense_front; drop; eat; move
   10. counter := counter - 1
   11. if counter != 0 → jump back to FORAGE_LOOP_HEAD
   12. jump back to LOOP_HEAD
  ```

  ## Template anchors (4-bit, Tierra-style)

  Anchors are the nops embedded in the code. Jump instructions read the template
  (the nops following the jump opcode) and search the codeome for the *complement*
  of that template. Bit-flip: `nop_0 ↔ nop_1`.

  | Label                | Anchor             | Jump template        |
  |----------------------|--------------------|----------------------|
  | LOOP_HEAD            | [n1, n1, n1, n1]   | [n0, n0, n0, n0]     |
  | COPY_LOOP_HEAD       | [n1, n0, n0, n1]   | [n0, n1, n1, n0]     |
  | ABORT_TARGET         | [n1, n1, n0, n0]   | [n0, n0, n1, n1]     |
  | TURN_LEFT_ANCHOR     | [n0, n1, n0, n0]   | [n1, n0, n1, n1]     |
  | SKIP_TURN_ANCHOR     | [n0, n0, n1, n0]   | [n1, n1, n0, n1]     |
  | FORAGE_LOOP_HEAD     | [n0, n1, n0, n1]   | [n1, n0, n1, n0]     |

  Six anchor patterns + six jump templates, all distinct. Every jump finds its
  target (forward or backward after wrap) before any false match.

  ## Separators `push0`

  The template-extractor reads up to `template_max_len` (default 8) consecutive
  nops. To guarantee that a template always extracts exactly 4 nops, two adjacent
  nop blocks must be separated by a non-nop opcode. Two positions where this is
  needed:

  - **Pos 67**: between the template of `jmp_t skip` (63..66) and
    `TURN_LEFT_ANCHOR` (68..71).
  - **Pos 120**: between the template of the final `jmp_t` (116..119) and
    `LOOP_HEAD` (0..3) across the codeome wrap.

  Both are `:push0` placed at dead positions (unreachable code: the two branches
  of the random turn jump past them).

  ## Conventions

  - `:store` pops slot_idx (top), pops value (second). To store V → slot[S]:
    `push V, push S, store`.
  - `:write_child` pops opcode_int (top), pops child_addr (second).
  - `:sub` pops a (top), pops b (second), pushes `b - a`.
  - `:mod` pops a (top), pops b (second), pushes `b mod a`.
  - `:load` pops slot_idx (top), pushes `slots[slot_idx]`.
  - `:pushN` pushes a random integer in 0..255 (see `Interpreter.dispatch`).
  - Slot[0] is used in two non-overlapping phases: first for N (size), then
    for the forage counter. Slot[1] is the copy loop counter.

  ## Energy balance (with default `eat_amount` = 20)

  - Codeome length: 123 opcodes (121 + 2 for in-forage `:conjugate, :drop`)
    → copy loop body cost ~6.8/iter × 123 ≈ 836
  - Allocate(123) + setup + divide ≈ ~33
  - Plasmid replication tax: 0.5 × 31 (Twitch plasmid) ≈ 15.5
  - Total replication cost: ~885
  - Forage per cycle: sense+drop+eat+move (~5.6) + conjugate+drop (~4.1) +
    counter ops (~2.5) + plasmid intercept (~1.8 when it fires) ≈ 13.4
  - Eat gain at default `eat_amount` = 20. Net: ~+6.6 per iter × 128 ≈ +845/gen
  - Steady state ≈ 2 × 128 × 6.6 − 885 ≈ +805. Sustainable.

  See [`docs/superpowers/specs/2026-05-19-seed-plasmids-design.md`] for the
  Twitch plasmid layout and the full cost derivation.
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──────────────────────
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_1,

    # ── pos 4..6: get own size N, store in slot[0] ───────────────────────
    :get_size,
    :push0,
    :store,

    # ── pos 7..9: allocate child slot of size N in front cell ────────────
    :push0,
    :load,
    :allocate,

    # ── pos 10..14: jz_t → if allocate failed, jump to ABORT_TARGET ──────
    :jz_t,
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_1,

    # ── pos 15..17: init copy counter slot[1] = 0 ────────────────────────
    :push0,
    :push1,
    :store,

    # ── pos 18..21: COPY_LOOP_HEAD anchor [n1, n0, n0, n1] ───────────────
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_1,

    # ── pos 22..24: read opcode at counter ───────────────────────────────
    :push1,
    :load,
    :read_self,

    # ── pos 25..29: write opcode to child at counter ─────────────────────
    :push1,
    :load,
    :swap,
    :write_child,
    :drop,

    # ── pos 30..35: increment counter slot[1] += 1 ───────────────────────
    :push1,
    :load,
    :push1,
    :add,
    :push1,
    :store,

    # ── pos 36..40: loop condition (N - (counter+1) != 0?) ───────────────
    :push0,
    :load,
    :push1,
    :load,
    :sub,

    # ── pos 41..45: jnz_t → back to COPY_LOOP_HEAD if not done ───────────
    :jnz_t,
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_0,

    # ── pos 46: divide ───────────────────────────────────────────────────
    :divide,

    # ── pos 47..50: ABORT_TARGET anchor [n1, n1, n0, n0] ─────────────────
    # Landing pad for both jz_t (allocate failed) and fall-through after divide.
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_0,

    # ── pos 51..55: r := pushN; stack ← (r mod 2) ────────────────────────
    :pushN,
    :push1,
    :push1,
    :add,
    :mod,

    # ── pos 56..60: jz_t → if 0, jump to TURN_LEFT_ANCHOR ────────────────
    :jz_t,
    :nop_1,
    :nop_0,
    :nop_1,
    :nop_1,

    # ── pos 61: turn_right (executed when r mod 2 == 1) ─────────────────
    :turn_right,

    # ── pos 62..66: jmp_t → skip turn_left branch ────────────────────────
    :jmp_t,
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_1,

    # ── pos 67: separator (dead code, never executed) ────────────────────
    # Prevents the template-extractor from reading past the 4 nops of the
    # template above (pos 63..66) and into TURN_LEFT_ANCHOR.
    :push0,

    # ── pos 68..71: TURN_LEFT_ANCHOR [n0, n1, n0, n0] ────────────────────
    :nop_0,
    :nop_1,
    :nop_0,
    :nop_0,

    # ── pos 72: turn_left (executed when r mod 2 == 0) ──────────────────
    :turn_left,

    # ── pos 73..76: SKIP_TURN_ANCHOR [n0, n0, n1, n0] ────────────────────
    # Both branches (turn_right and turn_left) converge here to fall
    # naturally into the forage init.
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_0,

    # ── pos 77..91: build K=128 on stack ─────────────────────────────────
    # push1 (=1), then 7 doublings via dup+add: 2, 4, 8, 16, 32, 64, 128
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
    :dup,
    :add,
    :dup,
    :add,

    # ── pos 92..93: store K in slot[0] ───────────────────────────────────
    # slot[0] is free here: the next `get_size; push0; store` will overwrite it
    :push0,
    :store,

    # ── pos 94..97: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
    :nop_0,
    :nop_1,
    :nop_0,
    :nop_1,

    # ── pos 98..101: forage body — sense, drop result, eat, move ─────────
    :sense_front,
    :drop,
    :eat,
    :move,

    # ── pos 102..103: try to infect a neighbor; drop the result ─────────
    :conjugate,
    :drop,

    # ── pos 104..109: counter := counter - 1 (slot[0]) ───────────────────
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,

    # ── pos 110..111: load counter for check ─────────────────────────────
    :push0,
    :load,

    # ── pos 112..116: jnz_t → back to FORAGE_LOOP_HEAD if counter != 0 ───
    :jnz_t,
    :nop_1,
    :nop_0,
    :nop_1,
    :nop_0,

    # ── pos 117..121: jmp_t → back to LOOP_HEAD to retry replication ─────
    :jmp_t,
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,

    # ── pos 122: separator (dead code, never executed) ───────────────────
    # Without this, the final jmp_t's template extraction would read
    # 4 nops of the template + 4 nops of LOOP_HEAD across the wrap (8 nops
    # total). Forcing a non-nop at the wrap stops extraction at 4.
    :push0
  ]

  @doc "Returns the raw opcode list (plasmid-free base; useful for debugging and Carnivore)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes

  @plasmid_opcodes [
    # ── pos 0..3: INTERCEPT_ANCHOR = FORAGE_LOOP_HEAD pattern [n0,n1,n0,n1] ──
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 4..8: pushN mod 2 ────────────────────────────────────────────
    :pushN, :push1, :push1, :add, :mod,

    # ── pos 9..13: jz_t TURN_LEFT_BR (template [n1,n0,n0,n0] → [n0,n1,n1,n1]) ──
    :jz_t, :nop_1, :nop_0, :nop_0, :nop_0,

    # ── pos 14: turn_right (mod was 1) ───────────────────────────────────
    :turn_right,

    # ── pos 15..19: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ──────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 20: separator ────────────────────────────────────────────────
    :push0,

    # ── pos 21..24: TURN_LEFT_BR anchor [n0,n1,n1,n1] ───────────────────
    :nop_0, :nop_1, :nop_1, :nop_1,

    # ── pos 25: turn_left (mod was 0) ────────────────────────────────────
    :turn_left,

    # ── pos 26..30: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ──────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0
  ]

  @doc """
  The Twitch plasmid: 31 opcodes that intercept the host's per-iteration
  `jnz_t FORAGE_LOOP_HEAD` and inject a random L/R turn before bouncing back.

  Anchor at pos 0..3 (`[n0,n1,n0,n1]`) matches the FORAGE_LOOP_HEAD pattern
  in any MR-derived codeome. The intercept fires every forage iteration
  (via the host's `jnz_t FORAGE_LOOP_HEAD`), producing visible movement.
  """
  @spec plasmid() :: [atom()]
  def plasmid, do: @plasmid_opcodes

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes ++ @plasmid_opcodes)
end
