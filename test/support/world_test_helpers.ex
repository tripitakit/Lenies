defmodule Lenies.WorldTestHelpers do
  @moduledoc ~S"""
  Shorthand helpers for tests that operate on the primary world's ETS tables.

  Pre-T6 tests freely accessed the per-world ETS tables by bare atom name
  (`:ets.lookup(:cells, ...)`) because the `:primary` world's tables were
  registered as `:named_table`. With that shim removed (T6), tables are
  unnamed tids held in the world's handle. Tests can either fetch the
  handle in setup —

      handle = Lenies.Worlds.primary_handle()
      :ets.insert(handle.tables.cells, ...)

  — or use these helpers, which look up the handle on each call.
  """

  @doc "ETS tid for the primary world's `:cells` table."
  def cells, do: Lenies.Worlds.primary_handle().tables.cells

  @doc "ETS tid for the primary world's `:lenies` table."
  def lenies, do: Lenies.Worlds.primary_handle().tables.lenies

  @doc "ETS tid for the primary world's `:child_slots` table."
  def child_slots, do: Lenies.Worlds.primary_handle().tables.child_slots

  @doc "ETS tid for the primary world's `:history` table."
  def history, do: Lenies.Worlds.primary_handle().tables.history
end
