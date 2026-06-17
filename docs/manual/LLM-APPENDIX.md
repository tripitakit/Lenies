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
discards the BOTTOM (oldest) element — the top survives. Popping an empty
stack returns **0** (never crash). `dup` pops top then pushes it twice
(net: duplicate). `swap` pops `a` (top) and `b`, pushes `a` then `b`
(net: top and second swap).

**Manual notation.** Two display conventions, BOTH with **TOP ON THE RIGHT**:
- Stack-effect notation `( before -- after )` — e.g., `( b a -- b+a )`
  means pop `a` (top), pop `b` (second), push `a+b`.
- Bracket state notation `[a, b, c]` — bottom=`a`, second-from-top=`b`,
  **top=`c`**. Push 5 then 7 onto an empty stack yields `[5, 7]`, not
  `[7, 5]`. (Internally the Elixir source uses head=top lists; the
  appendix and the manual deliberately reverse this for human reading.)

**Slots.** A fixed-size scratchpad of **4 integer slots** indexed `0..3`. All
slot accesses do `slot_idx mod 4`, so indices > 3 wrap. Slots start at 0.
- `:store` stack effect `( value slot_idx -- )` — slot_idx is TOP.
- `:load` stack effect `( slot_idx -- value )`.

**Call stack.** Independent of the data stack. Max depth **32**. `:ret` on
an EMPTY call stack does NOT crash; it just advances IP by 1.

**Codeome ring.** Fixed-length list of opcodes. IP is always `mod size`, so
execution wraps from the last opcode back to position 0. Bounds: codeome
length must be in `[5, 1024]` (`codeome_length_bounds`) AND contain at
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
3. It searches the codeome — forward from `ip+1` for up to **512** opcodes
   (`template_search_radius`), then backward — for the FIRST run of nops
   that matches the complement exactly.
4. On match: `IP := match_pos + length(template)` — i.e. the IP lands at
   the instruction AFTER the matching nops.
5. On miss (`:not_found`) or empty template (`t_len == 0`): `IP := ip + 1 + t_len`
   — execution falls through past the jump's own template.

**World actions.** Nine opcodes interact with the world cell ahead (or with a
neighbor): `:sense_front`, `:move`, `:eat`, `:attack`, `:defend`, `:allocate`,
`:write_child`, `:divide`, `:conjugate`. Each one returns `{:wait_world, …}`;
the Lenie process must then call the World process to resolve the action and
get a result. From the codeome author's perspective, these read as ordinary
opcodes; they just take extra real-world time to resolve.

**`:read_self`.** Reads the **chromosome** by index: pops `addr` (top), pushes
the **opcode integer** (NOT the atom name) at chromosome position `addr mod
chromosome_size`, per the encoding table in §2. It reads the chromosome only —
never a carried plasmid — so a copy loop bounded by `:get_size` replicates the
chromosome exactly.

---

## 2. The 40 opcodes — quick reference

The 40 opcodes are indexed 0..39 in the encoding map. Any integer outside
0..39 decodes as `:nop_0` (mutation tolerance). `:jlt_t`/`:jgt_t` are appended
at indices 38/39 so all earlier encodings are unchanged.

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
| 21 | `:sense_size` | 0.5 | `( -- n )` | Execution-stream size (chromosome + carried plasmids) |
| 22 | `:move` | 2.0 | `( -- )` | Step forward one cell; world action |
| 23 | `:turn_left` | 0.5 | `( -- )` | Counter-clockwise: n→w→s→e→n |
| 24 | `:turn_right` | 0.5 | `( -- )` | Clockwise: n→e→s→w→n |
| 25 | `:eat` | 2.0 | `( -- )` | Empties the cell: gain all resource+detritus, capped per cell at `3×eat_amount`=150 |
| 26 | `:attack` | 5.0 | `( -- )` | Damage Lenie in front cell (deals 10, costs 5) |
| 27 | `:defend` | 2.0 | `( -- )` | Activate defense for `defense_window_ticks=5`; incoming attacks deal half damage (10→5) and the attacker pays an extra `defense_attacker_penalty=5` |
| 28 | `:get_ip` | 0.3 | `( -- ip )` | Current instruction pointer |
| 29 | `:get_size` | 0.3 | `( -- n )` | Chromosome size, excludes plasmids (cheaper than `:sense_size`) |
| 30 | `:read_self` | 0.3 | `( addr -- opcode_int )` | Reads the chromosome only; returns the INTEGER encoding (per this table), not the atom |
| 31 | `:allocate` | `5.0 + 0.05·size_arg` | `( size_arg -- )` | Allocate child slot of size in front cell |
| 32 | `:write_child` | 1.0 | `( child_addr opcode_int -- )` | `opcode_int` is TOP |
| 33 | `:divide` | 10.0 | `( -- )` | Commit child as new Lenie |
| 34 | `:store` | 0.5 | `( value slot_idx -- )` | `slot_idx` is TOP |
| 35 | `:load` | 0.5 | `( slot_idx -- value )` | |
| 36 | `:make_plasmid` | `2.0 + 0.05·length` | `( start_addr length -- ok? )` | Pushes 1 on success, 0 on fail |
| 37 | `:conjugate` | `4.0 + 0.05·plasmid_size` | `( -- ok? )` | Push 1 if a neighbor accepted the plasmid, else 0 |
| 38 | `:jlt_t` | `0.2 + 0.05·t_len` | `( a -- )` | Jumps iff popped < 0 (sign test; compare via `sub` first) |
| 39 | `:jgt_t` | `0.2 + 0.05·t_len` | `( a -- )` | Jumps iff popped > 0 (sign test) |

**Empty-pop rule.** Any opcode that pops with nothing on the stack reads `0`.
So `:add` on `[]` becomes `0 + 0 = 0` (result pushed), `:store` with one
operand stores using slot_idx=top=that operand and value=0, etc.

**Tolerance.** Unknown opcode integers decode as `:nop_0`. Out-of-bounds
chromosome reads in `:read_self` use `addr mod chromosome_size`.

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
| `:allocate` | `5.0 + 0.05 × size_arg` | `size_arg=10` → 5.50. `size_arg=123` → 11.15. `size_arg=1024` (max codeome) → 56.2. |
| `:make_plasmid` | `2.0 + 0.05 × length` | `length=20` → 3.00. `length=100` → 7.00. |
| `:conjugate` | `4.0 + 0.05 × plasmid_size` | Latest plasmid 30 ops → 5.50. No plasmid → just 4.00 (returns 0). |

### Quick replication budget

Copy loop body (per source opcode copied) ≈ 5.0 energy units in the canonical
`Ancestor` replicator: `push0, load, dup, read_self, write_child, drop` plus
the per-iter zero-test and single-slot decrement. For a 100-opcode codeome:

- Allocate(100): `5.0 + 0.05 × 100 = 10.0`
- Copy loop: `100 × 5.0 ≈ 500`
- Divide: `10.0`
- Setup + final wrap: a handful more
- **Total per division: ~524 energy** (matches `Ancestor`'s annotation)

---

## 4. Template addressing — the canonical idiom

A template is the run of `:nop_0`/`:nop_1` immediately AFTER a jump opcode.
The VM bit-flips each nop in that run to compute the **complement**, then
searches the codeome for the FIRST matching run.

**Search order:** forward from `ip+1` up to radius 512, then backward
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
between them. `Ancestor` does this twice (pos 49 and 99); every replicating
codeome and every plasmid needs the same separator wherever two nop runs would
adjoin — INCLUDING across the codeome-ring wrap.

---

## 5. Reference codeomes — the seed ladder

The four codeomes below are the shipped default seeds, designed as a capability
ladder (simple → complex). Each is organized around a *different* computational
principle and a different opcode group — they are not variations of one model.
Quote them when starting a new codeome: they encode the conventions (separators,
distinct-anchor selection, K-construction, single-slot reuse, the call stack,
the HGT pathway) an AI agent would otherwise rediscover.

| Rung | Module | Ops | Signature opcodes | Replicates? |
|------|--------|-----|-------------------|-------------|
| 1 | `reflex.ex` | 49 | `sense_front` as branch predicate | No (mortal) |
| 2 | `ancestor.ex` | 100 | `get_size/allocate/read_self/write_child/divide` | Yes |
| 3 | `architect.ex` | 173 | `call_t`/`ret` (the call stack) | Yes |
| 4 | `symbiont.ex` | 118 | `sense_age` + `make_plasmid` + `conjugate` | Yes |

### 5.1 Reflex (`lib/lenies/codeomes/reflex.ex`)

The simplest seed: a pure sensor→motor reflex. 49 opcodes, no slots, no call
stack, no replication. It reads the cell ahead (`sense_front` pushes `-1` for a
Lenie, `0` for empty, `>0` for food) and three-way-branches: food → `eat;move`,
empty → `move`, Lenie → `turn_right`. Mortal — never divides.

Key idiom: a three-valued sense used directly as a branch predicate, with sign
discrimination via `dup` + `jz_t` + a `+1` trick.

Anchors (4-bit; complement = bit-flip):

| Label | Anchor          | Template        |
|-------|-----------------|-----------------|
| LOOP  | `[n1,n1,n1,n1]` | `[n0,n0,n0,n0]` |
| EMPTY | `[n0,n1,n1,n0]` | `[n1,n0,n0,n1]` |
| AVOID | `[n1,n1,n0,n0]` | `[n0,n0,n1,n1]` |

```elixir
[
  # 0..3 LOOP anchor
  :nop_1, :nop_1, :nop_1, :nop_1,
  # 4..5 sense ahead, duplicate
  :sense_front, :dup,
  # 6..10 jz_t EMPTY (v==0 -> cruise)
  :jz_t, :nop_1, :nop_0, :nop_0, :nop_1,
  # 11..12 v+1 (lenie -1 -> 0; food -> >=2)
  :push1, :add,
  # 13..17 jz_t AVOID (lenie ahead)
  :jz_t, :nop_0, :nop_0, :nop_1, :nop_1,
  # 18..19 food: eat, advance
  :eat, :move,
  # 20..24 jmp_t LOOP
  :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
  # 25 separator
  :push0,
  # 26..29 EMPTY anchor
  :nop_0, :nop_1, :nop_1, :nop_0,
  # 30..31 cruise: drop leftover 0, advance
  :drop, :move,
  # 32..36 jmp_t LOOP
  :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
  # 37 separator
  :push0,
  # 38..41 AVOID anchor
  :nop_1, :nop_1, :nop_0, :nop_0,
  # 42 turn away
  :turn_right,
  # 43..47 jmp_t LOOP
  :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0,
  # 48 separator (wraps into LOOP at 0)
  :push0
]
```

### 5.2 Ancestor (`lib/lenies/codeomes/ancestor.ex`)

The canonical self-replicator. 100 opcodes. Measures self, allocates a child,
copies the chromosome opcode-by-opcode, divides, then forages K=64 to refuel.
Its signature trick is a **single slot used as both the copy counter and the
copy address**: it counts down from `N-1` to `0`, copying high address first.
Deterministic post-divide `turn_right` (no random branch).

Anchors (4-bit, from five distinct complement-pairs → all ten nop windows
distinct):

| Label     | Anchor          | Template        |
|-----------|-----------------|-----------------|
| HEAD      | `[n1,n1,n1,n1]` | `[n0,n0,n0,n0]` |
| COPY      | `[n1,n0,n0,n1]` | `[n0,n1,n1,n0]` |
| REPRODUCE | `[n1,n1,n0,n0]` | `[n0,n0,n1,n1]` |
| ABORT     | `[n1,n0,n1,n0]` | `[n0,n1,n0,n1]` |
| FORAGE    | `[n1,n0,n0,n0]` | `[n0,n1,n1,n1]` |

Structure (positions): `HEAD` 0..3 → save N (4..6) → allocate (7..9) →
`jz_t ABORT` (10..14) → N-1 into slot0 (15..20) → `COPY` 21..24 → copy body
(25..30: `push0,load,dup,read_self,write_child,drop`) → zero-test
`jz_t REPRODUCE` (31..37) → decrement (38..43) → `jmp_t COPY` (44..48) →
separator (49) → `REPRODUCE` 50..53 → `divide,turn_right` (54..55) → `ABORT`
56..59 → build K=64 (60..72) → store (73..74) → `FORAGE` 75..78 →
`jz_t HEAD` exit (79..85) → `eat,move` (86..87) → decrement (88..93) →
`jmp_t FORAGE` (94..98) → separator (99). Allocate-failure guard at `jz_t`
pos 10. Separators at pos 49 and 99.

### 5.3 Architect (`lib/lenies/codeomes/architect.ex`)

The same replicative capability as Ancestor, reorganized as a **structured
program of callable subroutines** via `call_t`/`ret` — the only seed whose call
stack is ever non-empty. 173 opcodes. Because ten labels are needed, it uses
**5-bit templates** (ten anchors `1xxxx` plus ten templates `0..9` as `0xxxx`
= twenty mutually-distinct nop windows, so every jump resolves uniquely).

Shape:

```
MAIN:  call_t FORAGE ; call_t REPLICATE ; jmp_t MAIN
FORAGE: build K ; store ; FLOOP: jz_t FEND ; call_t STEER ; eat ; move ;
        decrement ; jmp_t FLOOP ; FEND: ret      # nested call -> STEER
STEER:  sense_front ; +1 ; jz_t STURN ; ret ; STURN: turn_right ; ret
REPLICATE: allocate ; jz_t RDONE ; copy loop (RCOPY/RDIV) ; divide ;
           turn_right ; RDONE: ret
```

Call depth reaches 2 (`MAIN → FORAGE → STEER`). Ten anchors: `MAIN`(11111),
`FORAGE`(11110), `FLOOP`(11101), `FEND`(11100), `STEER`(11011), `STURN`(11010),
`REPLICATE`(11001), `RCOPY`(11000), `RDIV`(10111), `RDONE`(10110); each
template is the bit-flip. Lesson to quote: `call_t` pushes the return IP and
jumps to the complement; `ret` pops it. A subroutine reached only via `call_t`
always has a frame to pop, so multiple `ret` exits are safe.

### 5.4 Symbiont (`lib/lenies/codeomes/symbiont.ex`)

The adaptive / horizontal-gene-transfer organism. 118 opcodes. It introspects
its own age as a regulatory clock, **mints** a plasmid from its own code with
`make_plasmid`, and **conjugates** it into neighbours conditioned on what it
senses — the only seed that uses `sense_age`, `make_plasmid`, or in-code
`conjugate`.

Life cycle:

```
ENTRY (runs once): push0 ; build 4 ; make_plasmid ; drop   # mint codeome[0..3]
MAIN: sense_age ; build 8 ; mod ; jz_t REPRO                # age % 8 == 0 -> reproduce
SPREAD: sense_front ; +1 ; jz_t INFECT ; eat ; move ; jmp_t MAIN
INFECT: conjugate ; drop ; move ; jmp_t MAIN
REPRO:  allocate ; jz_t MAIN ; copy loop (RCOPY/RDIV) ; divide ; turn_right ; jmp_t MAIN
```

The minted cassette is `codeome[0..3]` = `[push0,push1,dup,add]` — it contains
**no nops**, so it can never hijack an anchor in a recipient; it is a benign,
inherited passenger that demonstrates the transfer pathway (mint → conjugate →
segregate to offspring) without altering recipient behaviour. Anchors (4-bit):
`MAIN`(1111), `REPRO`(1001), `INFECT`(1100), `RCOPY`(1010), `RDIV`(1000).
To build a plasmid that *expresses* in a recipient, see chapter 10 — it must
begin with an anchor matching a per-iteration jump the host performs.

---

## 6. Common pitfalls for LLM-generated codeomes

1. **Operand order for `:sub`.** `:sub` computes `second - top`, NOT
   `top - second`. To compute `a - b` where `a` is in a slot:
   - WRONG: `push b, push a, sub` → pushes `b - a` (sign flipped)
   - RIGHT: `push a, push b, sub` → pushes `a - b` (you wanted)
   The same applies to `:mod`: `:mod` computes `second mod top`.

2. **Operand order for `:store`.** Slot index is TOP. To store `V` into
   slot `S`:
   - WRONG: `push S, push V, store` → stores `S` into slot `V mod 4`
     (never crashes — the slot index wraps mod 4 — but it silently
     corrupts data)
   - RIGHT: `push V, push S, store`

3. **Operand order for `:write_child`.** `opcode_int` is TOP,
   `child_addr` is second.
   - WRONG: `push opcode_int, push child_addr, write_child`
   - RIGHT: `push child_addr, push opcode_int, write_child`
   `Ancestor` avoids `swap` entirely: `push0, load, dup, read_self` (pos
   25..28) leaves `[addr, opcode_int]` already in the order `:write_child`
   wants — copy that idiom.

4. **Operand order for `:make_plasmid`.** `length` is TOP, `start_addr`
   is second. Stack effect `( start_addr length -- ok? )`.
   - WRONG: `push length, push start_addr, make_plasmid`
   - RIGHT: `push start_addr, push length, make_plasmid`

5. **Forgetting the separator between anchor and template.** Two adjacent
   nop runs get absorbed by the template extractor (up to 8 nops). This
   includes across the **ring wrap** — if the last opcode of your codeome
   is part of a template's nop run and the first opcode is an anchor's nop
   run, you have an 8-nop misread. Always end the codeome with a non-nop
   (`:push0` is canonical) when a template's nops are at the tail. See
   `Ancestor` positions 49 and 99; `Reflex` positions 25, 37, 48; `Symbiont`
   positions 41, 54, 70, 105, 117.

6. **Confusing `:turn_left` direction.** `:turn_left` is COUNTER-clockwise
   (n→w→s→e→n). `:turn_right` is CLOCKWISE (n→e→s→w→n). The cycle is the
   same as a clock face viewed from above, with north pointing up.

7. **Thinking `:sense_self` queries the world.** It does NOT. `:sense_self`
   ALWAYS pushes 1 (a hardcoded local sentinel). It's nearly useless
   alone — its primary purpose is letting evolved codeomes test "am I
   still alive?" with zero world cost. To sense the cell ahead of you,
   use `:sense_front`.

8. **Treating empty pop as a crash.** It is NOT. Popping from an empty
   stack returns 0 (and `:load` on an unwritten slot returns 0 too).
   `:ret` from an empty call stack does NOT halt either — it just
   advances IP by 1. Plan defensively but don't pre-fill the stack "to
   be safe" — that's extra opcodes for nothing. (Note: `:peek` is NOT
   an opcode — it's an internal `State.peek/1` helper in source. The
   only way to non-destructively read the top is `:dup` then use one
   of the copies.)

9. **Codeome length out of bounds.** The acceptable codeome length range is
   **[5, 1024]** opcodes. Below 5: rejected. Above 1024: rejected. Also
   the codeome must contain at least **10 non-nop** opcodes — a codeome
   of 100 nops will be rejected even though length is in range.

10. **Atom typos.** Use `:nop_0` (with underscore) NOT `:nop0`. Use
    `:push0` (no underscore) NOT `:push_0`. Use `:sense_front` not
    `:senseFront` or `:sense-front`. The Elixir parser will accept
    typos as valid atoms, and `Codeome.from_list/1` does NOT validate them
    — it stores whatever you give it. Validation happens at the editor
    layer (via `Codeome.Opcodes.known?/1`), which rejects any atom not in
    the 40-opcode whitelist before the codeome is built. (At execution
    time an unrecognized opcode is treated as `:nop_0`, so a typo silently
    becomes a no-op rather than crashing.)

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
    `:allocate → write_child loop → :divide`. `Ancestor`
    enforces this via the COPY anchor at positions 21..24 and
    reaches `:divide` at position 54 only after the copy loop has
    written N opcodes.

13. **Cap awareness in sandbox.** The Sandbox world enforces per-world
    caps: **spawn_cap = 10** (max Lenies spawned via the editor), and
    **replication_cap = 50** (max children per spawned ancestor lineage).
    When the cap is hit, `:divide` returns silently — replication just
    stops. The Arena world overrides both to `:infinity`. AI agents
    should design replicators that remain stable when replication is
    suddenly throttled (`Reflex` is a good "always stable" template
    since it doesn't replicate at all).

---

## 7. Validation checklist

Before outputting a codeome, mentally run through this list:

1. **All opcode atoms are in the 40-opcode whitelist (no typos).** Use
   the table in §2 as the canonical reference. The editor rejects any
   atom outside the whitelist (via `Codeome.Opcodes.known?/1`) before
   building the codeome; `Codeome.from_list/1` itself does not validate,
   and any unrecognized opcode that slips through executes as `:nop_0`.

2. **Codeome length is in `[5, 1024]`.** Count the opcodes in your list
   (including all nops and separators). Below 5 or above 1024: rejected
   at creation. The reference codeomes are 49 (Reflex), 100 (Ancestor),
   173 (Architect), 118 (Symbiont).

3. **At least 10 non-nop opcodes** (`min_viable_codeome_opcodes`).
   `:nop_0` and `:nop_1` don't count toward this; everything else does.

4. **Every template has a matching complement somewhere** in the codeome
   (else the jump falls through). `Ancestor`'s anchor table is a good
   reference set — five anchors drawn from five distinct complement-pairs, so
   all ten nop windows are unique: pick distinct anchors for each control-flow
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
   (`Ancestor` does this: slot[0] holds the copy index during replication,
   then the forage budget K); just make sure the value is fresh when you load it.

8. **Energy budget is sustainable.** For a replicator: the energy grazed
   per forage cycle must exceed the replication cycle cost. `:eat` empties
   the whole cell (0 in a desert, up to cap `3×eat_amount`=150 in an oasis),
   so per-cycle gain is field-dependent and bursty — there is no fixed
   per-iter margin. Keep replication cost low, move well to reach charged
   cells, and size K to cross the deserts between oases. (See ch. 8.)

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

- Calling `Lenies.Codeome.from_list(your_atoms)` to build the struct, and
  checking each atom with `Lenies.Codeome.Opcodes.known?/1` (the editor
  uses this to reject unknown atoms; `from_list/1` itself does not validate).
- Checking length is in `[5, 1024]` and non-nop count `>= 10`.
- Optionally simulating ticks via `Lenies.Interpreter.step/2`.

In the editor: paste the atoms into the spawn form (the editor accepts the
same atom list syntax via the palette drag-and-drop), give your codeome a
unique name, then click "Spawn". The Lenie will appear in the current world.
If the codeome is invalid, the editor reports the rejection reason in the
flash bar at the top.

For deeper analysis, the four reference codeomes in §5 all have
`def codeome/0` functions exposed in their respective modules — call them
from `iex -S mix` (e.g. `Lenies.Codeomes.Ancestor.codeome()`) to
see the parsed `%Codeome{}` struct and verify your understanding.
