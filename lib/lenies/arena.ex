defmodule Lenies.Arena do
  @moduledoc """
  Lifecycle manager for the single, publicly-viewable `:arena` world.

  Mirrors `Lenies.Sandboxes` but for a singleton world: attach on
  `LeniesWeb.ArenaLive` mount, `Process.monitor` the viewer pid,
  30 s grace timer on last detach, snapshot+stop on expiry, auto-restore
  from the `"auto"` snapshot on next first attach.

  Beyond lifecycle, owns the Arena's domain rules:

  - `seed/2` — atomic check-and-spawn (one alive lineage per user).
  - `apoptosis/1` — user-triggered self-terminate of their lineage.
  - `lineage_count/1` — count of a user's alive Lenies in the Arena.

  See `docs/superpowers/specs/2026-05-29-global-arena-design.md`.
  """
  use GenServer

  @world_id :arena
  @grace_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Attach the calling viewer pid to the Arena. Idempotent; starts the world on first attach."
  @spec attach_viewer(pid) :: :ok | {:error, term}
  def attach_viewer(pid \\ self()), do: GenServer.call(__MODULE__, {:attach_viewer, pid})

  @doc "Explicit detach. Usually unnecessary — :DOWN handles disconnect."
  @spec detach_viewer(pid) :: :ok
  def detach_viewer(pid \\ self()), do: GenServer.cast(__MODULE__, {:detach_viewer, pid})

  @impl true
  def init(_opts), do: {:ok, initial_state()}

  defp initial_state do
    %{
      started?: false,
      viewers: MapSet.new(),
      monitors: %{},
      pending_stop: nil,
      generation: 0
    }
  end

  @impl true
  def handle_call({:attach_viewer, pid}, _from, %{started?: false} = state) do
    case start_arena() do
      {:ok, _sup_pid} ->
        ref = Process.monitor(pid)

        new_state = %{
          state
          | started?: true,
            viewers: MapSet.put(state.viewers, pid),
            monitors: Map.put(state.monitors, pid, ref),
            generation: state.generation + 1
        }

        {:reply, :ok, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:attach_viewer, pid}, _from, %{started?: true} = state) do
    new_state =
      if MapSet.member?(state.viewers, pid) do
        %{state | generation: state.generation + 1}
      else
        ref = Process.monitor(pid)

        %{
          state
          | viewers: MapSet.put(state.viewers, pid),
            monitors: Map.put(state.monitors, pid, ref),
            generation: state.generation + 1
        }
      end

    {:reply, :ok, cancel_pending_stop(new_state)}
  end

  @impl true
  def handle_cast({:detach_viewer, pid}, state), do: {:noreply, remove_viewer(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, remove_viewer(state, pid)}
  end

  @impl true
  def handle_info({:maybe_stop, gen}, state) do
    cond do
      state.generation != gen ->
        # Generation changed (re-attach refreshed lifecycle). Ignore.
        {:noreply, state}

      MapSet.size(state.viewers) > 0 ->
        # New attaches since grace was scheduled. Ignore.
        {:noreply, state}

      true ->
        auto_save()
        _ = Lenies.Worlds.stop_world(@world_id)
        {:noreply, initial_state()}
    end
  end

  defp auto_save do
    case Lenies.Worlds.save_snapshot(@world_id, "auto") do
      :ok ->
        :ok

      :error ->
        # World already gone (race with manual stop). No-op.
        :ok

      {:error, reason} ->
        require Logger
        Logger.error("Lenies.Arena: auto-snapshot save failed: #{inspect(reason)}")
        :ok
    end
  end

  defp start_arena do
    case Lenies.Worlds.start_world(@world_id, %{}) do
      {:ok, sup_pid} ->
        maybe_auto_restore()
        {:ok, sup_pid}

      {:error, {:already_started, sup_pid}} ->
        {:ok, sup_pid}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_auto_restore do
    case Lenies.Snapshot.validate(@world_id, "auto") do
      :ok ->
        case Lenies.Worlds.restore_snapshot(@world_id, "auto") do
          :ok ->
            :ok

          {:error, reason} ->
            quarantine_broken_auto(reason)
            :ok
        end

      {:error, :missing_file} ->
        if auto_dir_exists?(), do: quarantine_broken_auto(:missing_file), else: :ok

      {:error, reason} ->
        quarantine_broken_auto(reason)
        :ok
    end
  end

  defp auto_dir_exists? do
    root = Lenies.Snapshot.snapshot_root()
    Path.join([root, Lenies.Worlds.id_to_path(@world_id), "auto"]) |> File.dir?()
  end

  defp quarantine_broken_auto(reason) do
    require Logger

    root = Lenies.Snapshot.snapshot_root()
    dir = Path.join([root, Lenies.Worlds.id_to_path(@world_id), "auto"])

    if File.dir?(dir) do
      broken =
        Path.join([
          root,
          Lenies.Worlds.id_to_path(@world_id),
          "auto.broken.#{System.system_time(:second)}"
        ])

      File.rename(dir, broken)

      Logger.warning(
        "Lenies.Arena: auto snapshot quarantined as #{broken} (#{inspect(reason)})"
      )
    end

    :ok
  end

  defp cancel_pending_stop(%{pending_stop: nil} = state), do: state

  defp cancel_pending_stop(%{pending_stop: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | pending_stop: nil}
  end

  defp remove_viewer(state, pid) do
    if MapSet.member?(state.viewers, pid) do
      new_viewers = MapSet.delete(state.viewers, pid)
      new_monitors = Map.delete(state.monitors, pid)
      new_state = %{state | viewers: new_viewers, monitors: new_monitors}

      if MapSet.size(new_viewers) == 0 and state.started? do
        schedule_grace_stop(new_state)
      else
        new_state
      end
    else
      state
    end
  end

  defp schedule_grace_stop(state) do
    ref =
      Process.send_after(
        self(),
        {:maybe_stop, state.generation},
        grace_ms()
      )

    %{state | pending_stop: ref}
  end

  defp grace_ms, do: Application.get_env(:lenies, :arena_grace_ms, @grace_ms)
end
