defmodule Lenies.Telemetry do
  @moduledoc """
  Per-world telemetry collector. Subscribes to its world's `:tick` and
  `:control` PubSub topics and maintains a ring buffer in the world's
  `history` ETS table.

  Registered via `{:via, Registry, {Lenies.Registry, {:telemetry, world_id}}}`.

  ## Compat shim (removed in Task 10)

  The `:primary` world's Telemetry is ALSO registered under the global atom
  name `Lenies.Telemetry` so legacy callers (`:sys.get_state(Lenies.Telemetry)`,
  `Lenies.Telemetry.history/1`) keep working during the transition. All other
  worlds register only under the via-Registry tuple.
  """

  use GenServer

  @default_max_entries 10_000
  @species_per_snapshot 20

  # ----- Public API -----

  def start_link(opts \\ []) do
    world_id = Keyword.get(opts, :world_id, :primary)
    init_arg = {world_id, opts}

    case GenServer.start_link(__MODULE__, init_arg, name: via(world_id)) do
      {:ok, pid} = ok ->
        # Compat shim (removed in Task 10): the `:primary` world's Telemetry
        # is ALSO registered under the global atom name `Lenies.Telemetry`.
        if world_id == :primary do
          try do
            Process.register(pid, __MODULE__)
          rescue
            ArgumentError -> :ok
          end
        end

        ok

      other ->
        other
    end
  end

  @doc """
  Via-tuple name for the Telemetry of `world_id`.
  """
  def via(world_id),
    do: {:via, Registry, {Lenies.Registry, {:telemetry, world_id}}}

  def history(:all) do
    case fetch_handle(:primary) do
      {:ok, handle} ->
        :ets.tab2list(handle.tables.history)
        |> Enum.map(fn {_k, v} -> v end)
        |> Enum.sort_by(& &1.tick)

      :error ->
        []
    end
  end

  def history(:last_n, n) when is_integer(n) and n > 0 do
    history(:all) |> Enum.take(-n)
  end

  # ----- Server -----

  @impl true
  def init({world_id, opts}) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    # Cache this world's handle so we don't pay a GenServer.call on every
    # tick. The handle struct is immutable; the tids inside survive World
    # restarts only if the GenServer crashes, in which case Telemetry would
    # be restarted by its supervisor and re-read the handle here.
    handle =
      case fetch_handle(world_id) do
        {:ok, h} -> h
        :error -> nil
      end

    pubsub_prefix =
      if handle, do: handle.pubsub_prefix, else: "world:" <> Lenies.Worlds.id_to_path(world_id)

    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{pubsub_prefix}:tick")
    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{pubsub_prefix}:control")

    {:ok,
     %{world_id: world_id, max_entries: max_entries, counter: 0, handle: handle}}
  end

  @impl true
  def handle_info({:tick, tick_n}, state) do
    state = ensure_handle(state)
    stats = GenServer.call(state.handle.pid, :snapshot_stats)

    entry = %{
      tick: tick_n,
      population: stats.population,
      total_resource: stats.total_resource,
      total_carcass: stats.total_carcass,
      cells: stats.cells,
      species: species_snapshot(),
      timestamp_ms: System.system_time(:millisecond)
    }

    :ets.insert(state.handle.tables.history, {state.counter, entry})
    state = %{state | counter: state.counter + 1}
    state = enforce_ring_buffer(state)
    {:noreply, state}
  end

  def handle_info({:sterilized, _ts}, state) do
    state = ensure_handle(state)
    :ets.delete_all_objects(state.handle.tables.history)
    {:noreply, %{state | counter: 0}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # World may have restarted (tids inside the cached handle are dead): if
  # the cached one points at a dead table OR is nil, refresh it.
  defp ensure_handle(%{handle: %{tables: %{history: tid}}} = state) do
    if :ets.info(tid, :size) != :undefined do
      state
    else
      refresh_handle(state)
    end
  end

  defp ensure_handle(state), do: refresh_handle(state)

  defp refresh_handle(state) do
    case fetch_handle(state.world_id) do
      {:ok, h} -> %{state | handle: h}
      :error -> state
    end
  end

  defp fetch_handle(world_id) do
    try do
      Lenies.Worlds.handle(world_id)
    catch
      :exit, _ -> :error
    end
  end

  # Snapshot of populations for the top-K species at this tick.
  # Bounded to @species_per_snapshot to keep history entries small.
  defp species_snapshot do
    Lenies.Species.aggregate()
    |> Enum.take(@species_per_snapshot)
    |> Map.new(fn s -> {s.hash, s.population} end)
  end

  defp enforce_ring_buffer(state) do
    current_size = :ets.info(state.handle.tables.history, :size)

    if current_size > state.max_entries do
      # Contiguity invariant: keys are a contiguous range [oldest, counter-1].
      # The counter is incremented after each insert and reset to 0 on
      # {:sterilized, _} (which also clears :history). Entries are evicted only
      # from the bottom of the range (oldest first), never from the middle.
      # Therefore: oldest_key = counter - current_size, and we can evict the
      # `to_remove` lowest keys without scanning the table — O(to_remove) instead
      # of O(n log n).
      to_remove = current_size - state.max_entries
      oldest = state.counter - current_size

      Enum.each(oldest..(oldest + to_remove - 1), fn k ->
        :ets.delete(state.handle.tables.history, k)
      end)
    end

    state
  end
end
