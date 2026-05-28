defmodule Lenies.World.ChildSlots do
  @moduledoc """
  Helper for the `:child_slots` ETS table, which holds gestation slots during
  replication.

  Record: `slot_id` (binary) → `%{parent_id, target_cell, size, opcodes}`
  - `parent_id`: id of the parent Lenie that allocated the slot
  - `target_cell`: `{x, y}` where the child will be born (a free cell at allocate time)
  - `size`: length of the child's Codeome
  - `opcodes`: tuple of opcode atoms (size elements), initialized to `:nop_0`

  All mutations go through the `World` GenServer (single writer). Each
  function takes the per-world `:child_slots` tid (from `state.tables`)
  as its first argument — there is no global `:child_slots` table since
  the multi-world refactor (T6).
  """

  @type slot :: %{
          parent_id: binary(),
          target_cell: {non_neg_integer(), non_neg_integer()},
          size: non_neg_integer(),
          opcodes: tuple()
        }

  @doc "Create an empty slot initialized to `:nop_0` × size. Returns {:ok, slot_id}."
  @spec create(:ets.tid(), binary(), {non_neg_integer(), non_neg_integer()}, non_neg_integer()) ::
          {:ok, binary()}
  def create(tid, parent_id, target_cell, size) do
    slot_id = generate_slot_id()

    slot = %{
      parent_id: parent_id,
      target_cell: target_cell,
      size: size,
      opcodes: List.duplicate(:nop_0, size) |> List.to_tuple()
    }

    :ets.insert(tid, {slot_id, slot})
    {:ok, slot_id}
  end

  @spec get(:ets.tid(), binary()) :: {:ok, slot()} | :not_found
  def get(tid, slot_id) do
    case :ets.lookup(tid, slot_id) do
      [{^slot_id, slot}] -> {:ok, slot}
      [] -> :not_found
    end
  end

  @spec set_opcode(:ets.tid(), binary(), integer(), atom()) :: :ok | :not_found
  def set_opcode(tid, slot_id, addr, opcode) do
    case get(tid, slot_id) do
      {:ok, slot} ->
        idx = Integer.mod(addr, slot.size)
        new_opcodes = put_elem(slot.opcodes, idx, opcode)
        :ets.insert(tid, {slot_id, %{slot | opcodes: new_opcodes}})
        :ok

      :not_found ->
        :not_found
    end
  end

  @spec delete(:ets.tid(), binary()) :: :ok
  def delete(tid, slot_id) do
    :ets.delete(tid, slot_id)
    :ok
  end

  @spec opcodes_to_list(slot()) :: [atom()]
  def opcodes_to_list(slot), do: Tuple.to_list(slot.opcodes)

  defp generate_slot_id do
    # ULID-like prefix + random
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
