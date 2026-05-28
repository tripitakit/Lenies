defmodule Lenies.Sandboxes do
  @moduledoc """
  Per-user sandbox lifecycle manager.

  Each logged-in user has exactly one sandbox — a `Lenies.Worlds`
  instance keyed `{:sandbox, user.id}` — that lives only while the user
  is connected. The first LiveView mount attaches; subsequent mounts
  (multi-tab, editor + dashboard) share the same world. The last
  disconnect schedules a grace-period timer; if no re-attach happens
  within that window, the world auto-snapshots to disk and stops. The
  next connection auto-restores from that snapshot.

  See `docs/superpowers/specs/2026-05-28-personal-sandbox-design.md`.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the world id for a user id. Pure helper."
  @spec world_id_for(integer) :: {:sandbox, integer}
  def world_id_for(user_id) when is_integer(user_id), do: {:sandbox, user_id}

  @doc """
  Attach the calling LiveView pid to `user_id`'s sandbox. Ensures the world is
  running (starting it and auto-restoring from snapshot if needed) and
  monitors the caller so disconnect is detected automatically.
  """
  @spec attach(integer) :: :ok | {:error, term}
  def attach(user_id) when is_integer(user_id) do
    GenServer.call(__MODULE__, {:attach, user_id, self()})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:attach, user_id, pid}, _from, state) do
    case Map.get(state, user_id) do
      nil ->
        case start_sandbox(user_id) do
          {:ok, _world_pid} ->
            ref = Process.monitor(pid)
            entry = %{
              world_id: world_id_for(user_id),
              connections: MapSet.new([pid]),
              monitors: %{pid => ref},
              pending_stop: nil,
              generation: 1
            }
            {:reply, :ok, Map.put(state, user_id, entry)}
          {:error, _} = err ->
            {:reply, err, state}
        end

      %{} = _entry ->
        # Already attached (Task 3 will handle this properly); reply :ok for now.
        {:reply, :ok, state}
    end
  end

  defp start_sandbox(user_id) do
    case Lenies.Worlds.start_world(world_id_for(user_id), %{}) do
      {:ok, sup_pid} -> {:ok, sup_pid}
      {:error, {:already_started, sup_pid}} -> {:ok, sup_pid}
      {:error, _} = err -> err
    end
  end
end
