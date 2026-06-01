# Lenies VM Fact Sheet (source-derived ground truth)

Working reference for the manual proofread. NOT part of the manual.
Derived from `lib/lenies/` on 2026-06-01. Stack notation: **top on the right**.

## State struct (`Interpreter.State`) — 9 fields

Note: the manual's Ch.1 table lists **8** fields and omits `plasmids`. The
struct actually has **9** fields. Either the manual must add `plasmids` or
explicitly say it covers the 8 core VM fields and treats `plasmids` separately
(Ch.10). FLAG for Ch.1.

| Field | Default | Notes |
|---|---|---|
| `ip` | 0 | wraps mod size via `advance_ip/3` (`Integer.mod`) |
| `stack` | `[]` | max **16**; `push` prepends (head=top); on overflow `Enum.take(stack,16)` drops the **bottom** (oldest) |
| `slots` | `%{0=>0,1=>0,2=>0,3=>0}` | 4 slots; `store/load` do `Integer.mod(idx,4)` |
| `dir` | `:n` | `:n\|:e\|:s\|:w` |
| `energy` | `0.0` | float; `new/1` coerces `*1.0` |
| `age` | 0 | incremented per K-batch by the Lenie process, not the interpreter |
| `pos` | `{0,0}` | written back by World after `:move` |
| `call_stack` | `[]` | max **32**; `push_call` then `Enum.take(.,32)` |
| `plasmids` | `[]` | list of `%Plasmid{}`; mutated by `make_plasmid`/`conjugate` |

## The 38 opcodes (`Codeome.Opcodes.all/0`, in encode order 0..37)

Integer encoding = index in this list (used by `read_self`/`write_child`).

0 nop_0, 1 nop_1, 2 push0, 3 push1, 4 pushN, 5 dup, 6 drop, 7 swap, 8 add,
9 sub, 10 mul, 11 mod, 12 jmp_t, 13 jz_t, 14 jnz_t, 15 call_t, 16 ret,
17 sense_front, 18 sense_self, 19 sense_energy, 20 sense_age, 21 sense_size,
22 move, 23 turn_left, 24 turn_right, 25 eat, 26 attack, 27 defend, 28 get_ip,
29 get_size, 30 read_self, 31 allocate, 32 write_child, 33 divide, 34 store,
35 load, 36 make_plasmid, 37 conjugate. **Total = 38.**

## Semantics + stack effect + cost (top on right)

| Opcode | Stack effect | Cost | Outcome | Notes |
|---|---|---|---|---|
| nop_0/nop_1 | `( -- )` | 0.1 | :cont | template bits; no-op at exec level |
| push0 | `( -- 0 )` | 0.1 | :cont | |
| push1 | `( -- 1 )` | 0.1 | :cont | |
| pushN | `( -- n )` | 0.1 | :cont | n = `:rand.uniform(256)-1` → **0..255** |
| dup | `( a -- a a )` | 0.1 | :cont | |
| drop | `( a -- )` | 0.1 | :cont | |
| swap | `( b a -- a b )` | 0.1 | :cont | exchange top two |
| add | `( b a -- b+a )` | 0.2 | :cont | commutative |
| sub | `( b a -- b−a )` | 0.2 | :cont | **second minus top** (`fn a,b -> b-a`) |
| mul | `( b a -- b*a )` | 0.2 | :cont | |
| mod | `( b a -- b mod a )` | 0.2 | :cont | `a==0 → 0`; else `Integer.mod(b,a)` |
| jmp_t | `( -- )` | 0.2+0.05·tlen | :cont | always jumps to complement; t_len=0 → fall through to skip_to |
| jz_t | `( a -- )` | 0.2+0.05·tlen | :cont | pops; jumps if `a==0` |
| jnz_t | `( a -- )` | 0.2+0.05·tlen | :cont | pops; jumps if `a!=0` |
| call_t | `( -- )` | 0.2+0.05·tlen | :cont | push return_ip to call_stack; jump to complement; not_found → no push, ip=return_ip |
| ret | `( -- )` | 0.2 (tlen 0) | :cont | pop call_stack→ip; empty → advance ip by 1 |
| sense_front | `( -- v )`* | 0.5 | **:wait_world** | `{:sense_front,pos,dir}`; world pushes v |
| sense_self | `( -- 1 )` | 0.5 | :cont | always pushes 1 |
| sense_energy | `( -- e )` | 0.5 | :cont | `trunc(energy)` |
| sense_age | `( -- age )` | 0.5 | :cont | |
| sense_size | `( -- size )` | 0.5 | :cont | codeome size |
| move | `( -- )` | 2.0 | **:wait_world** | `{:move,pos,dir}` |
| turn_left | `( -- )` | 0.5 | :cont | n→w→s→e→n (CCW) |
| turn_right | `( -- )` | 0.5 | :cont | n→e→s→w→n (CW) |
| eat | `( -- )`* | 2.0 | **:wait_world** | `{:eat,pos}` |
| attack | `( -- )`* | 5.0 | **:wait_world** | `{:attack,pos,dir}` |
| defend | `( -- )` | 2.0 | **:wait_world** | bare `:defend` term |
| get_ip | `( -- ip )` | 0.3 | :cont | current ip |
| get_size | `( -- size )` | 0.3 | :cont | duplicate of sense_size value |
| read_self | `( addr -- opint )` | 0.3 | :cont | `Opcodes.encode(codeome[addr])` |
| allocate | `( size -- )`* | 5.0+0.05·size | **:wait_world** | `{:allocate,size,pos,dir}` |
| write_child | `( addr opint -- )`* | 1.0 | **:wait_world** | pops opint(top) then addr; `{:write_child,opint,addr}` |
| divide | `( -- )`* | 10.0 | **:wait_world** | `{:divide,energy,pos,dir}` |
| store | `( value slot -- )` | 0.5 | :cont | pops slot(top) then value |
| load | `( slot -- value )` | 0.5 | :cont | |
| make_plasmid | `( start len -- ok )` | 2.0+0.05·len (base 2.0) | :cont | pops len(top) then start; push 1 if `valid_length?` (1..64) else push 0 |
| conjugate | `( -- )`* | 4.0+0.05·psize (base 4.0 here) | **:wait_world** | picks random carried plasmid; `{:conjugate,pos,dir,ops}`; world adds size surcharge on success |
| unknown | — | 0.1 | :cont | treated as nop_0 |

\* world-interaction opcodes: the **interpreter** charges base cost + advances
IP, then returns `:wait_world`; the Lenie process calls World and applies the
result (pushes sensed values, updates pos/energy). Energy check (`<=0 → :halt
:starvation`) runs even on the wait_world path.

## Defensive semantics

- empty-stack `pop` → `{0, state}` (no crash)
- `mod` by 0 → 0
- slot index wraps mod 4 (any integer valid)
- unknown opcode → treated as `:nop_0` (cost 0.1, advance 1)
- failed template search (`:not_found`) → fall through to `skip_to`
- `ret` on empty call_stack → advance ip by 1 (no-op)
- **Invariant: mutations never produce syntax errors.**

## Template addressing (`Interpreter.Template`)

- `extract/3`: longest contiguous run of `:nop_0/:nop_1` from `ip+1`, capped at
  `template_max_len` (default **8**).
- `find_complement/4`: bit-flip the template (`nop_0↔nop_1`), search **forward
  first** (`from+1`, up to `radius`), **then backward** (`from-1`). Returns
  `{:ok, pos}` (index of first nop of match) or `:not_found`. Radius default
  **256**. Empty template → `:not_found`.
- jump target = `Integer.mod(match_pos + length(template), size)` (lands just
  after the matched complement).

## Config defaults (`Lenies.Config` / runtime.exs)

grid_size `{256,256}`, tick_interval_ms 100, radiation_per_tick 100,
radiation_uniform_ratio 0.7, hotspot_count 8, cell_resource_cap 100,
carcass_decay 0.05, codeome_length_bounds `{5,1000}`,
min_viable_codeome_opcodes 10, reconcile_interval_ms 30_000.
App env: `template_max_len` 8, `template_search_radius` 256.

## Plasmid (`Lenies.Plasmid`)

Hard cap **64** opcodes; `valid_length?(len)` = `1 <= len <= 64`. Stored as a
plain list. `make_plasmid` appends to `state.plasmids`; `conjugate` transfers a
uniformly-random carried plasmid.
