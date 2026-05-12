defmodule Lenies.Codeomes.MinimalReplicator do
  @moduledoc """
  Codeome scritto a mano per replicazione emergente sostenibile.

  Differenza chiave rispetto a un replicator "minimo da test" (1 forage tra
  divide e divide): qui dopo ogni `:divide` la cellula ruota a destra (per
  uscire da dietro al figlio appena nato che blocca il `:move`) e fa K=64
  cicli di forage prima di ritentare la replicazione. Questo amortizza il
  costo del copy loop (~6 unità di energia per opcode copiato) su molte
  iterazioni di forage, dando uno steady-state energetico positivo.

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
    7. (After divide OR after abort jump)
  ABORT_TARGET:
    8. turn_right            # esce da dietro al figlio
    9. Build K=64 on stack via push1 + 6×(dup,add)
   10. Store K in slot[0]    # slot[0] è libero: N non serve fino al prossimo LOOP_HEAD
  FORAGE_LOOP_HEAD:
   11. sense_front; drop; eat; move
   12. counter := counter - 1
   13. if counter != 0 → jump back to FORAGE_LOOP_HEAD
   14. jump back to LOOP_HEAD
  ```

  ## Template anchors (4-bit, Tierra-style)

  Anchor = i nop incorporati nel codice. Le jump leggono il template (i nop
  che seguono l'opcode di salto) e cercano nel codeome il *complemento* di
  quel template. Bit-flip:`nop_0 ↔ nop_1`.

  | Label              | Anchor             | Jump template        |
  |--------------------|--------------------|----------------------|
  | LOOP_HEAD          | [n1, n1, n1, n1]   | [n0, n0, n0, n0]     |
  | COPY_LOOP_HEAD     | [n1, n0, n0, n1]   | [n0, n1, n1, n0]     |
  | ABORT_TARGET       | [n1, n1, n0, n0]   | [n0, n0, n1, n1]     |
  | FORAGE_LOOP_HEAD   | [n0, n1, n0, n1]   | [n1, n0, n1, n0]     |

  I quattro pattern di anchor sono distinti tra loro e nessuno appare
  altrove nel codeome, quindi ogni jump trova in avanti la sua target
  prima di qualunque false match.

  ## Conventions

  - `:store` pops slot_idx (top), pops value (second). Per V → slot[S]:
    `push V, push S, store`.
  - `:write_child` pops opcode_int (top), pops child_addr (second).
  - `:sub` pops a (top), pops b (second), pushes `b - a`.
  - `:load` pops slot_idx (top), pushes `slots[slot_idx]`.
  - Slot[0] è usato in due fasi non sovrapposte: prima per N (taglia), poi
    per il contatore di forage. Slot[1] è il contatore del copy loop.

  ## Energy balance (con `eat_amount` di default = 20)

  - Copy loop body cost ~6/iter × 93 iter ≈ 558
  - Allocate(93) + setup + divide ≈ ~20
  - Costo totale per replicazione: ~580
  - Forage per ciclo: 4 op (cost 6.1) + counter ops (~2.5) = 8.6. Eat gain = 20.
    Netto: +11.4 per iter. × 64 = +730 per gen
  - E_new = (E_old − 580) / 2 + 730 = E_old/2 + 440. Steady state ≈ 880.
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

    # ── pos 51: turn_right — esce da dietro al figlio appena nato ────────
    :turn_right,

    # ── pos 52..64: build K=64 on stack ──────────────────────────────────
    # push1 (=1), poi 6 doppiamenti via dup+add: 2, 4, 8, 16, 32, 64
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

    # ── pos 65..66: store K in slot[0] ───────────────────────────────────
    # slot[0] è libero: il prossimo `get_size; push0; store` la sovrascriverà
    :push0,
    :store,

    # ── pos 67..70: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
    :nop_0,
    :nop_1,
    :nop_0,
    :nop_1,

    # ── pos 71..74: forage body — sense, drop result, eat, move ──────────
    :sense_front,
    :drop,
    :eat,
    :move,

    # ── pos 75..80: counter := counter - 1 (slot[0]) ─────────────────────
    :push0,
    :load,
    :push1,
    :sub,
    :push0,
    :store,

    # ── pos 81..87: jnz_t → back to FORAGE_LOOP_HEAD if counter != 0 ─────
    :push0,
    :load,
    :jnz_t,
    :nop_1,
    :nop_0,
    :nop_1,
    :nop_0,

    # ── pos 88..92: jmp_t → back to LOOP_HEAD per ritentare replicazione ─
    :jmp_t,
    :nop_0,
    :nop_0,
    :nop_0,
    :nop_0
  ]

  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(@opcodes)

  @doc "Returns the raw opcode list (useful for debugging)."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes
end
