defmodule Lenies.Codeomes.Symbiont do
  @moduledoc """
  Rung 4 of the seed capability ladder — the adaptive, infective organism.

  The most complex rung. It **introspects its own age** to switch phenotype on a
  regulatory clock, performs **horizontal gene transfer it initiates itself** —
  minting a plasmid at runtime with `make_plasmid` and pushing it into adjacent
  neighbours with `conjugate` — and replicates so the trait spreads both
  **vertically** (division) and **horizontally** (conjugation).

  No current seed uses `sense_age`, `make_plasmid`, or in-code `conjugate`; the
  existing plasmids are pre-injected at spawn, never minted by the organism.

  ## Life cycle

  At spawn (`ip = 0`) it mints a 4-gene passenger cassette once, then loops on an
  age clock:

  ```
  ENTRY (runs once):
    push0 ; <build 4> ; make_plasmid ; drop   ; mint codeome[0..3] as a plasmid

  MAIN:
    sense_age ; <build 8> ; mod ; jz_t REPRO   ; age % 8 == 0 → reproduce phase
  SPREAD:                                       ; else forage + infect
    sense_front ; push1 ; add ; jz_t INFECT     ; neighbour ahead → conjugate
    eat ; move ; jmp_t MAIN
  INFECT:
    conjugate ; drop ; move ; jmp_t MAIN
  REPRO:
    get_size ; push0 ; store
    push0 ; load ; allocate ; jz_t MAIN          ; alloc failed → skip
    push0 ; load ; push1 ; sub ; push0 ; store   ; slot0 = N-1
    RCOPY:
      push0 ; load ; dup ; read_self ; write_child ; drop
      push0 ; load ; jz_t RDIV
      push0 ; load ; push1 ; sub ; push0 ; store
      jmp_t RCOPY
    RDIV:
      divide ; turn_right ; jmp_t MAIN
  ```

  The **passenger cassette** is `codeome[0..3]` (= `[push0, push1, dup, add]`).
  It contains no `:nop` opcodes, so it can never become a template-jump target
  in a recipient — it rides as an inert, inherited gene rather than hijacking
  behaviour. The demonstrated capability is the HGT *pathway* (mint → transfer →
  inherit), observable as rising plasmid counts in neighbouring lineages (see
  the species plasmid-count panel); the cassette's payload is intentionally
  benign.

  Reproduction happens roughly once every eight metabolic ticks (`age % 8`),
  leaving seven ticks of foraging to pay for each copy — a regulatory duty cycle
  rather than continuous division.

  ## Stack-machine technique

  Internal-state introspection (`sense_age`) as a **conditional dispatch**, an
  **environment-conditioned action** (`sense_front` → `conjugate`), and the
  **`make_plasmid` + `conjugate` HGT pathway** wired from the organism's own
  opcodes. (The regulatory switch is an exact age-modulo clock rather than an
  energy threshold — a deliberate design choice; the `:jlt_t`/`:jgt_t` sign
  branches added later would also permit a threshold form. See design doc §4.)

  ## Template anchors (4-bit; complement = bit-flip)

  Five labels, drawn from five **different complement-pairs**, so the five
  anchors and their templates are ten mutually-distinct 4-bit patterns and every
  jump resolves uniquely. The repeated `template_MAIN` (`0000`) is fine: it only
  ever searches for `MAIN` (`1111`), which occurs exactly once.

  | Label  | Anchor          | Template        |
  |--------|-----------------|-----------------|
  | MAIN   | [n1,n1,n1,n1]   | [n0,n0,n0,n0]   |
  | REPRO  | [n1,n0,n0,n1]   | [n0,n1,n1,n0]   |
  | INFECT | [n1,n1,n0,n0]   | [n0,n0,n1,n1]   |
  | RCOPY  | [n1,n0,n1,n0]   | [n0,n1,n0,n1]   |
  | RDIV   | [n1,n0,n0,n0]   | [n0,n1,n1,n1]   |

  ## References

  - J. Lederberg & E.L. Tatum, "Gene recombination in *Escherichia coli*,"
    *Nature*, 1946 — bacterial conjugation / plasmid transfer.
  - F. Jacob & J. Monod, "Genetic regulatory mechanisms…," *J. Mol. Biol.*,
    1961 — the *lac* operon as the canonical regulatory switch.
  - Quorum sensing — density-conditioned bacterial behaviour.

  See `docs/superpowers/specs/2026-06-11-seed-codeomes-redesign-design.md` §3.
  """

  alias Lenies.Codeome

  @opcodes [
    # ═══ ENTRY — mint the passenger cassette once (runs at ip 0) ═════════
    # pos 0: start_addr = 0
    :push0,
    # pos 1..5: build length 4 (push1; dup; add; dup; add)
    :push1,
    :dup,
    :add,
    :dup,
    :add,
    # pos 6: mint codeome[0..3] as a plasmid (pushes 1/0)
    :make_plasmid,
    # pos 7: discard the result
    :drop,

    # ═══ MAIN — age clock ════════════════════════════════════════════════
    # pos 8..11: MAIN anchor [n1,n1,n1,n1]
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_1,
    # pos 12: read own age
    :sense_age,
    # pos 13..19: build 8 (push1 + 3×(dup,add))
    :push1,
    :dup,
    :add,
    :dup,
    :add,
    :dup,
    :add,
    # pos 20: age mod 8
    :mod,
    # pos 21: if 0 → REPRO
    :jz_t,
    # pos 22..25: template_REPRO [n0,n1,n1,n0]
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_0,

    # ═══ SPREAD — forage + conditional infect ════════════════════════════
    # pos 26..28: v+1 (lenie -1 → 0)
    :sense_front,
    :push1,
    :add,
    # pos 29: neighbour ahead → INFECT
    :jz_t,
    # pos 30..33: template_INFECT [n0,n0,n1,n1]
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_1,
    # pos 34..35: forage
    :eat,
    :move,
    # pos 36: back to MAIN
    :jmp_t,
    # pos 37..40: template_MAIN [n0,n0,n0,n0]
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,
    # pos 41: separator
    :push0,

    # ═══ INFECT ══════════════════════════════════════════════════════════
    # pos 42..45: INFECT anchor [n1,n1,n0,n0]
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_0,
    # pos 46..48: transfer a plasmid to the neighbour, then advance
    :conjugate,
    :drop,
    :move,
    # pos 49: back to MAIN
    :jmp_t,
    # pos 50..53: template_MAIN [n0,n0,n0,n0]
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,
    # pos 54: separator
    :push0,

    # ═══ REPRO — allocate + copy + divide ════════════════════════════════
    # pos 55..58: REPRO anchor [n1,n0,n0,n1]
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_1,
    # pos 59..61: slot0 = N
    :get_size,
    :push0,
    :store,
    # pos 62..64: allocate child of size N
    :push0,
    :load,
    :allocate,
    # pos 65: alloc failed → MAIN
    :jz_t,
    # pos 66..69: template_MAIN [n0,n0,n0,n0]
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,
    # pos 70: separator
    :push0,
    # pos 71..76: slot0 = N-1
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,
    # pos 77..80: RCOPY anchor [n1,n0,n1,n0]
    :nop_1,
    :nop_0,
    :nop_1,
    :nop_0,
    # pos 81..86: copy own[i] → child[i]
    :push0,
    :load,
    :dup,
    :read_self,
    :write_child,
    :drop,
    # pos 87..88: reload i
    :push0,
    :load,
    # pos 89: i==0 → RDIV
    :jz_t,
    # pos 90..93: template_RDIV [n0,n1,n1,n1]
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_1,
    # pos 94..99: i--
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,
    # pos 100: loop
    :jmp_t,
    # pos 101..104: template_RCOPY [n0,n1,n0,n1]
    :nop_0,
    :nop_1,
    :nop_0,
    :nop_1,
    # pos 105: separator
    :push0,
    # pos 106..109: RDIV anchor [n1,n0,n0,n0]
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_0,
    # pos 110..111: bear child, step off
    :divide,
    :turn_right,
    # pos 112: back to MAIN
    :jmp_t,
    # pos 113..116: template_MAIN [n0,n0,n0,n0]
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,
    # pos 117: separator (wrap to MAIN at pos 8)
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging and tests)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
