defmodule Lenies.WorldTestHelpers do
  @moduledoc ~S"""
  Shorthand helpers for tests that operate on the primary world's ETS tables
  and processes.

  Pre-T6 tests freely accessed the per-world ETS tables by bare atom name
  (`:ets.lookup(:cells, ...)`) because the `:primary` world's tables were
  registered as `:named_table`. With that shim removed (T6), tables are
  unnamed tids held in the world's handle. Tests can either fetch the
  handle in setup —

      {:ok, handle} = Lenies.Worlds.handle(:primary)
      :ets.insert(handle.tables.cells, ...)

  — or use these helpers, which look up the handle on each call.

  Post-T10 the `:primary` World is registered only via
  `{:via, Registry, {Lenies.Registry, {:world, :primary}}}`, NOT the global
  atom `Lenies.World`. Tests that previously called
  `Process.whereis(Lenies.World)` to check liveness should call
  `world_pid/0` instead; same for the per-world LenieSupervisor and
  Telemetry.
  """

  @doc "ETS tid for the primary world's `:cells` table."
  def cells, do: primary_handle().tables.cells

  @doc "ETS tid for the primary world's `:lenies` table."
  def lenies, do: primary_handle().tables.lenies

  @doc "ETS tid for the primary world's `:child_slots` table."
  def child_slots, do: primary_handle().tables.child_slots

  @doc "ETS tid for the primary world's `:history` table."
  def history, do: primary_handle().tables.history

  # Fetch the :primary world's handle, raising if the world isn't running.
  # Test-internal helper — production code should use Lenies.Worlds.handle/1
  # and match on the {:ok, _} | :error result.
  defp primary_handle do
    case Lenies.Worlds.handle(:primary) do
      {:ok, h} -> h
      :error -> raise "Lenies.WorldTestHelpers: :primary world is not running"
    end
  end

  @doc "Pid of the running `:primary` World GenServer, or nil if not running."
  def world_pid do
    case Registry.lookup(Lenies.Registry, {:world, :primary}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Pid of the running `:primary` LenieSupervisor, or nil if not running."
  def lenie_sup_pid do
    case Registry.lookup(Lenies.Registry, {:lenie_sup, :primary}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Pid of the running `:primary` Telemetry, or nil if not running."
  def telemetry_pid do
    case Registry.lookup(Lenies.Registry, {:telemetry, :primary}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Start the full `:primary` world (World + per-world LenieSupervisor +
  Telemetry) the way `Lenies.Application` does in production, via
  `Lenies.Worlds.start_world(:primary, …)`.

  Returns the World GenServer pid (NOT the per-world supervisor pid) so
  existing tests that match `{:ok, _world} = World.start_link(...)` can
  simply replace the right-hand side with a call to this helper and the
  semantics line up. The whole sub-tree is torn down in `on_exit` via
  `stop_primary/0`.

  Idempotent: if the primary world is already running, returns the
  existing World pid.
  """
  def start_primary(config_overrides \\ %{tick_interval_ms: 0}) do
    case Lenies.Worlds.start_world(:primary, config_overrides) do
      {:ok, _sup_pid} -> {:ok, world_pid()}
      {:error, {:already_started, _sup_pid}} -> {:ok, world_pid()}
    end
  end

  @doc """
  Stop the full `:primary` world tree (Supervisor + World +
  LenieSupervisor + Telemetry) and clean up named-table fixtures.
  Idempotent.
  """
  def stop_primary do
    Lenies.Worlds.stop_world(:primary)
    Lenies.World.Tables.delete_all()
    :ok
  end
end
