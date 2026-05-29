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

  @doc "Count of Lenies in the Arena whose seeder_user_id matches `user_id`."
  @spec lineage_count(integer) :: non_neg_integer()
  def lineage_count(user_id) when is_integer(user_id) do
    case Lenies.Worlds.handle(@world_id) do
      {:ok, handle} ->
        ms = [
          {{:_, %{seeder_user_id: :"$1"}}, [{:==, :"$1", user_id}], [true]}
        ]

        :ets.select_count(handle.tables.lenies, ms)

      :error ->
        0
    end
  end

  @doc """
  Atomically check the user's lineage count and (if 0) spawn one Lenie from their
  collection into the Arena.
  """
  @spec seed(map(), integer | binary) ::
          {:ok, :seeded}
          | {:error, :lineage_alive, non_neg_integer()}
          | {:error, term}
  def seed(user, codeome_id), do: GenServer.call(__MODULE__, {:seed, user, codeome_id})

  @doc """
  Kills all Lenies in the Arena whose seeder_user_id matches `user.id`.
  Returns `{:ok, count_killed}`. Idempotent.

  Terminates each Lenie process via `DynamicSupervisor.terminate_child/2`, then
  posts `:lenie_died` to the World on each Lenie's behalf so the cell is freed
  and a carcass is left — mirroring the natural death path. (Lenie doesn't
  trap exits, so terminate/2 is bypassed by a supervisor shutdown; we send
  the cast ourselves to keep the world consistent.)
  """
  @spec apoptosis(map()) :: {:ok, non_neg_integer()}
  def apoptosis(user), do: GenServer.call(__MODULE__, {:apoptosis, user})

  @impl true
  def init(_opts) do
    state =
      if Lenies.Worlds.alive?(@world_id) do
        ref = Process.send_after(self(), {:maybe_stop, 1}, grace_ms())

        %{
          started?: true,
          viewers: MapSet.new(),
          monitors: %{},
          pending_stop: ref,
          generation: 1
        }
      else
        initial_state()
      end

    Phoenix.PubSub.broadcast(Lenies.PubSub, "arena:manager_up", :arena_manager_up)
    {:ok, state}
  end

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

  def handle_call({:attach_viewer, pid}, from, %{started?: true} = state) do
    if Lenies.Worlds.alive?(@world_id) do
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
    else
      # World died externally (operator stop, crash). Demonitor any stale
      # viewer refs, reset to cold-start state, and re-handle so the world
      # is brought back up.
      Enum.each(state.monitors, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)

      reset =
        cancel_pending_stop(%{state | started?: false, viewers: MapSet.new(), monitors: %{}})

      handle_call({:attach_viewer, pid}, from, reset)
    end
  end

  def handle_call({:seed, user, codeome_id}, _from, state) do
    reply = do_seed(user, codeome_id)
    {:reply, reply, state}
  end

  def handle_call({:apoptosis, user}, _from, state) do
    count =
      case Lenies.Worlds.handle(@world_id) do
        {:ok, handle} ->
          # Grab id + the fields needed to post `:lenie_died` on the Lenie's
          # behalf (pos, energy, codeome_hash). Lenie doesn't trap exits, so
          # a supervisor shutdown bypasses its terminate/2 — we replay the
          # cast ourselves to keep the World/ETS state consistent.
          ms = [
            {{:"$1", %{seeder_user_id: :"$2", pos: :"$3", energy: :"$4", codeome_hash: :"$5"}},
             [{:==, :"$2", user.id}], [{{:"$1", :"$3", :"$4", :"$5"}}]}
          ]

          rows = :ets.select(handle.tables.lenies, ms)
          sup = Lenies.LenieSupervisor.via(@world_id)

          Enum.reduce(rows, 0, fn {id, pos, energy, hash}, acc ->
            case Registry.lookup(Lenies.Registry, {:lenie, @world_id, id}) do
              [{pid, _}] ->
                _ = DynamicSupervisor.terminate_child(sup, pid)
                GenServer.cast(handle.pid, {:lenie_died, id, pos, energy, hash})
                acc + 1

              [] ->
                acc
            end
          end)

        :error ->
          0
      end

    {:reply, {:ok, count}, state}
  end

  defp do_seed(user, codeome_id) do
    with %Lenies.Collection.Codeome{} = entry <- Lenies.Collection.get_codeome(user, codeome_id),
         {:ok, handle} <- Lenies.Worlds.handle(@world_id),
         0 <- lineage_count(user.id) do
      codeome = Lenies.Codeome.from_list(Lenies.Collection.to_opcode_atoms(entry))
      hash = Lenies.Codeome.hash(codeome)
      Lenies.SpeciesColor.set_override(handle, hash, entry.color_hex)

      opts = [
        energy: entry.energy_default,
        dir: Enum.random([:n, :s, :e, :w]),
        seeder_user_id: user.id,
        seed_origin: "★ " <> entry.name
      ]

      case Lenies.Worlds.spawn_lenie(@world_id, codeome, opts) do
        {:ok, {_id, _pos}} -> {:ok, :seeded}
        {:error, _} = err -> err
      end
    else
      nil -> {:error, :not_found}
      count when is_integer(count) and count > 0 -> {:error, :lineage_alive, count}
      :error -> {:error, :arena_not_running}
      {:error, _} = err -> err
    end
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

      Logger.warning("Lenies.Arena: auto snapshot quarantined as #{broken} (#{inspect(reason)})")
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
