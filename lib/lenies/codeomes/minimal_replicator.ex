defmodule Lenies.Codeomes.MinimalReplicator do
  @moduledoc """
  Codeome scritto a mano per replicazione emergente sostenibile.

  Differenza chiave rispetto a un replicator "minimo da test" (1 forage tra
  divide e divide): qui dopo ogni `:divide` la cellula ruota a destra **o** a
  sinistra in modo casuale (50/50 via `:pushN` + `:mod 2`), per uscire da
  dietro al figlio appena nato che blocca il `:move`. Poi fa K=128 cicli di
  forage prima di ritentare la replicazione. Questo amortizza il costo del
  copy loop (~6 unità di energia per opcode copiato) su molte iterazioni di
  forage, dando uno steady-state energetico positivo.

  ## Algoritmo

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

  Anchor = i nop incorporati nel codice. Le jump leggono il template (i nop
  che seguono l'opcode di salto) e cercano nel codeome il *complemento* di
  quel template. Bit-flip: `nop_0 ↔ nop_1`.

  | Label                | Anchor             | Jump template        |
  |----------------------|--------------------|----------------------|
  | LOOP_HEAD            | [n1, n1, n1, n1]   | [n0, n0, n0, n0]     |
  | COPY_LOOP_HEAD       | [n1, n0, n0, n1]   | [n0, n1, n1, n0]     |
  | ABORT_TARGET         | [n1, n1, n0, n0]   | [n0, n0, n1, n1]     |
  | TURN_LEFT_ANCHOR     | [n0, n1, n0, n0]   | [n1, n0, n1, n1]     |
  | SKIP_TURN_ANCHOR     | [n0, n0, n1, n0]   | [n1, n1, n0, n1]     |
  | FORAGE_LOOP_HEAD     | [n0, n1, n0, n1]   | [n1, n0, n1, n0]     |

  Sei pattern di anchor + sei template, tutti distinti tra loro. Ogni jump
  trova in avanti (o backward, dopo wrap) il proprio target prima di
  qualunque false match.

  ## Separatori `push0`

  Il template-extractor legge fino a `template_max_len` (default 8) nop
  consecutivi. Per garantire che un template estragga sempre esattamente
  4 nop, due blocchi di nop adiacenti devono essere separati da un opcode
  non-nop. Due punti in cui ne servono:

  - **Pos 67**: tra il template di `jmp_t skip` (63..66) e
    `TURN_LEFT_ANCHOR` (68..71).
  - **Pos 120**: tra il template del `jmp_t` finale (116..119) e
    `LOOP_HEAD` (0..3) attraverso il wrap del codeome.

  Entrambi sono `:push0` posti in posizioni morte (unreachable code: i due
  branch del turn random saltano oltre).

  ## Conventions

  - `:store` pops slot_idx (top), pops value (second). Per V → slot[S]:
    `push V, push S, store`.
  - `:write_child` pops opcode_int (top), pops child_addr (second).
  - `:sub` pops a (top), pops b (second), pushes `b - a`.
  - `:mod` pops a (top), pops b (second), pushes `b mod a`.
  - `:load` pops slot_idx (top), pushes `slots[slot_idx]`.
  - `:pushN` pushes un intero random in 0..255 (vedi `Interpreter.dispatch`).
  - Slot[0] è usato in due fasi non sovrapposte: prima per N (taglia), poi
    per il contatore di forage. Slot[1] è il contatore del copy loop.

  ## Energy balance (con `eat_amount` di default = 20)

  - Codeome length: 121 opcode → copy loop body cost ~6/iter × 121 ≈ 726
  - Allocate(121) + setup + divide ≈ ~33
  - Costo totale per replicazione: ~759
  - Forage per ciclo: 4 op (cost 6.1) + counter ops (~2.5) = 8.6. Eat gain = 20.
    Netto: +11.4 per iter. × 128 ≈ +1459 per gen
  - E_new = (E_old − 759) / 2 + 1459 = E_old/2 + 1080. Steady state ≈ 2160.
    Sostenibile finché le celle attraversate hanno almeno ~20 unità di risorsa.
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
    # Landing pad sia per jz_t (allocate fallita) sia per fall-through dopo divide.
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

    # ── pos 61: turn_right (eseguito quando r mod 2 == 1) ────────────────
    :turn_right,

    # ── pos 62..66: jmp_t → skip turn_left branch ────────────────────────
    :jmp_t,
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_1,

    # ── pos 67: separator (dead code, never executed) ────────────────────
    # Serve a impedire al template-extractor di leggere oltre i 4 nop del
    # template appena sopra (pos 63..66) finendo dentro TURN_LEFT_ANCHOR.
    :push0,

    # ── pos 68..71: TURN_LEFT_ANCHOR [n0, n1, n0, n0] ────────────────────
    :nop_0,
    :nop_1,
    :nop_0,
    :nop_0,

    # ── pos 72: turn_left (eseguito quando r mod 2 == 0) ─────────────────
    :turn_left,

    # ── pos 73..76: SKIP_TURN_ANCHOR [n0, n0, n1, n0] ────────────────────
    # I due rami (turn_right e turn_left) convergono qui per cadere
    # naturalmente nel forage init.
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_0,

    # ── pos 77..91: build K=128 on stack ─────────────────────────────────
    # push1 (=1), poi 7 doppiamenti via dup+add: 2, 4, 8, 16, 32, 64, 128
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
    # slot[0] è libero qui: il prossimo `get_size; push0; store` la sovrascriverà
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

    # ── pos 102..107: counter := counter - 1 (slot[0]) ───────────────────
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,

    # ── pos 108..109: load counter for check ─────────────────────────────
    :push0,
    :load,

    # ── pos 110..114: jnz_t → back to FORAGE_LOOP_HEAD if counter != 0 ───
    :jnz_t,
    :nop_1,
    :nop_0,
    :nop_1,
    :nop_0,

    # ── pos 115..119: jmp_t → back to LOOP_HEAD per ritentare replicazione
    :jmp_t,
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0,

    # ── pos 120: separator (dead code, never executed) ───────────────────
    # Senza questo, l'estrazione del template del jmp_t finale leggerebbe
    # 4 nop del template + 4 nop del LOOP_HEAD attraverso il wrap (8 nop
    # totali). Forzando un non-nop al wrap, l'estrazione si ferma a 4.
    :push0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
