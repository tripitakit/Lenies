defmodule Lenies.Codeomes.MaxForager do
  @moduledoc """
  A gradient-climbing self-replicator: each forage step it senses the four
  neighbouring cells, **moves onto the one holding the most energy and eats it**,
  then — once per generation — copies its chromosome and `divide`s.

  ## Behaviour

  One generation is:

  1. **Replicate** (von Neumann copy loop, à la `Ancestor`): measure self,
     `allocate` a child, copy the chromosome opcode-by-opcode, `divide`, step
     off the newborn.
  2. **Forage K times** — each step:
     - **Scan**: rotate counter-clockwise sensing the cell ahead at each of the
       four headings (`sense_front` pushes the cell's energy: `n>0` resource,
       `0` empty, `-1` a Lenie), storing the four readings in slots 0..3, then
       return to the initial heading.
     - **Pick the max**: argmax over the four readings, then `turn_left` the
       right number of times, `move` onto that cell, and `eat`.

  ## Stack-machine technique

  - **Argmax with the direction folded into the value.** A stack VM with no
    `over`/`min`/`max` and only zero/sign branch tests can't easily track
    "which slot won". Instead each reading is encoded as a *composite*
    `energy*4 + (3 - dir)`; the max composite still corresponds to the max
    energy, ties break toward the *earlier* direction (front > left > back >
    right), and the winning direction is recovered as `3 - (max mod 4)`. So the
    argmax collapses to a plain running-max accumulated in one slot, using the
    `:jgt_t` sign branch.
  - **Forage counter on the stack.** The four slots are all needed each scan, so
    the K-counter rides on the bottom of the data stack across forage steps (the
    scan and the argmax are both stack-neutral), freeing all four slots for the
    readings.

  ## Anchors

  The codeome needs ~14 distinct labels (replication + forage loop + argmax), so
  it uses **5-bit templates**: every anchor is `[nop_1 | 4 bits]` and every jump
  template is the bit-flipped complement `[nop_0 | …]`. Because anchors start
  with `nop_1` and templates with `nop_0`, no anchor can ever be mistaken for a
  template — every jump resolves to its intended label. `:push0` separators sit
  wherever two nop runs would otherwise merge (including across the ring wrap).

  ## Energy note

  The per-step argmax is computationally heavy (~24 energy) relative to a single
  `:eat`, so MaxForager is sustainable only where `eat_amount` is high enough to
  out-earn the scan+decide cost (the project default was raised for this reason)
  or in resource-rich worlds. It always *can* replicate given a starting energy
  buffer; how long a lineage persists depends on world richness.

  Verified in the Stepper: forages toward resources and divides repeatedly.

  ## References

  - L. Steels, behaviour-based gradient ascent / chemotaxis-style foraging.
  - J. von Neumann, self-reproducing automata (the copy loop).
  - Tierra (T. Ray) ancestor — the allocate/read_self/write_child/divide cycle.
  """

  import Bitwise
  alias Lenies.Codeome

  @labels ~w(HEAD COPY REPRO FSETUP FTOP FEND AS1 AN2 AS2 AN3 AS3 AAFT ATLOOP ATEND)a
  @label_index @labels |> Enum.with_index() |> Map.new()

  @doc "The MaxForager chromosome as a `Lenies.Codeome.t()`."
  @spec codeome() :: Codeome.t()
  def codeome, do: Codeome.from_list(opcodes())

  @doc "The raw opcode list (built from the labelled blocks)."
  @spec opcodes() :: [atom()]
  def opcodes do
    sep = [:push0]
    build64 = [:push1] ++ List.flatten(List.duplicate([:dup, :add], 6))

    List.flatten([
      # ── HEAD: measure self, allocate child, guard, set top copy index ──
      lbl(:HEAD),
      [:get_size, :push0, :store],
      [:push0, :load, :allocate],
      j(:jz_t, :FSETUP),
      [:push0, :load, :push1, :sub, :push0, :store],
      # ── COPY: child[i] := self[i], down to i == 0 ──
      lbl(:COPY),
      [:push0, :load, :dup, :read_self, :write_child, :drop],
      [:push0, :load],
      j(:jz_t, :REPRO),
      [:push0, :load, :push1, :sub, :push0, :store],
      j(:jmp_t, :COPY),
      sep,
      lbl(:REPRO),
      [:divide, :turn_right],
      # ── FSETUP: build the K=64 forage counter (also alloc-fail landing) ──
      lbl(:FSETUP),
      build64,
      # ── FTOP: forage loop; counter rides the stack bottom ──
      lbl(:FTOP),
      [:dup],
      j(:jz_t, :FEND),
      # scan four neighbours CCW into slots 0..3, return to initial heading
      [:sense_front, :push0, :store, :turn_left],
      [:sense_front, :push1, :store, :turn_left],
      [:sense_front, :push1, :push1, :add, :store, :turn_left],
      [:sense_front, :push1, :push1, :push1, :add, :add, :store, :turn_left],
      # argmax (front-priority): slot0 := max(energy*4 + (3-dir))
      [:push0, :load, :dup, :add, :dup, :add, :push1, :push1, :push1, :add, :add, :add, :push0, :store],
      [:push1, :load, :dup, :add, :dup, :add, :push1, :push1, :add, :add],
      [:dup, :push0, :load, :sub],
      j(:jgt_t, :AS1),
      [:drop],
      j(:jmp_t, :AN2),
      sep,
      lbl(:AS1),
      [:push0, :store],
      lbl(:AN2),
      [:push1, :push1, :add, :load, :dup, :add, :dup, :add, :push1, :add],
      [:dup, :push0, :load, :sub],
      j(:jgt_t, :AS2),
      [:drop],
      j(:jmp_t, :AN3),
      sep,
      lbl(:AS2),
      [:push0, :store],
      lbl(:AN3),
      [:push1, :push1, :push1, :add, :add, :load, :dup, :add, :dup, :add],
      [:dup, :push0, :load, :sub],
      j(:jgt_t, :AS3),
      [:drop],
      j(:jmp_t, :AAFT),
      sep,
      lbl(:AS3),
      [:push0, :store],
      lbl(:AAFT),
      # d = 3 - (slot0 mod 4)  -> slot1
      [:push0, :load, :push1, :push1, :add, :dup, :add, :mod],
      [:push1, :push1, :push1, :add, :add, :swap, :sub, :push1, :store],
      # turn_left d times
      lbl(:ATLOOP),
      [:push1, :load],
      j(:jz_t, :ATEND),
      [:turn_left, :push1, :load, :push1, :sub, :push1, :store],
      j(:jmp_t, :ATLOOP),
      sep,
      lbl(:ATEND),
      [:move, :eat],
      # decrement forage counter, loop
      [:push1, :sub],
      j(:jmp_t, :FTOP),
      sep,
      lbl(:FEND),
      [:drop],
      j(:jmp_t, :HEAD),
      sep
    ])
  end

  # ----- 5-bit anchor assembler -----

  # Anchor for a label: nop_1 followed by the 4-bit label index.
  defp lbl(name), do: to_nops([1 | nibble(@label_index[name])])

  # Jump opcode + the template that resolves to `name` (complement of its anchor).
  defp j(op, name), do: [op | to_nops(flip([1 | nibble(@label_index[name])]))]

  defp nibble(i), do: for(b <- 3..0//-1, do: i >>> b &&& 1)
  defp flip(bits), do: Enum.map(bits, fn 0 -> 1; 1 -> 0 end)
  defp to_nops(bits), do: Enum.map(bits, fn 0 -> :nop_0; 1 -> :nop_1 end)
end
