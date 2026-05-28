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

  @doc """
  Explicit detach from the user's sandbox. Useful in tests and for graceful
  disconnect from a LiveView's terminate/2 (though :DOWN handles the common
  case automatically).
  """
  @spec detach(integer) :: :ok
  def detach(user_id) when is_integer(user_id) do
    GenServer.cast(__MODULE__, {:detach, user_id, self()})
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

  @impl true
  def handle_cast({:detach, user_id, pid}, state) do
    case Map.get(state, user_id) do
      nil -> {:noreply, state}
      %{} -> {:noreply, remove_pid(state, user_id, pid)}
    end
  end

  defp start_sandbox(user_id) do
    world_id = world_id_for(user_id)

    case Lenies.Worlds.start_world(world_id, %{}) do
      {:ok, sup_pid} ->
        maybe_auto_restore(world_id)
        {:ok, sup_pid}

      {:error, {:already_started, sup_pid}} ->
        {:ok, sup_pid}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_auto_restore(world_id) do
    case Lenies.Snapshot.validate(world_id, "auto") do
      :ok ->
        case Lenies.Worlds.restore_snapshot(world_id, "auto") do
          :ok ->
            :ok

          {:error, reason} ->
            quarantine_broken_auto(world_id, reason)
            :ok
        end

      {:error, :missing_file} ->
        # If the auto/ directory exists but is missing required files, it's
        # corrupt/partial — quarantine it. If the directory doesn't exist at
        # all, this is the common "no snapshot yet" path: fresh empty world.
        if auto_dir_exists?(world_id) do
          quarantine_broken_auto(world_id, :missing_file)
        end

        :ok

      {:error, reason} ->
        quarantine_broken_auto(world_id, reason)
        :ok
    end
  end

  defp auto_dir_exists?(world_id) do
    root = Application.get_env(:lenies, :snapshot_root, System.tmp_dir!())
    File.dir?(Path.join([root, Lenies.Worlds.id_to_path(world_id), "auto"]))
  end

  defp quarantine_broken_auto(world_id, reason) do
    require Logger

    root = Application.get_env(:lenies, :snapshot_root, System.tmp_dir!())
    dir = Path.join([root, Lenies.Worlds.id_to_path(world_id), "auto"])

    if File.dir?(dir) do
      broken =
        Path.join([
          root,
          Lenies.Worlds.id_to_path(world_id),
          "auto.broken.#{System.system_time(:second)}"
        ])

      File.rename(dir, broken)

      Logger.warning(
        "Lenies.Sandboxes: auto snapshot for #{inspect(world_id)} quarantined as #{broken} (#{inspect(reason)})"
      )
    end

    :ok
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

  @impl true
  def handle_info({:maybe_stop, user_id, gen}, state) do
    case state[user_id] do
      nil ->
        # User entry already gone (e.g. a manual stop_world from elsewhere). No-op.
        {:noreply, state}

      %{generation: ^gen} = entry ->
        if MapSet.size(entry.connections) == 0 do
          auto_save(user_id)
          _ = Lenies.Worlds.stop_world({:sandbox, user_id})
          {:noreply, Map.delete(state, user_id)}
        else
          # New attaches arrived but the generation didn't change (unlikely, but be defensive).
          {:noreply, state}
        end

      _other ->
        # Generation has changed (a re-attach refreshed lifecycle). Ignore.
        {:noreply, state}
    end
  end

  defp auto_save(user_id) do
    case Lenies.Worlds.save_snapshot({:sandbox, user_id}, "auto") do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.error(
          "Lenies.Sandboxes: auto-snapshot save failed for user #{user_id}: #{inspect(reason)}"
        )

        :ok
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
