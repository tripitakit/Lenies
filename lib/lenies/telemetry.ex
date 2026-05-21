defmodule Lenies.Telemetry do
  @moduledoc """
  Collects tick events from the World and maintains a ring buffer in ETS (`:history`).

  Subscribes to `"world:tick"` via Phoenix.PubSub; on each `{:tick, n}` it
  computes an aggregated snapshot and stores it.
  """

  use GenServer

  alias Lenies.World

  @name __MODULE__
  @default_max_entries 10_000
  @species_per_snapshot 20

  # ----- Public API -----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def history(:all) do
    :ets.tab2list(:history)
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.sort_by(& &1.tick)
  end

  def history(:last_n, n) when is_integer(n) and n > 0 do
    history(:all) |> Enum.take(-n)
  end

  # ----- Server -----

  @impl true
  def init(opts) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
    Phoenix.PubSub.subscribe(Lenies.PubSub, "world:control")
    {:ok, %{max_entries: max_entries, counter: 0}}
  end

  @impl true
  def handle_info({:tick, tick_n}, state) do
    stats = World.snapshot_stats()

    entry = %{
      tick: tick_n,
      population: stats.population,
      total_resource: stats.total_resource,
      total_carcass: stats.total_carcass,
      cells: stats.cells,
      species: species_snapshot(),
      timestamp_ms: System.system_time(:millisecond)
    }

    :ets.insert(:history, {state.counter, entry})
    state = %{state | counter: state.counter + 1}
    state = enforce_ring_buffer(state)
    {:noreply, state}
  end

  def handle_info({:sterilized, _ts}, state) do
    :ets.delete_all_objects(:history)
    {:noreply, %{state | counter: 0}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Snapshot of populations for the top-K species at this tick.
  # Bounded to @species_per_snapshot to keep history entries small.
  defp species_snapshot do
    Lenies.Species.aggregate()
    |> Enum.take(@species_per_snapshot)
    |> Map.new(fn s -> {s.hash, s.population} end)
  end

  defp enforce_ring_buffer(state) do
    current_size = :ets.info(:history, :size)

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
        :ets.delete(:history, k)
      end)
    end

    state
  end
end
