defmodule Lenies.Codeomes.MinimalReplicator do
  @moduledoc """
  Codeome scritto a mano per la replicazione emergente. Raggiunge >=3 generazioni.

  ## Algoritmo

  1. Get own size N, store in slot[0]
  2. Allocate a child slot of size N (in front cell)
  3. If allocate failed, jump to ABORT_TARGET (forage and loop)
  4. Init counter slot[1] = 0
  5. COPY_LOOP: read opcode at counter, write to child at counter; increment counter
  6. When counter == N, exit loop → divide
  7. After divide (or after abort): forage (eat, move), then jump back to LOOP_HEAD

  ## Template anchors (3-bit, Tierra-style)

  Anchor = the complement nops embedded in the code.
  Jump instruction = followed by the template (complement-of-anchor nops).

  | Label           | Anchor (nops in code) | Jump template       |
  |-----------------|------------------------|---------------------|
  | LOOP_HEAD       | nop_1 nop_1 nop_1      | nop_0 nop_0 nop_0   |
  | COPY_LOOP_HEAD  | nop_1 nop_0 nop_1      | nop_0 nop_1 nop_0   |
  | ABORT_TARGET    | nop_0 nop_1 nop_0      | nop_1 nop_0 nop_1   |

  ## Collision-free design

  We avoid placing nops next to each other that could accidentally match a template.
  Non-nop opcodes between anchor sequences break any accidental template chain.

  ## Stack conventions

  - :store pops slot_idx (top), pops value (second): to store V in slot S: push V, push S, store
  - :write_child pops opcode_int (top), pops child_addr (second)
  - :sub pops a (top), pops b (second), pushes b - a
  - :load pops slot_idx (top), pushes slots[slot_idx]

  ## Layout

  pos  0..2   LOOP_HEAD anchor: nop_1 nop_1 nop_1
               (non-nop barrier before next block)
  pos  3      get_size  stack=[N]
  pos  4      push0     stack=[N, 0]
  pos  5      store     slot[0]=N; stack=[]

  pos  6      push0     stack=[0]
  pos  7      load      stack=[N]
  pos  8      allocate  wait; stack=[1 success | 0 fail]

  pos  9      jz_t      jump to ABORT if allocate=0
  pos 10      nop_1     template=nop_1 nop_0 nop_1 (-> finds ABORT_TARGET anchor: nop_0 nop_1 nop_0)
  pos 11      nop_0
  pos 12      nop_1

  pos 13      push0     init counter
  pos 14      push1
  pos 15      store     slot[1]=0

  pos 16..18  COPY_LOOP_HEAD anchor: nop_1 nop_0 nop_1
               (barrier: non-nop before)

  pos 19      push1     load counter
  pos 20      load      stack=[counter]
  pos 21      read_self stack=[opcode_int]

  pos 22      push1     load counter again for child_addr
  pos 23      load      stack=[opcode_int, counter]
  pos 24      swap      stack=[counter, opcode_int]  (opcode on top for write_child)
  pos 25      write_child  pops opcode_int, pops counter; pushes 1/0
  pos 26      drop      stack=[]

  pos 27      push1     increment counter
  pos 28      load      stack=[counter]
  pos 29      push1     stack=[counter, 1]
  pos 30      add       stack=[counter+1]
  pos 31      push1     stack=[counter+1, 1]
  pos 32      store     slot[1]=counter+1; stack=[]

  pos 33      push0     loop condition
  pos 34      load      stack=[N]
  pos 35      push1
  pos 36      load      stack=[N, counter+1]
  pos 37      sub       stack=[N - (counter+1)]
  pos 38      jnz_t     if nonzero, jump back to COPY_LOOP_HEAD
  pos 39      nop_0     template=nop_0 nop_1 nop_0 (-> finds COPY_LOOP_HEAD anchor: nop_1 nop_0 nop_1)
  pos 40      nop_1
  pos 41      nop_0

  pos 42      divide    spawn child

  pos 43..45  ABORT_TARGET anchor: nop_0 nop_1 nop_0
               (also the landing zone after jz_t fails allocate)
               NOTE: after divide, IP falls through to here → that's fine, these are nops

  pos 46      sense_front   forage
  pos 47      drop
  pos 48      eat
  pos 49      move
  pos 50      jmp_t     jump back to LOOP_HEAD
  pos 51      nop_0     template=nop_0 nop_0 nop_0 (-> finds LOOP_HEAD anchor: nop_1 nop_1 nop_1)
  pos 52      nop_0
  pos 53      nop_0

  Total: 54 opcodes

  ## Collision check

  Templates and anchors:
  - jmp_t at 50, template=[nop_0,nop_0,nop_0] at 51-53. Complement=[nop_1,nop_1,nop_1].
    Forward search from 51: checks 51(nop_0),52(nop_0),53(nop_0),wrap→0(nop_1)...
    Position 0-2 is [nop_1,nop_1,nop_1]. Hits at pos 0. ✓ IP=0+3=3.

  - jnz_t at 38, template=[nop_0,nop_1,nop_0] at 39-41. Complement=[nop_1,nop_0,nop_1].
    Forward search from 39: checks 39(nop_0),40(nop_1),41(nop_0),42(divide-not-nop)...
    pos 39-41 = [nop_0,nop_1,nop_0] — that's the TEMPLATE itself, not the complement.
    Keeps going: 42=divide(not nop), 43=nop_0, 44=nop_1, 45=nop_0 — that's [nop_0,nop_1,nop_0]
    again (the ABORT_TARGET anchor which equals the template, not complement).
    Keeps going to 46=sense_front(not nop)...
    Then wraps: 0=nop_1, 1=nop_1, 2=nop_1 — not a match for [nop_1,nop_0,nop_1].
    pos 3=get_size(not nop)...
    pos 16=nop_1, 17=nop_0, 18=nop_1 — YES! That's [nop_1,nop_0,nop_1]. ✓ IP=16+3=19.

    Wait, forward search from 39 wraps around and hits 16. Distance: from 39 to 54
    (end) = 15 steps, then 0..16 = 16 more steps → 31 steps total. Within 256. ✓

    But does it hit any false match first? Let's check all positions containing nop_1:
    - pos 0,1,2: [nop_1,nop_1,nop_1] — not [nop_1,nop_0,nop_1] ✗
    - pos 10,11,12: [nop_1,nop_0,nop_1] — but forward search from 39 goes 39→53 then
      wraps 0→16 → hits pos 0 first (nop_1 but not matching [nop_1,nop_0,nop_1])
      then pos 10: [nop_1,nop_0,nop_1] — YES, this is a FALSE MATCH at pos 10!
      IP would land at 10+3=13. That's wrong!

  PROBLEM: jnz_t template [nop_0,nop_1,nop_0] has complement [nop_1,nop_0,nop_1].
  The jz_t at pos 9 has template [nop_1,nop_0,nop_1] at pos 10-12.
  Those template nops at 10-12 ARE [nop_1,nop_0,nop_1] = the complement we seek!
  So the jnz_t backward/forward search would find pos 10 before pos 16!

  FIX: Use a different template for jnz_t that doesn't clash with jz_t's template nops.
  """

  alias Lenies.Codeome

  # This first definition had a collision; see below for the fixed version.
  # We use different template/anchor assignments that don't overlap with any
  # other nop sequences in the code.
  #
  # REVISED TEMPLATE ASSIGNMENTS:
  #
  # | Label           | Anchor (nops in code) | Jump template       |
  # |-----------------|------------------------|---------------------|
  # | LOOP_HEAD       | nop_1 nop_1 nop_1      | nop_0 nop_0 nop_0   |
  # | COPY_LOOP_HEAD  | nop_0 nop_1 nop_1      | nop_1 nop_0 nop_0   |
  # | ABORT_TARGET    | nop_1 nop_0 nop_0      | nop_0 nop_1 nop_1   |
  #
  # Collision analysis with revised layout:
  #
  # jz_t at pos 9, template=[nop_0,nop_1,nop_1] at pos 10-12.
  #   Complement=[nop_1,nop_0,nop_0]. Searches forward from pos 10.
  #   Only nop sequences ahead (before hitting non-nop):
  #   pos 10-12=[nop_0,nop_1,nop_1] - that's the template, not complement.
  #   pos 13=push0(non-nop). Then wraps and continues.
  #   COPY_LOOP_HEAD anchor at pos 16-18=[nop_0,nop_1,nop_1].
  #   Wait - that's also [nop_0,nop_1,nop_1] not the complement [nop_1,nop_0,nop_0]. OK.
  #   ABORT_TARGET anchor at pos 43-45=[nop_1,nop_0,nop_0]. ← This IS the complement!
  #   Distance from pos 10: forward 10→53=43 steps, then 43-10=33 steps → hits 43. ✓
  #   Does it hit any false [nop_1,nop_0,nop_0] first?
  #   - pos 0-2=[nop_1,nop_1,nop_1]: not a match. pos 3=get_size(non-nop).
  #   - No other [nop_1,nop_0,nop_0] sequence before pos 43 in the revised code. ✓
  #
  # jnz_t at pos 38, template=[nop_1,nop_0,nop_0] at pos 39-41.
  #   Complement=[nop_0,nop_1,nop_1]. Searches forward from pos 39.
  #   pos 39-41=[nop_1,nop_0,nop_0] — template nops (not complement).
  #   pos 42=divide(non-nop). pos 43-45=[nop_1,nop_0,nop_0] — template nops again.
  #   pos 46=sense_front(non-nop). pos 47-50=[nop_0,nop_0,nop_0,jmp_t]: pos 47 is nop_0
  #   but [nop_0,nop_0,...] is not [nop_0,nop_1,nop_1]. Then wraps.
  #   After wrap: pos 0-2=[nop_1,nop_1,nop_1] — not the complement.
  #   pos 3=get_size. pos 10-12=[nop_0,nop_1,nop_1] — YES! Complement found at pos 10.
  #   But COPY_LOOP_HEAD anchor is at pos 16-18. False match at pos 10!
  #
  #   The jz_t template nops at 10-12=[nop_0,nop_1,nop_1] are the same as
  #   the COPY_LOOP_HEAD anchor we want to jump to. This is a structural conflict.
  #
  # ROOT CAUSE: We can't avoid having nop sequences that look like other anchors
  # in the template arguments following jump opcodes.
  #
  # SOLUTION: Use 4-bit templates. With 4 bits there are 16 distinct patterns,
  # and it's much easier to avoid accidental matches in a short codeome.
  # OR: Separate the jz_t template from all anchors by using a completely different
  # bit pattern that doesn't appear anywhere else.
  #
  # Let's use 4-bit templates for jump targets, keeping the templates distinct:
  # - LOOP_HEAD anchor:       nop_1 nop_1 nop_1 nop_1  -> jmp  template: nop_0 nop_0 nop_0 nop_0
  # - COPY_LOOP_HEAD anchor:  nop_1 nop_0 nop_0 nop_1  -> jnz  template: nop_0 nop_1 nop_1 nop_0
  # - ABORT_TARGET anchor:    nop_1 nop_1 nop_0 nop_0  -> jz   template: nop_0 nop_0 nop_1 nop_1
  #
  # With 4-bit templates these won't accidentally appear in the 4-nop template args
  # of other jumps (since each jump's template nops are distinct from all anchors).

  @opcodes [
    # ── LOOP_HEAD anchor ──────────────────────────────────────────────────
    # pos 0..3: complement of [nop_0, nop_0, nop_0, nop_0]
    :nop_1,
    :nop_1,
    :nop_1,
    :nop_1,

    # ── PHASE A: get own size N, store in slot[0] ─────────────────────────
    # pos 4: get_size → stack=[N]
    :get_size,
    # pos 5: push0 → stack=[N, 0]
    :push0,
    # pos 6: store → slot[0]=N; stack=[]
    :store,

    # ── PHASE B: allocate child slot of size N ───────────────────────────
    # pos 7: push0 → stack=[0]
    :push0,
    # pos 8: load → stack=[N]
    :load,
    # pos 9: allocate → wait_world; pops N; pushes 1 (ok) or 0 (fail)
    :allocate,

    # ── jz_t: if allocate failed, jump to ABORT_TARGET ───────────────────
    # pos 10: jz_t
    :jz_t,
    # pos 11..14: template=[nop_0, nop_0, nop_1, nop_1]
    # complement=[nop_1, nop_1, nop_0, nop_0] = ABORT_TARGET anchor
    :nop_0,
    :nop_0,
    :nop_1,
    :nop_1,

    # ── init counter: slot[1] = 0 ────────────────────────────────────────
    # pos 15: push0 → stack=[0]
    :push0,
    # pos 16: push1 → stack=[0, 1]
    :push1,
    # pos 17: store → slot[1]=0; stack=[]
    :store,

    # ── COPY_LOOP_HEAD anchor ─────────────────────────────────────────────
    # pos 18..21: complement of [nop_0, nop_1, nop_1, nop_0]
    :nop_1,
    :nop_0,
    :nop_0,
    :nop_1,

    # ── PHASE C: read opcode at counter ──────────────────────────────────
    # pos 22: push1 → stack=[1]
    :push1,
    # pos 23: load → stack=[counter]
    :load,
    # pos 24: read_self → pops counter, pushes opcode_int; stack=[opcode_int]
    :read_self,

    # ── PHASE D: write opcode to child at counter ─────────────────────────
    # pos 25: push1 → stack=[opcode_int, 1]
    :push1,
    # pos 26: load → stack=[opcode_int, counter]
    :load,
    # pos 27: swap → stack=[counter, opcode_int]   (write_child: opcode_int on top)
    :swap,
    # pos 28: write_child → pops opcode_int (top), pops counter; pushes 1 or 0
    :write_child,
    # pos 29: drop → stack=[]
    :drop,

    # ── PHASE E: increment counter ────────────────────────────────────────
    # pos 30: push1
    :push1,
    # pos 31: load → stack=[counter]
    :load,
    # pos 32: push1
    :push1,
    # pos 33: add → stack=[counter+1]
    :add,
    # pos 34: push1
    :push1,
    # pos 35: store → slot[1]=counter+1; stack=[]
    :store,

    # ── PHASE F: loop condition (N - counter+1 != 0?) ────────────────────
    # pos 36: push0
    :push0,
    # pos 37: load → stack=[N]
    :load,
    # pos 38: push1
    :push1,
    # pos 39: load → stack=[N, counter+1]
    :load,
    # pos 40: sub → stack=[N - (counter+1)]
    :sub,
    # pos 41: jnz_t → pops top; if !=0, jump to COPY_LOOP_HEAD
    :jnz_t,
    # pos 42..45: template=[nop_0, nop_1, nop_1, nop_0]
    # complement=[nop_1, nop_0, nop_0, nop_1] = COPY_LOOP_HEAD anchor (pos 18..21)
    :nop_0,
    :nop_1,
    :nop_1,
    :nop_0,

    # ── PHASE G: divide (copy loop done) ─────────────────────────────────
    # pos 46: divide → wait_world; spawns child
    :divide,

    # ── ABORT_TARGET anchor ───────────────────────────────────────────────
    # pos 47..50: complement of [nop_0, nop_0, nop_1, nop_1]
    # Also: after divide, execution falls through these nops (harmless)
    :nop_1,
    :nop_1,
    :nop_0,
    :nop_0,

    # ── PHASE H: forage and loop ─────────────────────────────────────────
    # pos 51: sense_front → wait_world; pushes cell contents
    :sense_front,
    # pos 52: drop → discard sense result
    :drop,
    # pos 53: eat → wait_world; gains energy
    :eat,
    # pos 54: move → wait_world; moves forward
    :move,
    # pos 55: jmp_t → jump back to LOOP_HEAD
    :jmp_t,
    # pos 56..59: template=[nop_0, nop_0, nop_0, nop_0]
    # complement=[nop_1, nop_1, nop_1, nop_1] = LOOP_HEAD anchor (pos 0..3)
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
