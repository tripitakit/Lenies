defmodule Lenies.Codeomes.Ancestor do
  @moduledoc """
  Rung 2 of the seed capability ladder — the canonical self-replicator.

  Measure self, allocate a child slot, copy the chromosome opcode-by-opcode,
  `divide`, then forage to refuel before the next generation. This is the
  irreducible *true* replicator — Tierra's ancestor reimagined — and the first
  rung that reproduces.

  It is deliberately **not** `MinimalReplicator`'s implementation:

  - MR keeps **two** slots (`N` in slot 0, an **up-counter** in slot 1) and
    reloads both every iteration, copying low→high.
  - Ancestor keeps **one** slot used as a **down-counter that is also the copy
    address** (`i = N-1 … 0`, copying high→low). The loop variable is both the
    counter and the operand: `load i; dup; read_self; write_child`.
  - Deterministic single post-divide `turn_right`; no carried plasmid.

  ## Algorithm

  ```
  HEAD:
    get_size ; push0 ; store     ; slot0 = N   (save own length)
    push0 ; load ; allocate      ; reserve a child of size N
    jz_t ABORT                   ; alloc failed → refuel and retry
    push0 ; load ; push1 ; sub   ; N-1
    push0 ; store                ; slot0 = N-1 (top copy index)
  COPY:
    push0 ; load ; dup           ; [i, i]
    read_self ; write_child ; drop   ; child[i] := own[i]
    push0 ; load ; jz_t REPRODUCE    ; copied index 0 → divide
    push0 ; load ; push1 ; sub ; push0 ; store   ; i := i-1
    jmp_t COPY
  REPRODUCE:
    divide ; turn_right          ; bear child, step off it
  ABORT:                         ; forage init (also alloc-fail landing)
    <build 64> ; push0 ; store   ; slot0 = 64 forage budget
  FORAGE:
    push0 ; load ; jz_t HEAD     ; budget spent → replicate again
    eat ; move
    push0 ; load ; push1 ; sub ; push0 ; store   ; budget--
    jmp_t FORAGE
  ```

  ## Stack-machine technique

  A loop variable that is **simultaneously the counter and the address**: one
  slot drives the copy address, the zero-test, and the decrement. The clean
  allocate path saves `N` to a slot first so the fail branch leaves the stack
  empty (no leftover operand on either side of `jz_t ABORT`).

  ## Template anchors (4-bit; complement = bit-flip)

  | Label     | Anchor          | Jump template     |
  |-----------|-----------------|-------------------|
  | HEAD      | [n1,n1,n1,n1]   | [n0,n0,n0,n0]     |
  | COPY      | [n1,n0,n0,n1]   | [n0,n1,n1,n0]     |
  | REPRODUCE | [n1,n1,n0,n0]   | [n0,n0,n1,n1]     |
  | ABORT     | [n1,n0,n1,n0]   | [n0,n1,n0,n1]     |
  | FORAGE    | [n1,n0,n0,n0]   | [n0,n1,n1,n1]     |

  The five anchors are drawn from five **different complement-pairs**, so all
  ten nop windows (five anchors + five templates) are distinct 4-bit patterns.
  Each search target therefore occurs exactly once in the ring, and every jump
  resolves to its intended anchor regardless of scan order. `:push0` separators
  follow each jump template so the extractor never merges a template into the
  anchor behind it.

  ## Energy / viability

  Copy cost ≈ 5 energy per opcode copied (~500 for the 100-opcode chromosome),
  plus `allocate` (~10) and `divide` (10). The post-divide forage budget is
  K=64; at the production `eat_amount` of 20 each forage iteration nets
  ~+15, so a full forage run (~+960) comfortably covers a generation. Net
  steady state is positive in a food-bearing world.

  ## References

  - T.S. Ray, "An approach to the synthesis of life," *Artificial Life II*
    (Langton et al., eds.), Addison-Wesley, 1991 — the ancestor `0080aaa`.
  - J. von Neumann, *Theory of Self-Reproducing Automata* (Burks, ed., 1966) —
    copy-then-construct reproduction.

  See `docs/superpowers/specs/2026-06-11-seed-codeomes-redesign-design.md` §3.
  """

  alias Lenies.Codeome

  @opcodes [
    # ── pos 0..3: HEAD anchor [n1,n1,n1,n1] ──────────────────────────────
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_1,

    # ── pos 4..6: save own size N into slot[0] ───────────────────────────
    :get_size,
    :push0,
    :store,

    # ── pos 7..9: allocate a child of size N in the front cell ───────────
    :push0,
    :load,
    :allocate,

    # ── pos 10..14: jz_t ABORT — allocate failed → refuel and retry ──────
    :jz_t,
    :nop_0,
    :nop_1,
    :nop_0,
    :nop_1,

    # ── pos 15..20: top copy index N-1 → slot[0] ─────────────────────────
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,

    # ── pos 21..24: COPY anchor [n1,n0,n0,n1] ────────────────────────────
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_1,

    # ── pos 25..30: copy own[i] → child[i] ───────────────────────────────
    # push0;load → i ; dup → [i,i] ; read_self pops i → [i, op_i] ;
    # write_child pops op_i then i (addr) → [ok] ; drop → []
    :push0,
    :load,
    :dup,
    :read_self,
    :write_child,
    :drop,

    # ── pos 31..32: reload i for the zero test ───────────────────────────
    :push0,
    :load,

    # ── pos 33..37: jz_t REPRODUCE — copied index 0 → divide ─────────────
    :jz_t,
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_1,

    # ── pos 38..43: decrement i (slot[0] -= 1) ───────────────────────────
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,

    # ── pos 44..48: jmp_t COPY ───────────────────────────────────────────
    :jmp_t,
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_0,

    # ── pos 49: separator ────────────────────────────────────────────────
    :push0,

    # ── pos 50..53: REPRODUCE anchor [n1,n1,n0,n0] ───────────────────────
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_0,

    # ── pos 54..55: bear the child, then step off it ─────────────────────
    :divide,
    :turn_right,

    # ── pos 56..59: ABORT anchor [n1,n0,n1,n0] (also alloc-fail landing) ──
    :nop_1,
    :nop_0,
    :nop_1,
    :nop_0,

    # ── pos 60..72: build 64 forage budget (push1 + 6×(dup,add)) ─────────
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

    # ── pos 73..74: store budget in slot[0] ──────────────────────────────
    :push0,
    :store,

    # ── pos 75..78: FORAGE anchor [n1,n0,n0,n0] ──────────────────────────
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_0,

    # ── pos 79..80: load budget for exit check ───────────────────────────
    :push0,
    :load,

    # ── pos 81..85: jz_t HEAD — budget spent → replicate again ───────────
    :jz_t,
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,

    # ── pos 86..87: forage — eat then advance ────────────────────────────
    :eat,
    :move,

    # ── pos 88..93: decrement budget (slot[0] -= 1) ──────────────────────
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,

    # ── pos 94..98: jmp_t FORAGE ─────────────────────────────────────────
    :jmp_t,
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_1,

    # ── pos 99: separator (breaks the wrap into HEAD at pos 0) ────────────
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging and tests)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
