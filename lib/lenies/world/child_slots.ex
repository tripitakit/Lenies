defmodule Lenies.World.ChildSlots do
  @moduledoc """
  Helper per la tabella ETS `:child_slots` che ospita gli slot di gestazione
  durante la replicazione.

  Record: `slot_id` (binary) → `%{parent_id, target_cell, size, opcodes}`
  - `parent_id`: id del Lenie genitore che ha allocato lo slot
  - `target_cell`: `{x, y}` dove nascerà il figlio (cella libera al momento dell'allocate)
  - `size`: lunghezza del Codeome figlio
  - `opcodes`: tuple di atomi opcode (size elementi), inizializzata a `:nop_0`

  Tutte le mutazioni passano per il `World` GenServer (single writer). I metodi
  qui sono helper *chiamati da dentro* le callback del World. Lookup è pure ETS
  (può essere chiamato da chiunque legge `:child_slots`).
  """

  @table :child_slots

  @type slot :: %{
          parent_id: binary(),
          target_cell: {non_neg_integer(), non_neg_integer()},
          size: non_neg_integer(),
          opcodes: tuple()
        }

  @doc "Crea uno slot vuoto inizializzato a `:nop_0` × size. Ritorna {:ok, slot_id}."
  @spec create(binary(), {non_neg_integer(), non_neg_integer()}, non_neg_integer()) ::
          {:ok, binary()}
  def create(parent_id, target_cell, size) do
    slot_id = generate_slot_id()

    slot = %{
      parent_id: parent_id,
      target_cell: target_cell,
      size: size,
      opcodes: List.duplicate(:nop_0, size) |> List.to_tuple()
    }

    :ets.insert(@table, {slot_id, slot})
    {:ok, slot_id}
  end

  @spec get(binary()) :: {:ok, slot()} | :not_found
  def get(slot_id) do
    case :ets.lookup(@table, slot_id) do
      [{^slot_id, slot}] -> {:ok, slot}
      [] -> :not_found
    end
  end

  @spec set_opcode(binary(), integer(), atom()) :: :ok | :not_found
  def set_opcode(slot_id, addr, opcode) do
    case get(slot_id) do
      {:ok, slot} ->
        idx = Integer.mod(addr, slot.size)
        new_opcodes = put_elem(slot.opcodes, idx, opcode)
        :ets.insert(@table, {slot_id, %{slot | opcodes: new_opcodes}})
        :ok

      :not_found ->
        :not_found
    end
  end

  @spec delete(binary()) :: :ok
  def delete(slot_id) do
    :ets.delete(@table, slot_id)
    :ok
  end

  @spec opcodes_to_list(slot()) :: [atom()]
  def opcodes_to_list(slot), do: Tuple.to_list(slot.opcodes)

  defp generate_slot_id do
    # ULID-like prefix + random
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
