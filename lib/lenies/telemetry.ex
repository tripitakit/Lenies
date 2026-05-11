defmodule Lenies.Telemetry do
  @moduledoc """
  Raccoglie eventi di tick dal World e mantiene un ring buffer in ETS (`:history`).

  Sottoscrive `"world:tick"` via Phoenix.PubSub; ad ogni `{:tick, n}` calcola
  uno snapshot aggregato e lo memorizza. Sponsorizza la GUI futura (sotto-progetto 5).
  """

  use GenServer

  alias Lenies.World

  @name __MODULE__
  @default_max_entries 10_000

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

  defp enforce_ring_buffer(state) do
    current_size = :ets.info(:history, :size)

    if current_size > state.max_entries do
      # rimuovi le entry più vecchie (counter più basso)
      to_remove = current_size - state.max_entries

      :ets.tab2list(:history)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.take(to_remove)
      |> Enum.each(fn {k, _} -> :ets.delete(:history, k) end)
    end

    state
  end
end
