# Appendix: Knowledge Base for AI Coding Agents

> Purpose: this is a single self-contained reference designed to bootstrap an AI
> coding agent (Claude, GPT, etc.) into writing valid Lenies codeomes that paste
> directly into the codeome editor. It distils the chapters of the manual into a
> dense, code-heavy reference.
>
> Last updated against source: 2026-05-31 (Elixir 1.19, OTP 28).

---

## 1. The VM in one page

A **codeome** is a fixed-length ring of opcodes executed by a tiny stack VM.
Every Lenie has its own VM state and runs one opcode per tick (modulo
`interpreter_steps_per_batch`).

**Stack.** A single data stack, max depth **16** opcodes. Push beyond the cap
discards the BOTTOM (oldest) element — the top survives. `pop` and `peek` on
an empty stack return **0** (never crash). `dup` pops top then pushes it
twice (net: duplicate). `swap` pops `a` (top) and `b`, pushes `a` then `b`
(net: top and second swap).

**Manual notation.** Stack effects are written `( before -- after )` with
**TOP ON THE RIGHT**. Example: `( b a -- b+a )` means pop `a` (top), pop `b`
(second), push `a+b`. Internally Elixir lists are head=top, but every public
document — including this appendix — uses top-on-right.

**Slots.** A fixed-size scratchpad of **4 integer slots** indexed `0..3`. All
slot accesses do `slot_idx mod 4`, so indices > 3 wrap. Slots start at 0.
- `:store` stack effect `( value slot_idx -- )` — slot_idx is TOP.
- `:load` stack effect `( slot_idx -- value )`.

**Call stack.** Independent of the data stack. Max depth **32**. `:ret` on
an EMPTY call stack does NOT crash; it just advances IP by 1.

**Codeome ring.** Fixed-length list of opcodes. IP is always `mod size`, so
execution wraps from the last opcode back to position 0. Bounds: codeome
length must be in `[5, 1000]` (`codeome_length_bounds`) AND contain at
least **10 non-nop** opcodes (`min_viable_codeome_opcodes`). Codeomes that
violate either bound are rejected at creation.

**Energy.** Every opcode applies a cost (`State.apply_cost`). If energy
`<= 0` after the opcode, the Lenie halts with `:starvation`. Default starting
energy is 500 (editable in the editor spawn form).

**Templates and addressing.** Jumps and calls (`:jmp_t`, `:jz_t`, `:jnz_t`,
`:call_t`) use Tierra-style template matching:
1. The template is the run of `:nop_0`/`:nop_1` IMMEDIATELY AFTER the jump
   opcode (max length **8**, capped by `template_max_len`).
2. The VM bit-flips every nop in that run to produce the **complement**.
3. It searches the codeome — forward from `ip+1` for up to **256** opcodes
   (`template_search_radius`), then backward — for the FIRST run of nops
   that matches the complement exactly.
4. On match: `IP := match_pos + length(template)` — i.e. the IP lands at
   the instruction AFTER the matching nops.
5. On miss (`:not_found`) or empty template (`t_len == 0`): `IP := ip + 1 + t_len`
   — execution falls through past the jump's own template.

**World actions.** Five opcodes interact with the world cell ahead or with the
Lenie's own slot. Each one returns `{:wait_world, …}`; the Lenie process must
then call the World process to resolve the action and get a result. From the
codeome author's perspective, these read as ordinary opcodes; they just take
extra real-world time to resolve.

**`:read_self`.** Reads the codeome by index: pops `addr` (top), pushes the
**opcode integer** (NOT the atom name) at codeome position `addr mod size`,
per the encoding table in §2.

---

## 2. The 38 opcodes — quick reference

The 38 opcodes are indexed 0..37 in the encoding map. Any integer outside
0..37 decodes as `:nop_0` (mutation tolerance).

### Notation in this table

- Stack effect uses TOP ON THE RIGHT.
- `t_len` = length of the template that follows the jump opcode (0..8).
- `size_arg` = the popped `size` for `:allocate`.
- `length` = the popped `length` for `:make_plasmid`.
- `plasmid_size` = number of opcodes in the latest plasmid (for `:conjugate`).

| Int | Opcode | Cost | Stack effect | Notes |
|-----|--------|------|--------------|-------|
| 0 | `:nop_0` | 0.1 | `( -- )` | Template anchor bit 0; no exec effect |
| 1 | `:nop_1` | 0.1 | `( -- )` | Template anchor bit 1; no exec effect |
| 2 | `:push0` | 0.1 | `( -- 0 )` | |
| 3 | `:push1` | 0.1 | `( -- 1 )` | |
| 4 | `:pushN` | 0.1 | `( -- r )` | `r = :rand.uniform(256) - 1`, in 0..255; **NOT deterministic** |
| 5 | `:dup` | 0.1 | `( a -- a a )` | Pops top, pushes twice |
| 6 | `:drop` | 0.1 | `( a -- )` | Discards top |
| 7 | `:swap` | 0.1 | `( b a -- a b )` | Top and second exchange |
| 8 | `:add` | 0.2 | `( b a -- b+a )` | Commutative |
| 9 | `:sub` | 0.2 | `( b a -- b-a )` | **Second minus top** (NOT `a-b`) |
| 10 | `:mul` | 0.2 | `( b a -- b*a )` | Commutative |
| 11 | `:mod` | 0.2 | `( b a -- b mod a )` | If `a == 0`, result is 0 (no crash) |
| 12 | `:jmp_t` | `0.2 + 0.05·t_len` | `( -- )` | Unconditional template jump |
| 13 | `:jz_t` | `0.2 + 0.05·t_len` | `( a -- )` | Jumps iff popped == 0 |
| 14 | `:jnz_t` | `0.2 + 0.05·t_len` | `( a -- )` | Jumps iff popped != 0 |
| 15 | `:call_t` | `0.2 + 0.05·t_len` | `( -- )` | Pushes `ip+1+t_len` onto CALL stack, then jumps |
| 16 | `:ret` | 0.2 | `( -- )` | Pops return_ip from CALL stack; empty → IP+=1 |
| 17 | `:sense_front` | 0.5 | `( -- v )` | World action; pushes sensed value (food count, -1 = Lenie, etc.) |
| 18 | `:sense_self` | 0.5 | `( -- 1 )` | **Always pushes 1**; local, never queries world |
| 19 | `:sense_energy` | 0.5 | `( -- e )` | `trunc(state.energy)` |
| 20 | `:sense_age` | 0.5 | `( -- age )` | Ticks since spawn |
| 21 | `:sense_size` | 0.5 | `( -- n )` | Codeome size |
| 22 | `:move` | 2.0 | `( -- )` | Step forward one cell; world action |
| 23 | `:turn_left` | 0.5 | `( -- )` | Counter-clockwise: n→w→s→e→n |
| 24 | `:turn_right` | 0.5 | `( -- )` | Clockwise: n→e→s→w→n |
| 25 | `:eat` | 2.0 | `( -- )` | Consume `eat_amount` (default 20) from cell |
| 26 | `:attack` | 5.0 | `( -- )` | Damage Lenie in front cell (deals 10, costs 5) |
| 27 | `:defend` | 2.0 | `( -- )` | Activate defense for `defense_window_ticks=5`; attackers lose 5 |
| 28 | `:get_ip` | 0.3 | `( -- ip )` | Current instruction pointer |
| 29 | `:get_size` | 0.3 | `( -- n )` | Codeome size (cheaper than `:sense_size`) |
| 30 | `:read_self` | 0.3 | `( addr -- opcode_int )` | Returns the INTEGER encoding (per this table), not the atom |
| 31 | `:allocate` | `5.0 + 0.05·size_arg` | `( size_arg -- )` | Allocate child slot of size in front cell |
| 32 | `:write_child` | 1.0 | `( child_addr opcode_int -- )` | `opcode_int` is TOP |
| 33 | `:divide` | 10.0 | `( -- )` | Commit child as new Lenie |
| 34 | `:store` | 0.5 | `( value slot_idx -- )` | `slot_idx` is TOP |
| 35 | `:load` | 0.5 | `( slot_idx -- value )` | |
| 36 | `:make_plasmid` | `2.0 + 0.05·length` | `( start_addr length -- ok? )` | Pushes 1 on success, 0 on fail |
| 37 | `:conjugate` | `4.0 + 0.05·plasmid_size` | `( -- ok? )` | Push 1 if a neighbor accepted the plasmid, else 0 |

**Empty-pop rule.** Any opcode that pops with nothing on the stack reads `0`.
So `:add` on `[]` becomes `0 + 0 = 0` (result pushed), `:store` with one
operand stores using slot_idx=top=that operand and value=0, etc.

**Tolerance.** Unknown opcode integers decode as `:nop_0`. Out-of-bounds
codeome reads in `:read_self` use `addr mod size`.

---

## 3. Cost cheat sheet

Per-opcode cost (in energy units) is applied before checking for starvation.
Constant costs first, then parameterized.

### Constant costs

| Cost | Opcodes |
|------|---------|
| 0.1 | `:nop_0`, `:nop_1`, `:push0`, `:push1`, `:pushN`, `:dup`, `:drop`, `:swap` |
| 0.2 | `:add`, `:sub`, `:mul`, `:mod`, `:ret` |
| 0.3 | `:get_ip`, `:get_size`, `:read_self` |
| 0.5 | `:sense_*` (all five), `:turn_left`, `:turn_right`, `:store`, `:load` |
| 1.0 | `:write_child` |
| 2.0 | `:move`, `:eat`, `:defend` |
| 5.0 | `:attack` |
| 10.0 | `:divide` |

### Parameterized costs

| Opcode | Formula | Example |
|--------|---------|---------|
| `:jmp_t`, `:jz_t`, `:jnz_t`, `:call_t` | `0.2 + 0.05 × t_len` | Empty template: 0.20. 4-nop template: 0.40. 8-nop template (cap): 0.60. |
| `:allocate` | `5.0 + 0.05 × size_arg` | `size_arg=10` → 5.50. `size_arg=123` → 11.15. `size_arg=1000` (max codeome) → 55.0. |
| `:make_plasmid` | `2.0 + 0.05 × length` | `length=20` → 3.00. `length=100` → 7.00. |
| `:conjugate` | `4.0 + 0.05 × plasmid_size` | Latest plasmid 30 ops → 5.50. No plasmid → just 4.00 (returns 0). |

### Quick replication budget

Copy loop body (per source opcode copied) ≈ 6.8 energy units in the canonical
MR replicator: `push1, load, read_self, push1, load, swap, write_child, drop`
plus the per-iter counter ops. For a 123-opcode codeome:

- Allocate(123): `5.0 + 0.05 × 123 = 11.15`
- Copy loop: `123 × 6.8 ≈ 836`
- Divide: `10.0`
- Setup + final wrap: a handful more
- **Total per division: ~885 energy** (matches MR's annotation)

---

## 4. Template addressing — the canonical idiom

A template is the run of `:nop_0`/`:nop_1` immediately AFTER a jump opcode.
The VM bit-flips each nop in that run to compute the **complement**, then
searches the codeome for the FIRST matching run.

**Search order:** forward from `ip+1` up to radius 256, then backward
(non-toroidal); on miss IP becomes `ip + 1 + t_len` (fall through).

**Landing IP on match:** `match_pos + length(template)` — IP lands at the
instruction AFTER the matching nops (NOT at the start of the match).

**Worked example (forward jump):**

```
pos  0: :jmp_t          # jump opcode
pos  1: :nop_0          # template[0]
pos  2: :nop_1          # template[1]; template = [n0, n1], complement = [n1, n0]
pos  3: :push1          # instruction after template (would execute on fall-through)
pos  4: :nop_1          # complement[0]; match starts here
pos  5: :nop_0          # complement[1]; match ends here
pos  6: :sense_front    # IP lands HERE (= 4 + 2 = 6)
```

Cost: `0.2 + 0.05 × 2 = 0.30` for the `:jmp_t`.

**Separator rule.** If you place an anchor (a nop run) immediately after a
template's nop run, the template extractor reads PAST your intended template
boundary and absorbs both runs (up to `template_max_len = 8`). Always insert
a non-nop opcode (`:push0; :drop` is the canonical idiom, or any safe non-nop)
between them. The MR replicator does this twice (pos 67 and 122); the
Defender, Forager, Hunter, and plasmids all need the same separator wherever
two nop runs would adjoin — INCLUDING across the codeome-ring wrap.

---

## 5. Hand-written reference codeomes

The seven codeomes below are the canonical hand-tuned examples shipped with
Lenies. Quote them directly when starting a new codeome — they already
encode the conventions (separators, anchor patterns, K-construction tricks,
slot-overwrite phasing) that an AI agent would otherwise have to rediscover.

### 5.1 Walker (`lib/lenies/codeomes/walker.ex`)

The simplest non-trivial codeome: 7 opcodes, no replication, no slots, no
arithmetic. The Walker is a degenerate herbivore that sits on a single cell
trying to eat then moves forward, looping forever via a 1-nop template.

The template is `[:nop_0]` and the complement `[:nop_1]` sits at position 0;
on each jump the IP lands at `0 + 1 = 1` (the `:sense_front`), so the entire
loop body cycles. It does NOT replicate — use it only as a smoke test that
the editor accepts your input and the Lenie ticks. It will starve in tens of
ticks because nothing balances energy gain against the move/eat cost in a
sparse world.

```elixir
[
  # 0: complement marker (where :jmp_t will land)
  :nop_1,
  # 1: sense front cell
  :sense_front,
  # 2: discard sense result
  :drop,
  # 3: eat current cell
  :eat,
  # 4: try to move forward
  :move,
  # 5: jump
  :jmp_t,
  # 6: template (complement = :nop_1 at position 0)
  :nop_0
]
```

### 5.2 Forager (`lib/lenies/codeomes/forager.ex`)

A wandering herbivore. Built as `MinimalReplicator.replication_preamble() ++
forage_body` — i.e. the 52-opcode MR replication preamble (pos 0..51)
followed by the forage code below. Total length: 139 opcodes.

Strategy: each forage iter does `:eat`, `:move`, then computes
`pushN mod 3` to randomly turn left, turn right, or not turn at all. The
direction performs a random walk on `{N, E, S, W}`, so the position drifts
as a 2D random walk and fills space rather than tracing straight lines.
K=128 forage iters per replication. Sustainable at default `eat_amount=20`.

```elixir
# Forage body (appended to MinimalReplicator.replication_preamble() above)
[
  # ── pos 52..65: build K=128 (push1 + 7×(dup,add)) ────────────────────
  :push1,
  :dup, :add, :dup, :add, :dup, :add, :dup, :add,
  :dup, :add, :dup, :add, :dup, :add,

  # ── pos 66..67: K+1 = 129 (decrement-first loop overshoots by 1) ────
  :push1,
  :add,

  # ── pos 68..69: store K+1 in slot[0] ─────────────────────────────────
  :push0,
  :store,

  # ── pos 70..73: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
  :nop_0,
  :nop_1,
  :nop_0,
  :nop_1,

  # ── pos 74..79: decrement slot[0] ────────────────────────────────────
  :push0,
  :load,
  :push1,
  :sub,
  :push0,
  :store,

  # ── pos 80..81: load slot[0] for exit check ──────────────────────────
  :push0,
  :load,

  # ── pos 82..86: jz_t LOOP_HEAD (template [n0,n0,n0,n0]) — exit forage ─
  :jz_t,
  :nop_0,
  :nop_0,
  :nop_0,
  :nop_0,

  # ── pos 87..88: forage body — eat, move ──────────────────────────────
  :eat,
  :move,

  # ── pos 89..95: pushN; build 3; mod (pushN mod 3) ────────────────────
  :pushN,
  :push1,
  :push1,
  :push1,
  :add,
  :add,
  :mod,

  # ── pos 96: dup the result ───────────────────────────────────────────
  :dup,

  # ── pos 97..101: jz_t NO_TURN_BR (template [n1,n1,n1,n0]) ───────────
  :jz_t,
  :nop_1,
  :nop_1,
  :nop_1,
  :nop_0,

  # ── pos 102..103: val - 1 (val was 1 or 2) ───────────────────────────
  :push1,
  :sub,

  # ── pos 104..108: jz_t TURN_LEFT_BR (template [n1,n0,n0,n0]) ────────
  :jz_t,
  :nop_1,
  :nop_0,
  :nop_0,
  :nop_0,

  # ── pos 109: turn_right (val was 2) ──────────────────────────────────
  :turn_right,

  # ── pos 110..114: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ───
  :jmp_t,
  :nop_1,
  :nop_0,
  :nop_1,
  :nop_0,

  # ── pos 115: separator (prevents 8-consecutive-nop misread) ──────────
  :push0,

  # ── pos 116..119: NO_TURN_BR anchor [n0, n0, n0, n1] ─────────────────
  :nop_0,
  :nop_0,
  :nop_0,
  :nop_1,

  # ── pos 120: drop remaining val (= 0) ────────────────────────────────
  :drop,

  # ── pos 121..125: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ───
  :jmp_t,
  :nop_1,
  :nop_0,
  :nop_1,
  :nop_0,

  # ── pos 126: separator ───────────────────────────────────────────────
  :push0,

  # ── pos 127..130: TURN_LEFT_BR anchor [n0, n1, n1, n1] ──────────────
  :nop_0,
  :nop_1,
  :nop_1,
  :nop_1,

  # ── pos 131: turn_left ───────────────────────────────────────────────
  :turn_left,

  # ── pos 132..136: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ───
  :jmp_t,
  :nop_1,
  :nop_0,
  :nop_1,
  :nop_0,

  # ── pos 137: separator (final wrap protection) ───────────────────────
  :push0
]
```

### 5.3 TemplateJumper (`lib/lenies/codeomes/template_jumper.ex`)

A diagnostic codeome that verifies template addressing actually works. Sets
`slot[0] = 1` on jump-success and `slot[0] = 2` on fall-through. Use it as a
testbed when an AI agent is unsure whether a template will land correctly.

```elixir
[
  # pre
  :push0,             # 0
  :push0,             # 1
  :store,             # 2  slot[0] = 0
  :jmp_t,             # 3  jump opcode
  :nop_0,             # 4  template[0]
  :nop_1,             # 5  template[1] → template = [:nop_0, :nop_1]

  # fail path (executes only if no match is found)
  :push1,             # 6
  :dup,               # 7
  :add,               # 8
  :push0,             # 9
  :store,             # 10 slot[0] = 2 (proves jump fell through)
  :nop_0,             # 11 filler
  :nop_0,             # 12 filler

  # success path (jump target)
  :nop_1,             # 13 complement[0]
  :nop_0,             # 14 complement[1] → match starts at 13; IP lands at 15
  :push1,             # 15
  :push0,             # 16
  :store,             # 17 slot[0] = 1 (proves jump succeeded)

  # spin tail
  :nop_0,             # 18
  :nop_0,             # 19
  :nop_0              # 20
]
```

### 5.4 Hunter (`lib/lenies/codeomes/hunter.ex`)

A predator with a diagonal staircase advance and lock-on attack. Built as
`MinimalReplicator.replication_preamble() ++ forage_body`. Total length:
164 opcodes.

Strategy: on each forage iter `:sense_front`. If the cell ahead contains a
Lenie (sensed value `-1`), jump to LENIE_HANDLER and `:attack` once — no
move, no turn. Next iter faces the same cell; if prey is still there, attack
again. This "lock-on" amplifies kill probability without explicit pursuit
logic. Otherwise `:eat` + `:move`, then alternate `:turn_right`/`:turn_left`
via `slot[3]` parity, producing a deterministic diagonal staircase pattern
distinct from MR's straight-line runs and Forager's random walk.

K=96 forage iters per replication (built as 32+64 instead of doubling chain
to K=128). Sustainable at default `eat_amount=20`.

```elixir
# Forage body (appended to MinimalReplicator.replication_preamble())
[
  # ── pos 52..66: build K=96 = 32 + 64 ────────────────────────────────
  # Phase 1 (11 ops): push1 + 5×(dup, add) → stack=[32]
  # Phase 2 (4 ops):  dup→[32,32]; dup→[32,32,32]; add→[32,64]; add→[96]
  :push1,
  :dup, :add, :dup, :add, :dup, :add, :dup, :add, :dup, :add,
  :dup, :dup, :add, :add,

  # ── pos 67..68: K+1 = 97 ─────────────────────────────────────────────
  :push1,
  :add,

  # ── pos 69..70: store K+1 in slot[0] ─────────────────────────────────
  :push0,
  :store,

  # ── pos 71..77: init slot[3] := 0 ────────────────────────────────────
  # push0 [0]; push1+push1+push1 [0,1,1,1]; add [0,1,2]; add [0,3]; store
  :push0,
  :push1, :push1, :push1,
  :add, :add,
  :store,

  # ── pos 78..81: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
  :nop_0, :nop_1, :nop_0, :nop_1,

  # ── pos 82..87: decrement slot[0] ────────────────────────────────────
  :push0, :load,
  :push1, :sub,
  :push0, :store,

  # ── pos 88..89: load slot[0] for exit check ──────────────────────────
  :push0, :load,

  # ── pos 90..94: jz_t LOOP_HEAD (template [n0,n0,n0,n0]) — exit ──────
  :jz_t,
  :nop_0, :nop_0, :nop_0, :nop_0,

  # ── pos 95..97: sense_front; push1; add — value+1 ────────────────────
  :sense_front,
  :push1,
  :add,

  # ── pos 98..102: jz_t LENIE_HANDLER (template [n1,n1,n1,n0]) ────────
  # Pops value+1. If was -1 (now 0) → jump to LENIE_HANDLER.
  :jz_t,
  :nop_1, :nop_1, :nop_1, :nop_0,

  # ── pos 103..104: not prey — eat, move ───────────────────────────────
  :eat,
  :move,

  # ── pos 105..110: build slot idx 3 and load slot[3] ──────────────────
  :push1, :push1, :push1,
  :add, :add,
  :load,

  # ── pos 111..112: counter + 1 ────────────────────────────────────────
  :push1,
  :add,

  # ── pos 113: dup (value needed for parity check AND for storing) ─────
  :dup,

  # ── pos 114..116: build 2 on stack ───────────────────────────────────
  :push1, :push1,
  :add,

  # ── pos 117: mod — (counter+1) mod 2 ─────────────────────────────────
  :mod,

  # ── pos 118..122: jz_t TURN_LEFT_BR (template [n1,n0,n0,n0]) ────────
  :jz_t,
  :nop_1, :nop_0, :nop_0, :nop_0,

  # ── pos 123: turn_right (mod was 1) ──────────────────────────────────
  :turn_right,

  # ── pos 124..129: store counter+1 → slot[3] ──────────────────────────
  :push1, :push1, :push1,
  :add, :add,
  :store,

  # ── pos 130..134: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
  :jmp_t,
  :nop_1, :nop_0, :nop_1, :nop_0,

  # ── pos 135: separator ───────────────────────────────────────────────
  :push0,

  # ── pos 136..139: LENIE_HANDLER anchor [n0, n0, n0, n1] ─────────────
  :nop_0, :nop_0, :nop_0, :nop_1,

  # ── pos 140: attack (no move, no turn — lock on) ─────────────────────
  :attack,

  # ── pos 141..145: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
  :jmp_t,
  :nop_1, :nop_0, :nop_1, :nop_0,

  # ── pos 146: separator ───────────────────────────────────────────────
  :push0,

  # ── pos 147..150: TURN_LEFT_BR anchor [n0, n1, n1, n1] ──────────────
  :nop_0, :nop_1, :nop_1, :nop_1,

  # ── pos 151: turn_left ───────────────────────────────────────────────
  :turn_left,

  # ── pos 152..157: store counter+1 → slot[3] ──────────────────────────
  :push1, :push1, :push1,
  :add, :add,
  :store,

  # ── pos 158..162: jmp_t FORAGE_LOOP_HEAD ─────────────────────────────
  :jmp_t,
  :nop_1, :nop_0, :nop_1, :nop_0,

  # ── pos 163: separator (final wrap protection) ───────────────────────
  :push0
]
```

### 5.5 Carnivore (`lib/lenies/codeomes/carnivore.ex`)

A predatory variant of MR built by patching the base codeome: inject
`:attack` immediately before the first `:eat`, then append a "Sprint"
plasmid (12 opcodes) that adds an extra `:move, :eat` per forage iter.

The Carnivore module's `codeome/0` does the patching at compile time —
when writing an AI-generated Carnivore variant, copy the full MR base
opcodes (§5.7), inject `:attack` before `:eat`, then append the plasmid:

```elixir
# The Sprint plasmid (appended to a modified MR base)
[
  # ── pos 0..3: INTERCEPT_ANCHOR = FORAGE_LOOP_HEAD pattern [n0,n1,n0,n1] ──
  :nop_0,
  :nop_1,
  :nop_0,
  :nop_1,

  # ── pos 4..5: extra step + extra eat (sprint) ────────────────────────
  :move,
  :eat,

  # ── pos 6..10: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ───────
  :jmp_t,
  :nop_1,
  :nop_0,
  :nop_1,
  :nop_0,

  # ── pos 11: trailing separator (CRITICAL) ───────────────────────────
  # Without this non-nop, the final jmp_t template merges with the host's
  # LOOP_HEAD nops across the codeome-ring wrap (8 nops read instead of
  # 4), so the bounce-back lands in replication setup instead of
  # FORAGE_LOOP_HEAD and the host starves in place.
  :push0
]
```

The intercept works because the plasmid's INTERCEPT_ANCHOR matches the
host's FORAGE_LOOP_HEAD template — when the host jumps to FORAGE_LOOP_HEAD,
the search finds the plasmid anchor first (it's appended later in the
codeome ring), and executes the plasmid body before bouncing back.

### 5.6 Defender (`lib/lenies/codeomes/defender.ex`)

A defensive herbivore that builds tight clusters. Replicates often (K=32),
defends every forage iteration, and uses a deterministic post-divide
`:turn_left` (inherited from the preamble; no random branch). Total length:
93 opcodes.

Strategy: short forage runs (~32 cells before each replication) combined
with the deterministic 90° turn after every divide → descendants spiral
outward in a rotating pattern, forming tight clusters. Margin is tighter
than Hunter/Forager (~+50 steady state) because of the short K — reducing
K further would push toward starvation.

```elixir
# Forage body (appended to MinimalReplicator.replication_preamble())
[
  # ── pos 52..62: build K=32 on stack (push1 + 5×(dup,add) = 32) ─────
  :push1,
  :dup, :add, :dup, :add, :dup, :add, :dup, :add, :dup, :add,

  # ── pos 63..64: K+1 = 33 (decrement-first loop overshoots by 1) ─────
  :push1,
  :add,

  # ── pos 65..66: store K+1 in slot[0] (forage counter) ────────────────
  :push0,
  :store,

  # ── pos 67..70: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
  :nop_0, :nop_1, :nop_0, :nop_1,

  # ── pos 71..76: decrement slot[0] (slot[0] -= 1) ─────────────────────
  :push0, :load,
  :push1, :sub,
  :push0, :store,

  # ── pos 77..78: load slot[0] for exit check ──────────────────────────
  :push0, :load,

  # ── pos 79..83: jz_t LOOP_HEAD (template [n0,n0,n0,n0]) — exit ──────
  :jz_t,
  :nop_0, :nop_0, :nop_0, :nop_0,

  # ── pos 84..86: forage body — defend, eat, move ──────────────────────
  :defend,
  :eat,
  :move,

  # ── pos 87..91: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ─────
  :jmp_t,
  :nop_1, :nop_0, :nop_1, :nop_0,

  # ── pos 92: separator — prevents template extractor from reading ────
  # 4 nops of the final template + 4 nops of LOOP_HEAD across wrap.
  :push0
]
```

### 5.7 MinimalReplicator (`lib/lenies/codeomes/minimal_replicator.ex`)

The canonical hand-tuned replicator. Replication preamble at positions 0..51
is reused verbatim by Forager, Hunter, and Defender (and any AI-generated
codeome that wants a working replication harness — just append your forage
body starting at position 52). Total base codeome length: 123 opcodes (with
`:conjugate, :drop` in the forage body); 121 without.

Sustainable at default `eat_amount=20` with K=128 forage iters per
replication. Steady state ≈ +805 energy per generation cycle.

```elixir
[
  # ── pos 0..3: LOOP_HEAD anchor [n1, n1, n1, n1] ──────────────────────
  :nop_1, :nop_1, :nop_1, :nop_1,

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
  :nop_0, :nop_0, :nop_1, :nop_1,

  # ── pos 15..17: init copy counter slot[1] = 0 ────────────────────────
  :push0,
  :push1,
  :store,

  # ── pos 18..21: COPY_LOOP_HEAD anchor [n1, n0, n0, n1] ───────────────
  :nop_1, :nop_0, :nop_0, :nop_1,

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
  :push1, :load,
  :push1, :add,
  :push1, :store,

  # ── pos 36..40: loop condition (N - (counter+1) != 0?) ───────────────
  :push0, :load,
  :push1, :load,
  :sub,

  # ── pos 41..45: jnz_t → back to COPY_LOOP_HEAD if not done ───────────
  :jnz_t,
  :nop_0, :nop_1, :nop_1, :nop_0,

  # ── pos 46: divide ───────────────────────────────────────────────────
  :divide,

  # ── pos 47..50: ABORT_TARGET anchor [n1, n1, n0, n0] ─────────────────
  # Landing pad for both jz_t (allocate failed) and fall-through after divide.
  :nop_1, :nop_1, :nop_0, :nop_0,

  # ── pos 51..55: r := pushN; stack ← (r mod 2) ────────────────────────
  :pushN,
  :push1, :push1, :add,
  :mod,

  # ── pos 56..60: jz_t → if 0, jump to TURN_LEFT_ANCHOR ────────────────
  :jz_t,
  :nop_1, :nop_0, :nop_1, :nop_1,

  # ── pos 61: turn_right (executed when r mod 2 == 1) ─────────────────
  :turn_right,

  # ── pos 62..66: jmp_t → skip turn_left branch ────────────────────────
  :jmp_t,
  :nop_1, :nop_1, :nop_0, :nop_1,

  # ── pos 67: separator (dead code, never executed) ────────────────────
  :push0,

  # ── pos 68..71: TURN_LEFT_ANCHOR [n0, n1, n0, n0] ────────────────────
  :nop_0, :nop_1, :nop_0, :nop_0,

  # ── pos 72: turn_left (executed when r mod 2 == 0) ──────────────────
  :turn_left,

  # ── pos 73..76: SKIP_TURN_ANCHOR [n0, n0, n1, n0] ────────────────────
  :nop_0, :nop_0, :nop_1, :nop_0,

  # ── pos 77..91: build K=128 on stack ─────────────────────────────────
  :push1,
  :dup, :add, :dup, :add, :dup, :add, :dup, :add,
  :dup, :add, :dup, :add, :dup, :add,

  # ── pos 92..93: store K in slot[0] ───────────────────────────────────
  :push0,
  :store,

  # ── pos 94..97: FORAGE_LOOP_HEAD anchor [n0, n1, n0, n1] ─────────────
  :nop_0, :nop_1, :nop_0, :nop_1,

  # ── pos 98..101: forage body — sense, drop result, eat, move ─────────
  :sense_front,
  :drop,
  :eat,
  :move,

  # ── pos 102..103: try to infect a neighbor; drop the result ─────────
  :conjugate,
  :drop,

  # ── pos 104..109: counter := counter - 1 (slot[0]) ───────────────────
  :push0, :load,
  :push1, :sub,
  :push0, :store,

  # ── pos 110..111: load counter for check ─────────────────────────────
  :push0,
  :load,

  # ── pos 112..116: jnz_t → back to FORAGE_LOOP_HEAD if counter != 0 ───
  :jnz_t,
  :nop_1, :nop_0, :nop_1, :nop_0,

  # ── pos 117..121: jmp_t → back to LOOP_HEAD to retry replication ─────
  :jmp_t,
  :nop_0, :nop_0, :nop_0, :nop_0,

  # ── pos 122: separator (dead code, never executed) ───────────────────
  :push0
]
```

---

## 6. Common pitfalls for LLM-generated codeomes

1. **Operand order for `:sub`.** `:sub` computes `second - top`, NOT
   `top - second`. To compute `a - b` where `a` is in a slot:
   - WRONG: `push b, push a, sub` → pushes `b - a` (sign flipped)
   - RIGHT: `push a, push b, sub` → pushes `a - b` (you wanted)
   The same applies to `:mod`: `:mod` computes `second mod top`.

2. **Operand order for `:store`.** Slot index is TOP. To store `V` into
   slot `S`:
   - WRONG: `push S, push V, store` → stores `S` into slot `V` (and crashes
     in the editor if `V` is bizarre; otherwise silently corrupts data)
   - RIGHT: `push V, push S, store`

3. **Operand order for `:write_child`.** `opcode_int` is TOP,
   `child_addr` is second.
   - WRONG: `push opcode_int, push child_addr, write_child`
   - RIGHT: `push child_addr, push opcode_int, write_child`
   The MR replicator uses `swap` between two `:load` calls (pos 25..28) to
   put `opcode_int` on top after pushing it earlier — copy that idiom.

4. **Operand order for `:make_plasmid`.** `length` is TOP, `start_addr`
   is second. Stack effect `( start_addr length -- ok? )`.
   - WRONG: `push length, push start_addr, make_plasmid`
   - RIGHT: `push start_addr, push length, make_plasmid`

5. **Forgetting the separator between anchor and template.** Two adjacent
   nop runs get absorbed by the template extractor (up to 8 nops). This
   includes across the **ring wrap** — if the last opcode of your codeome
   is part of a template's nop run and the first opcode is an anchor's nop
   run, you have an 8-nop misread. Always end the codeome with a non-nop
   (`:push0` is canonical) when a template's nops are at the tail. See MR
   positions 67 and 122; Defender position 92; Hunter positions 135, 146,
   163; Forager positions 115, 126, 137.

6. **Confusing `:turn_left` direction.** `:turn_left` is COUNTER-clockwise
   (n→w→s→e→n). `:turn_right` is CLOCKWISE (n→e→s→w→n). The cycle is the
   same as a clock face viewed from above, with north pointing up.

7. **Thinking `:sense_self` queries the world.** It does NOT. `:sense_self`
   ALWAYS pushes 1 (a hardcoded local sentinel). It's nearly useless
   alone — its primary purpose is letting evolved codeomes test "am I
   still alive?" with zero world cost. To sense the cell ahead of you,
   use `:sense_front`.

8. **Treating empty pop as a crash.** It is NOT. Popping from an empty
   stack returns 0 (and similarly for `:peek`, `:load` on an unwritten
   slot, etc.). `:ret` from an empty call stack does NOT halt either —
   it just advances IP by 1. Plan defensively but don't pre-fill the
   stack "to be safe" — that's extra opcodes for nothing.

9. **Codeome length out of bounds.** The acceptable codeome length range is
   **[5, 1000]** opcodes. Below 5: rejected. Above 1000: rejected. Also
   the codeome must contain at least **10 non-nop** opcodes — a codeome
   of 100 nops will be rejected even though length is in range.

10. **Atom typos.** Use `:nop_0` (with underscore) NOT `:nop0`. Use
    `:push0` (no underscore) NOT `:push_0`. Use `:sense_front` not
    `:senseFront` or `:sense-front`. The Elixir parser will accept
    typos as valid atoms but `Codeome.from_list/1` will raise on any
    atom not in the 38-opcode whitelist.

11. **Pushing non-integers.** All stack values are 64-bit integers. There
    is no `:push_float`. To push a constant `N`:
    - `N = 0`: use `:push0` (1 op, 0.1 cost)
    - `N = 1`: use `:push1` (1 op, 0.1 cost)
    - small `N > 1`: build with combos like `:push1, :dup, :add` (= 2),
      then chains of `:dup, :add` to double. K=128 = 1 + 7 doublings (15 ops);
      K=32 = 1 + 5 doublings (11 ops); K=96 = 32+64 = 1 + 5 doublings + dup,
      dup, add, add (15 ops).
    - `N` in 0..255: `:pushN` returns a uniform random int. Cheap (0.1)
      but non-deterministic.

12. **Calling `:divide` before `:write_child` has written any opcodes.**
    `:divide` will silently fail if the child slot is empty (or if no
    `:allocate` happened first). The canonical sequence is always
    `:allocate → write_child loop → :divide`. The MR replicator
    enforces this via the COPY_LOOP_HEAD anchor at positions 18..21 and
    drops to `:divide` at position 46 only after the copy loop has
    written N opcodes.

13. **Cap awareness in sandbox.** The Sandbox world enforces per-world
    caps: **spawn_cap = 10** (max Lenies spawned via the editor), and
    **replication_cap = 50** (max children per spawned ancestor lineage).
    When the cap is hit, `:divide` returns silently — replication just
    stops. The Arena world overrides both to `:infinity`. AI agents
    should design replicators that remain stable when replication is
    suddenly throttled (the Walker is a good "always stable" template
    since it doesn't replicate at all).

---

## 7. Validation checklist

Before outputting a codeome, mentally run through this list:

1. **All opcode atoms are in the 38-opcode whitelist (no typos).** Use
   the table in §2 as the canonical reference. `Codeome.from_list/1`
   raises `KeyError` on any atom outside the whitelist.

2. **Codeome length is in `[5, 1000]`.** Count the opcodes in your list
   (including all nops and separators). Below 5 or above 1000: rejected
   at creation. The reference codeomes are 7 (Walker), 21 (TemplateJumper),
   93 (Defender), 123 (MR), 139 (Forager), 164 (Hunter).

3. **At least 10 non-nop opcodes** (`min_viable_codeome_opcodes`).
   `:nop_0` and `:nop_1` don't count toward this; everything else does.

4. **Every template has a matching complement somewhere** in the codeome
   (else the jump falls through). The MR replicator's anchor table is a
   good reference set: pick distinct 4-bit anchors for each control-flow
   target, and the matching templates are just the bit-flips.

5. **Every anchor has a separator before its closing complement.** Insert
   `:push0` (or any non-nop) between adjacent nop runs to prevent the
   template extractor from absorbing both. Don't forget the codeome-ring
   wrap — if your last opcode is a template's nop, end the codeome with
   `:push0`.

6. **Replicators: `:allocate → :write_child loop → :divide`** in order.
   Don't `:divide` before the copy loop writes opcodes. Verify the copy
   counter is initialised to 0, incremented inside the loop, and tested
   against `:get_size` (or a stored N) for the exit condition.

7. **Slot indices are valid.** `:store` and `:load` accept any integer,
   but only `0..3` are distinct. Re-using a slot across phases is fine
   (MR does this: slot[0] holds N during replication, then K during
   forage); just make sure the value is fresh when you load it.

8. **Energy budget is sustainable.** For a replicator: per-iter eat gain
   must exceed per-iter cost, and `K × (gain - cost)` must exceed
   replication cost. Default `eat_amount=20` minus per-iter cost
   (~6-13 depending on body) leaves +7 to +14 per iter. K=32 → ~+50
   margin (tight); K=128 → ~+800 margin (comfortable).

---

## 8. Future: JSON import schema (placeholder)

A future Lenies release will support direct JSON import of codeomes via the
collection editor. The schema (TBD) will look approximately like:

```json
{
  "name": "MyCodeome",
  "color_hex": "#ff8800",
  "energy_default": 500.0,
  "opcodes": ["nop_0", "nop_1", "push0", "sense_front", "..."]
}
```

When that feature ships, this section will be updated with the canonical
schema. Until then, AI agents should output codeomes as Elixir atom lists
that the user can paste into the editor by hand.

---

## 9. Where to verify your output

If you have access to the Lenies source, verify your codeome by:

- Calling `Lenies.Codeome.from_list(your_atoms)` (raises on unknown atoms).
- Checking length is in `[5, 1000]` and non-nop count `>= 10`.
- Optionally simulating ticks via `Lenies.Interpreter.step/2`.

In the editor: paste the atoms into the spawn form (the editor accepts the
same atom list syntax via the palette drag-and-drop), give your codeome a
unique name, then click "Spawn". The Lenie will appear in the current world.
If the codeome is invalid, the editor reports the rejection reason in the
flash bar at the top.

For deeper analysis, the seven reference codeomes in §5 all have
`def codeome/0` functions exposed in their respective modules — call them
from `iex -S mix` (e.g. `Lenies.Codeomes.MinimalReplicator.codeome()`) to
see the parsed `%Codeome{}` struct and verify your understanding.
