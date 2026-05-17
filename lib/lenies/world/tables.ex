defmodule Lenies.World.Tables do
  @moduledoc """
  Creates and manages the project's ETS tables.

  Ownership convention: the caller (`Lenies.World` in production) must invoke
  `create_all/0` from its `init/1` to become the owner of the tables. All
  tables are `:set`, `:named_table`, `:public`.

  Tables:
  - `:cells`        — `{x,y} → %Lenies.World.Cell{}` (source of truth for occupancy)
  - `:lenies`       — `id    → snapshot` (written mainly by Lenies, with exceptions by World)
  - `:child_slots`  — `slot  → gestation record`
  - `:history`      — ring buffer of aggregated metrics (written by Telemetry)
  """

  @tables [:cells, :lenies, :child_slots, :history]

  def tables, do: @tables

  def create_all do
    for t <- @tables do
      :ets.new(t, [:set, :named_table, :public, read_concurrency: true, write_concurrency: true])
    end

    :ok
  end

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
