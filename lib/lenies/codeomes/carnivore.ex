defmodule Lenies.Codeomes.Carnivore do
  @moduledoc """
  Predatory variant of the minimal_replicator. The foraging phase inserts :attack
  before :eat. Same replication procedure (4-bit template anchors).

  If a Lenie is in front, :attack transfers energy directly. If the cell ahead
  is empty or contains only food, :attack returns :no_target (no-op) but still
  costs 5 energy.
  """

  alias Lenies.Codeome

  @plasmid_opcodes [
    # ── pos 0..3: INTERCEPT_ANCHOR = FORAGE_LOOP_HEAD pattern [n0,n1,n0,n1] ──
    :nop_0, :nop_1, :nop_0, :nop_1,

    # ── pos 4..5: extra step + extra eat (sprint) ────────────────────────
    :move, :eat,

    # ── pos 6..10: jmp_t FORAGE_LOOP_HEAD (template [n1,n0,n1,n0]) ───────
    :jmp_t, :nop_1, :nop_0, :nop_1, :nop_0,

    # ── pos 11: trailing separator (CRITICAL) ───────────────────────────
    # Without this non-nop, the final jmp_t template merges with the host's
    # LOOP_HEAD nops across the codeome-ring wrap (8 nops read instead of
    # 4), so the bounce-back lands in replication setup instead of
    # FORAGE_LOOP_HEAD and the host starves in place. See the Twitch
    # plasmid in MinimalReplicator for the full explanation.
    :push0
  ]

  def codeome do
    base_opcodes = Lenies.Codeomes.MinimalReplicator.opcodes()
    patched = inject_attack_before_eat(base_opcodes)
    Codeome.from_list(patched ++ @plasmid_opcodes)
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

  @doc """
  The Sprint plasmid: 12 opcodes that intercept the host's per-iteration
  `jnz_t FORAGE_LOOP_HEAD` and inject an extra `:move, :eat` pair before
  bouncing back. The host effectively covers two cells (and eats two)
  per forage iter instead of one.

  Anchor at pos 0..3 (`[n0,n1,n0,n1]`) matches the FORAGE_LOOP_HEAD pattern
  in any MR-derived codeome. The intercept fires every forage iteration,
  producing visible sprint movement. The trailing `:push0` (pos 11) is a
  mandatory separator — without it the bounce-back jmp mis-resolves across
  the codeome-ring wrap.
  """
  @spec plasmid() :: [atom()]
  def plasmid, do: @plasmid_opcodes
end
