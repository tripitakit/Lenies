defmodule Lenies.Codeomes.Carnivore do
  @moduledoc """
  Predatory variant of the minimal_replicator. The foraging phase inserts :attack
  before :eat. Same replication procedure (4-bit template anchors).

  If a Lenie is in front, :attack transfers energy directly. If the cell ahead
  is empty or contains only food, :attack returns :no_target (no-op) but still
  costs 5 energy.
  """

  alias Lenies.Codeome

  def codeome do
    base_opcodes = Lenies.Codeomes.MinimalReplicator.opcodes()
    patched = inject_attack_before_eat(base_opcodes)
    Codeome.from_list(patched)
  end

  defp inject_attack_before_eat(opcodes) do
    inject_attack(opcodes, [])
  end

  defp inject_attack([], acc), do: Enum.reverse(acc)

  defp inject_attack([:eat | rest], acc) do
    # Found the first :eat — inject :attack before it and return the rest unchanged
    Enum.reverse(acc) ++ [:attack, :eat | rest]
  end

  defp inject_attack([op | rest], acc) do
    inject_attack(rest, [op | acc])
  end

  @plasmid_opcodes [
    # ── pos 0..3: INTERCEPT_ANCHOR — matches host's LOOP_HEAD template ──
    :nop_1, :nop_1, :nop_1, :nop_1,

    # ── pos 4..5: extra step + extra eat ─────────────────────────────────
    :move, :eat,

    # ── pos 6..10: jmp_t back to host LOOP_HEAD (template [n0,n0,n0,n0]) ──
    :jmp_t, :nop_0, :nop_0, :nop_0, :nop_0
  ]

  @doc """
  The Sprint plasmid: 11 opcodes that intercept the host's end-of-forage
  `jmp_t LOOP_HEAD` and inject an extra `:move, :eat` pair before
  bouncing back. The host effectively covers two cells (and eats two)
  per forage iter instead of one.

  Anchor at pos 0..3 matches any MR-derived codeome's LOOP_HEAD via the
  template forward search.
  """
  @spec plasmid() :: [atom()]
  def plasmid, do: @plasmid_opcodes
end
