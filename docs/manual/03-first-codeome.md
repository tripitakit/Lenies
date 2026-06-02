# Chapter 3 — Your First Codeome: The Walker

You've read how the VM is built (chapter 1) and scanned the opcode table (chapter 2).
Time to make something move. This chapter walks you through writing the smallest codeome
that does anything genuinely useful: a creature that walks north, eats whatever it finds
underfoot, and loops forever. By the end you'll have a living dot crossing the canvas.

---

## 1. The Goal

We want the simplest possible Lenie that is not just dead code. "Simple" here means: one
direction, one action, one loop, nothing else. The Walker walks north on every tick, eats
any resource it finds on its current cell, and then jumps back to the top of its own code
to repeat. It has no decisions, no memory, no reproduction — just motion and eating. That
is enough to keep energy positive on a resource-rich world, and it is enough to see the VM
come alive in front of you.

---

## 2. The Conceptual Walker

Here is the core loop in Elixir list syntax (the same format the editor and the VM use
internally):

```elixir
[
  :nop_0,        # 0  LOOP_HEAD anchor (bit pattern: [0])
  :sense_front,  # 1  yield to world; push cell info (we'll ignore the value)
  :drop,         # 2  discard the sense result - we just want the wait_world cycle
  :eat,          # 3  yield; consume up to eat_amount from current cell if present
  :move,         # 4  yield; step forward if the front cell is empty
  :jmp_t,        # 5  jump to complement of the following template
  :nop_1,        # 6  template (bit pattern: [1])
  :push0         # 7  separator across the wrap; also helps padding (see below)
]
```

Walk through each position once to understand what is happening:

**Position 0 — `:nop_0`**
Costs 0.1 energy and does nothing to the stack or the world. Its entire purpose is to sit
here as an *anchor*: a recognisable bit pattern (`0`) that the jump at position 5 will
search for. No-ops are inert at the interpreter level; their meaning is positional.

**Positions 1–2 — `:sense_front; :drop`**
This is the *defensive front sense* idiom. `sense_front` yields control to the world,
costs 0.5 energy, and pushes a value describing the cell directly ahead. We don't actually
use that value — `drop` discards it immediately (cost 0.1). Why bother sensing at all?
Because the yield is what lets the world advance around us: without it the Lenie would
race through its loop without ever giving the simulation time to move things. You will see
this idiom whenever a loop needs to pace itself without branching. (The cookbook in
chapter 11 has more on world-yield patterns.)

**Position 3 — `:eat`**
Yields to the world and attempts to consume up to `eat_amount` (20 energy units) from the
current cell's resource pool. If the cell is empty the yield still happens; you just don't
gain energy. Cost: 2.0.

**Position 4 — `:move`**
Yields to the world and steps forward in the current facing direction (`:n` at birth).
If the target cell is occupied the move is blocked silently; the Lenie stays put and loses
the 2.0 energy anyway. On a lightly populated world this almost always succeeds.

**Position 5 — `:jmp_t`**
This is the jump. `jmp_t` reads the run of consecutive nops immediately *after* it in the
codeome and uses them as a *template*. Here the template is `[:nop_1]` (just one nop, bit
pattern `[1]`). The interpreter flips every bit in the template to get the *complement*:
`[:nop_0]` (bit pattern `[0]`). It then scans the codeome looking for that pattern. It
finds it at position 0. The instruction pointer jumps to one step past the match — position 1
(`sense_front`) — and the loop runs again. Cost for a one-bit template: 0.2 + 0.05 × 1 = 0.25.

**Position 6 — `:nop_1`**
The template the jump reads. It is not executed in the normal flow after the jump fires;
it is consumed as data by `jmp_t`.

**Position 7 — `:push0`**
This is a *separator*. The codeome is a ring: position 7 wraps back to position 0. If
there were nothing between `:nop_1` (position 6) and `:nop_0` (position 0), the template
extractor — which reads greedily forward — would cross the wrap boundary and collect
`[:nop_1, :nop_0]`, a two-bit template. That two-bit template complements to
`[:nop_0, :nop_1]`, and the search might not find what we expect. The `:push0` at
position 7 is the first non-nop the extractor hits after position 6, so it stops, and the
template stays exactly `[:nop_1]`. Chapter 4 covers separator placement in full detail.
For now: always put a non-nop between your template and anything on the other side of the
wrap.

---

## 3. How the Loop Works (Informal)

Most languages have `goto loop:` with an explicit label you write yourself. The Lenies VM
has no such thing. Instead, jumps target *bit patterns* embedded in the code itself.
`jmp_t :nop_1` means "jump to wherever the codeome contains a `:nop_0`" — the complement
of the one-bit template `[1]` is `[0]`, i.e. `:nop_0`. Chapter 4 covers this mechanism
in depth, including multi-bit templates, the search radius, and what happens when no match
is found. For now, just accept the rule: **`jmp_t` followed by a nop sequence jumps to
the complement of that sequence**.

---

## 4. A Short Stack Trace

Below is a tick-by-tick trace starting from a fresh Lenie at ip=0, energy=10000, facing
`:n`. The `k` in the stack column is whatever `sense_front` returns (a small integer
encoding the cell ahead); the exact value does not matter because we drop it immediately.

```
tick | ip | opcode       | stack after | dir | energy after
-----+----+--------------+-------------+-----+--------------
  0  |  0 | nop_0        | []          | :n  | 9999.9
  1  |  1 | sense_front  | [k]         | :n  | 9999.4   (yields wait_world; world replies with k)
  2  |  2 | drop         | []          | :n  | 9999.3
  3  |  3 | eat          | []          | :n  | 9997.3   (yields; +20 if cell had resource)
  4  |  4 | move         | []          | :n  | 9995.3   (yields; advances pos if front is empty)
  5  |  5 | jmp_t        | []          | :n  | 9995.05  (template=[nop_1], finds nop_0 at 0, ip <- 1)
  6  |  1 | sense_front  | [k]         | :n  | 9994.55  (loop continues)
```

Cost sources (from `Lenies.Codeome.Costs`):

- `nop_0` → 0.1
- `sense_front` → 0.5
- `drop` → 0.1
- `eat` → 2.0
- `move` → 2.0
- `jmp_t` with template_len=1 → 0.2 + 0.05 × 1 = 0.25

After birth the jump lands at position 1, so `:nop_0` (position 0) runs only once and the
steady-state loop is positions 1–5: `sense_front; drop; eat; move; jmp_t` =
0.5 + 0.1 + 2.0 + 2.0 + 0.25 = **4.85 energy per loop** (the very first pass adds the
one-time 0.1 for `:nop_0`, for 4.95). With `eat_amount` = 20, a single successful eat more
than pays for the entire loop. On a world with reasonable resource density the Walker is
comfortably energy-positive.

---

## 5. The Validation Gate

Before the editor will save a codeome it runs `LeniesWeb.CodeomeBuffer.validate/1`.
Three things must be true:

1. **Length in bounds:** the codeome must have between 5 and 1000 opcodes.
2. **Enough non-nop opcodes:** at least 10 opcodes that are not `:nop_0` or `:nop_1`.
3. **All opcodes in the whitelist:** every atom must be in the 38-entry opcode set.

The conceptual Walker above has **8 opcodes total** and **6 non-nops**
(`:sense_front`, `:drop`, `:eat`, `:move`, `:jmp_t`, `:push0`). It passes rule 1 and
rule 3, but it fails rule 2. If you try to save it the editor shows:

```
! too few non-nops (6, min 10)
```

The minimum-non-nop rule exists to prevent degenerate creatures that are mostly junk DNA
from consuming memory and simulation time. We need to add substance.

---

## 6. Padding Strategy

The solution is *dead-code padding*: add opcodes that the running program never actually
reaches. Because `jmp_t` always sends the instruction pointer back to position 1
(`sense_front`), anything after the separator at position 7 is never executed. We can
stuff it with cheap, harmless opcode pairs.

The cheapest no-effect pair is `:push0; :drop` — it costs 0.2 energy combined, pushes a
zero and immediately discards it, leaving the stack unchanged. We repeat it four times to
add 8 more opcodes (all non-nops), for a total of 16 opcodes and 14 non-nops.

```elixir
[
  :nop_0,                                                     # 0  LOOP_HEAD
  :sense_front, :drop, :eat, :move,                           # 1..4
  :jmp_t, :nop_1, :push0,                                     # 5..7  jump + template + separator
  :push0, :drop, :push0, :drop, :push0, :drop, :push0, :drop  # 8..15 dead-code padding
]
```

Count check:

- Total opcodes: 8 (core) + 8 (padding) = **16** — within the 5..1000 bound.
- Non-nop opcodes: 6 (core, excluding the two nops) + 8 (all padding ops are non-nop) = **14** — above the minimum of 10.
- All atoms in whitelist: yes.

Validation result: **`✓ valid (16 ops, 14 non-nop)`**

Positions 8–15 are unreachable in steady-state operation. If the Lenie were ever born
with ip somewhere in that region (for instance due to a mutation), it would execute a few
`push0; drop` cycles and eventually reach the end of the codeome — but because the codeome
is a ring, execution wraps around to position 0 (`nop_0`) and the loop picks up normally.
The padding is genuinely safe.

---

## 7. Try It — Editor Steps

Fire up the app at `http://localhost:4000` and follow these steps exactly:

1. Click **`+ New Seed`** in the controls panel on the left.
2. The codeome editor modal opens. The opcode palette is on the left side of the modal;
   the empty listing is on the right.
3. Drag opcodes from the palette into the listing in this exact order:
   - `:nop_0`
   - `:sense_front`
   - `:drop`
   - `:eat`
   - `:move`
   - `:jmp_t`
   - `:nop_1`
   - `:push0` (the separator)
   - Then four repetitions of `:push0`, `:drop` (8 more opcodes, the dead-code padding)
4. Watch the validation banner at the top of the listing. Once all 16 opcodes are in place
   it should read **`✓ valid (16 ops, 14 non-nop)`**. If it still shows a warning, recount
   the padding pairs — you need exactly four `:push0; :drop` pairs after the separator.
5. Click **Save**. In the name field type `walker-v1`. Pick any colour you like. Set the
   starting energy to `10000` (the default is fine). Confirm.
6. Close the modal.
7. In the controls panel the Seed dropdown now shows **`★ walker-v1`**. Select it if it is
   not already selected.
8. Set the count field to `1` and click **Spawn**.
9. Watch the canvas. A single coloured dot appears and begins walking north steadily.
   Because the world is toroidal it disappears off the top edge and reappears at the
   bottom — the same creature, crossing the wrap.

If the dot stays still, confirm the world has at least some initial resource (`eat_amount`
is non-zero in the config). If it vanishes immediately, its starting energy may have been
set too low — 10000 is safe.

---

## 8. Editor Ergonomics

The drag-and-drop walkthrough above covers the basics. The editor also supports a richer
set of interactions for editing larger codeomes.

**Selecting blocks**
Click a cell in the listing to select it (highlighted in blue). Shift-click a second cell
to extend the selection to a contiguous range. Press **Esc** to clear the selection.

**Clipboard operations**
With one or more cells selected, use the toolbar above the listing or keyboard shortcuts:

| Action    | Shortcut         |
|-----------|------------------|
| Copy      | Ctrl/Cmd+C       |
| Cut       | Ctrl/Cmd+X       |
| Paste     | Ctrl/Cmd+V       |
| Duplicate | Ctrl/Cmd+D       |
| Delete    | Del / Backspace  |

The clipboard is per editor session — it does not persist after you leave the editor page.

**Undo / Redo**
Every edit (drag, paste, delete, …) is recorded in a local history. Use **Ctrl/Cmd+Z** to
undo and **Ctrl/Cmd+Shift+Z** (or **Ctrl+Y**) to redo, or press the **Undo** / **Redo** buttons in the
toolbar.

**Snippets**
Select a range of cells, then click **Save as snippet** in the toolbar. Give the snippet a
name; it appears in the **Snippets** section at the bottom of the opcode palette. Click the
snippet there to insert it — it lands after the current selection, or at the end of the
codeome if nothing is selected. Snippets are saved on the server (in `priv/user_snippets.json`), so they persist across sessions and are available to anyone using the same running instance. To remove a snippet from the library, click the ⨯ button on its row in the Snippets section.

---

## 9. What's Next

The Walker works, but we waved our hands at the most interesting part: how does `jmp_t`
actually find `:nop_0` from `:nop_1`, and what happens when there are two possible matches,
or none at all?

→ Chapter 4 answers all of that. ([04-loops-and-templates.md](04-loops-and-templates.md))
