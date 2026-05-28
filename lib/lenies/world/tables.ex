defmodule Lenies.World.Tables do
  @moduledoc """
  Creates and manages the project's ETS tables.

  Ownership convention: the caller (`Lenies.World` in production) must invoke
  `create_all/1` from its `init/1` to become the owner of the tables. All
  tables are `:set`, `:public`, and UNNAMED — the caller holds the tids in
  its state map and exposes them via its `%Lenies.WorldHandle{}`.

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
  Creates the 4 per-world ETS tables (unnamed) and returns a map of tids.

  The atom passed as first arg to `:ets.new/2` is just a tag for
  `:ets.info/2` (the table has no global name without `:named_table`).
  """
  def create_all(_world_id) do
    opts = [:set, :public, read_concurrency: true, write_concurrency: true]
    ordered_opts = [:ordered_set, :public, read_concurrency: true, write_concurrency: true]

    %{
      cells: :ets.new(:cells, opts),
      lenies: :ets.new(:lenies, opts),
      child_slots: :ets.new(:child_slots, opts),
      history: :ets.new(:history, ordered_opts)
    }
  end

  @doc """
  Test-only convenience that creates the 4 tables as `:named_table` so a
  test fixture can read/write them by bare atom without spinning up a
  full `Lenies.World`.

  Production code MUST use `create_all/1` (unnamed tids) and thread the
  resulting map through a `%Lenies.WorldHandle{}`. This wrapper exists
  purely so existing test setups (`test/lenies/world/tables_test.exs`,
  `test/lenies/world/child_slots_test.exs`, …) keep working.
  """
  def create_all do
    opts = [:set, :public, :named_table, read_concurrency: true, write_concurrency: true]

    ordered_opts = [
      :ordered_set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(:cells, opts)
    :ets.new(:lenies, opts)
    :ets.new(:child_slots, opts)
    :ets.new(:history, ordered_opts)
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
  Test-only `on_exit` companion to `create_all/0`. Deletes the 4 named
  tables (idempotent), then — if a `Lenies.World` GenServer is still
  running — stops it so the next test starts from a clean slate.

  Production code MUST use `delete_all/1` with the per-world tables map.
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
  Test-only counterpart to `create_all/0`: empties the 4 named tables.
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
