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

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Attach the calling viewer pid to the Arena. Idempotent; starts the world on first attach."
  @spec attach_viewer(pid) :: :ok | {:error, term}
  def attach_viewer(pid \\ self()), do: GenServer.call(__MODULE__, {:attach_viewer, pid})

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

  defp start_arena do
    case Lenies.Worlds.start_world(@world_id, %{}) do
      {:ok, sup_pid} -> {:ok, sup_pid}
      {:error, {:already_started, sup_pid}} -> {:ok, sup_pid}
      {:error, _} = err -> err
    end
  end

  defp cancel_pending_stop(%{pending_stop: nil} = state), do: state

  defp cancel_pending_stop(%{pending_stop: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | pending_stop: nil}
  end
end
