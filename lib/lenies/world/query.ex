defmodule Lenies.World.Query do
  @moduledoc """
  Read-only query helpers over a world's ETS tables and process registry.

  Centralises the two things callers used to reach for directly:

    * the ETS table shapes — `handle.tables.cells` (`{x,y} => %{lenie_id: ...}`)
      and `handle.tables.lenies` (`id => snapshot map`);
    * the Registry key layout — `{:lenie, world_id, id}`.

  LiveViews and components should call these functions instead of touching
  `handle.tables.*` or `Lenies.Registry` so that a change to the storage
  layout stays contained in `Lenies.World.*` and never silently breaks the
  web tier.

  Every function is defensive: a torn-down world (the ETS table no longer
  exists) or a missing entry yields `:error` / `nil` / `0` rather than
  raising. This matters because LiveViews routinely hold a `%WorldHandle{}`
  whose tables can disappear under them when a world stops.
  """

  alias Lenies.WorldHandle

  @doc """
  The Lenie snapshot map stored at grid cell `{x, y}`, or `:error` if the
  cell is empty, the referenced Lenie has no record, or the world is gone.

  Accepts a `nil` handle (returns `:error`) so callers can pass an
  unmounted `world_handle` assign without guarding first.
  """
  @spec lenie_snap_at(WorldHandle.t() | nil, integer, integer) :: {:ok, map} | :error
  def lenie_snap_at(%WorldHandle{} = handle, x, y) do
    with [{_, %{lenie_id: id}}] when is_binary(id) <-
           :ets.lookup(handle.tables.cells, {x, y}),
         [{^id, snap}] <- :ets.lookup(handle.tables.lenies, id) do
      {:ok, snap}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def lenie_snap_at(_handle, _x, _y), do: :error

  @doc """
  The `codeome_hash` of the Lenie occupying `{x, y}`, or `:error`.

  Thin projection over `lenie_snap_at/3` for callers that only need the
  species identity at a cell (e.g. double-click-to-edit).
  """
  @spec codeome_hash_at(WorldHandle.t() | nil, integer, integer) :: {:ok, binary} | :error
  def codeome_hash_at(handle, x, y) do
    with {:ok, snap} <- lenie_snap_at(handle, x, y),
         hash when is_binary(hash) <- Map.get(snap, :codeome_hash) do
      {:ok, hash}
    else
      _ -> :error
    end
  end

  @doc """
  The Lenie snapshot map for `id`, looked up by id (not position), or
  `:error` if absent or the world is gone.
  """
  @spec lenie_snap(WorldHandle.t() | nil, term) :: {:ok, map} | :error
  def lenie_snap(%WorldHandle{} = handle, id) do
    case :ets.lookup(handle.tables.lenies, id) do
      [{^id, snap}] -> {:ok, snap}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def lenie_snap(_handle, _id), do: :error

  @doc """
  The number of live Lenie records in the world, or `0` if the table is
  unavailable. Used for spawn-cap checks; never raises.
  """
  @spec population(WorldHandle.t() | nil) :: non_neg_integer
  def population(%WorldHandle{} = handle) do
    :ets.info(handle.tables.lenies, :size) || 0
  rescue
    ArgumentError -> 0
  end

  def population(_handle), do: 0

  @doc """
  The pid of the running Lenie process `id` in `world_id`, or `nil` if it is
  not currently alive. Wraps the `{:lenie, world_id, id}` Registry key.
  """
  @spec lenie_pid(term, term) :: pid | nil
  def lenie_pid(world_id, id) do
    case Registry.lookup(Lenies.Registry, {:lenie, world_id, id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  catch
    :exit, _ -> nil
  end
end
