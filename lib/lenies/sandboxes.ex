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

  @grace_ms 30_000

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

      %{} = entry ->
        new_entry =
          entry
          |> add_connection(pid)
          |> cancel_pending_stop()
          |> bump_generation()
        {:reply, :ok, Map.put(state, user_id, new_entry)}
    end
  end

  defp start_sandbox(user_id) do
    case Lenies.Worlds.start_world(world_id_for(user_id), %{}) do
      {:ok, sup_pid} -> {:ok, sup_pid}
      {:error, {:already_started, sup_pid}} -> {:ok, sup_pid}
      {:error, _} = err -> err
    end
  end

  defp add_connection(entry, pid) do
    if MapSet.member?(entry.connections, pid) do
      entry
    else
      ref = Process.monitor(pid)
      %{entry |
        connections: MapSet.put(entry.connections, pid),
        monitors: Map.put(entry.monitors, pid, ref)}
    end
  end

  defp cancel_pending_stop(%{pending_stop: nil} = entry), do: entry
  defp cancel_pending_stop(%{pending_stop: ref} = entry) do
    _ = Process.cancel_timer(ref)
    %{entry | pending_stop: nil}
  end

  defp bump_generation(entry), do: %{entry | generation: entry.generation + 1}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case find_user_for_pid(state, pid) do
      nil -> {:noreply, state}
      user_id -> {:noreply, remove_pid(state, user_id, pid)}
    end
  end

  defp find_user_for_pid(state, pid) do
    Enum.find_value(state, fn {user_id, entry} ->
      if MapSet.member?(entry.connections, pid), do: user_id
    end)
  end

  defp remove_pid(state, user_id, pid) do
    entry = state[user_id]
    new_connections = MapSet.delete(entry.connections, pid)
    new_monitors = Map.delete(entry.monitors, pid)
    new_entry = %{entry | connections: new_connections, monitors: new_monitors}

    new_entry =
      if MapSet.size(new_connections) == 0 do
        schedule_grace_stop(new_entry, user_id)
      else
        new_entry
      end

    Map.put(state, user_id, new_entry)
  end

  defp schedule_grace_stop(entry, user_id) do
    ref =
      Process.send_after(
        self(),
        {:maybe_stop, user_id, entry.generation},
        grace_ms()
      )
    %{entry | pending_stop: ref}
  end

  defp grace_ms, do: Application.get_env(:lenies, :sandbox_grace_ms, @grace_ms)
end
