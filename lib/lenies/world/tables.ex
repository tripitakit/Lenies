defmodule Lenies.World.Tables do
  @moduledoc """
  Creates and manages the project's ETS tables.

  Ownership convention: the caller (`Lenies.World` in production) must invoke
  `create_all/1` from its `init/1` to become the owner of the tables. All
  tables are `:set`, `:public`. For the `:primary` world the tables are
  ALSO created as `:named_table` (compat shim during the multi-world
  refactor) so legacy callers reading by atom name (`:cells`, `:lenies`, …)
  continue to work. The shim is removed in Task 6 when Lenies switch to
  handle-based reads.

  Tables:
  - `:cells`             — `{x,y} → %Lenies.World.Cell{}` (source of truth for occupancy)
  - `:lenies`            — `id    → snapshot` (written mainly by Lenies, with exceptions by World)
  - `:child_slots`       — `slot  → gestation record`
  - `:history`           — ring buffer of aggregated metrics (written by Telemetry)

  Note: `:species_codeomes` (hash → [opcode] cache populated by `Lenie.init/1`)
  is NOT created here — it's owned by `Lenies.Application` so its lifetime
  spans the whole node, independent of any World restart. The content is
  deterministic given the hash, so sharing it across worlds is correct.
  """

  @tables [:cells, :lenies, :child_slots, :history]

  def tables, do: @tables

  @doc """
  Creates the 4 per-world ETS tables and returns a map of tids.

  For the `:primary` world (compat shim during the multi-world refactor) we
  ALSO register the tables as named (`:cells`, `:lenies`, `:child_slots`,
  `:history`) so legacy callers reading by atom name continue to work. The
  shim is removed in Task 6 when Lenies switch to handle-based reads.
  """
  def create_all(world_id) do
    named = if world_id == :primary, do: [:named_table], else: []
    opts = [:set, :public, read_concurrency: true, write_concurrency: true] ++ named

    # `:ets.new/2` returns the atom name when `:named_table` is in opts and a
    # reference (tid) otherwise. The state.tables map MUST always hold tids,
    # so for the named-table case we resolve the tid via `:ets.whereis/1`.
    %{
      cells: tid_of(:ets.new(:cells, opts)),
      lenies: tid_of(:ets.new(:lenies, opts)),
      child_slots: tid_of(:ets.new(:child_slots, opts)),
      history: tid_of(:ets.new(:history, opts))
    }
  end

  defp tid_of(ref) when is_reference(ref), do: ref
  defp tid_of(name) when is_atom(name), do: :ets.whereis(name)

  @doc """
  Legacy zero-arg variant — creates the 4 ETS tables as `:named_table` only.

  Used by tests and other call sites that haven't been migrated to the
  per-world tids map yet. Equivalent to `create_all(:primary)` minus the
  return value (returns `:ok` for back-compat).
  """
  def create_all do
    _ = create_all(:primary)
    :ok
  end

  @doc """
  Deletes the 4 ETS tables referenced by `tables_map` (a map of tids as
  returned by `create_all/1`). Idempotent.
  """
  def delete_all(tables_map) when is_map(tables_map) do
    for {_key, tid} <- tables_map do
      try do
        :ets.delete(tid)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  Legacy zero-arg variant — deletes the 4 ETS tables by named atom.
  Idempotent.
  """
  def delete_all do
    for t <- @tables do
      try do
        :ets.delete(t)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  Empties the 4 ETS tables referenced by `tables_map` without deleting them.
  """
  def clear_all(tables_map) when is_map(tables_map) do
    for {_key, tid} <- tables_map do
      try do
        :ets.delete_all_objects(tid)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  Legacy zero-arg variant — empties the 4 ETS tables by named atom.
  """
  def clear_all do
    for t <- @tables do
      try do
        :ets.delete_all_objects(t)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
