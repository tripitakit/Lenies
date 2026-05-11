defmodule Lenies.World do
  @moduledoc """
  Il "mondo" della sandbox Lenies. GenServer singleton che possiede le tabelle
  ETS, batte il tick ambientale, applica radiazione e decay carcasse, e fornisce
  API pubblica per snapshot e sterilizzazione.

  Vedi `docs/superpowers/specs/2026-05-11-lenies-design.md` §3, §6, §9.
  """

  use GenServer

  alias Lenies.Config
  alias Lenies.World.{Cell, Hotspots, Radiation, Tables}

  @name __MODULE__

  # ----- Public API -----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Statistiche rapide della sandbox per console/test."
  def snapshot_stats, do: GenServer.call(@name, :snapshot_stats)

  @doc "Forza un singolo tick sincrono (per test deterministici)."
  def tick_now, do: GenServer.call(@name, :tick_now)

  @doc "Reset completo: kill di tutti i Lenies, clear ETS, riavvio del tick."
  def sterilize, do: GenServer.call(@name, :sterilize)

  @doc """
  Esegue un'azione richiesta da un Lenie. Chiamata sincrona.

  Forms:
  - `{:sense_front, {x, y}, dir}` — restituisce `{:ok, :empty | {:resource, n} | {:lenie, id}}`
  - `{:move, {x, y}, dir, lenie_id}` — restituisce `{:ok, {:moved, {x2, y2}} | :blocked}`
  - `{:eat, {x, y}}` — restituisce `{:ok, {:ate, amount}}`
  """
  def action(action_spec), do: GenServer.call(@name, {:action, action_spec})

  # ----- Server -----

  @impl true
  def init(opts) do
    Tables.create_all()
    grid = Config.grid_size()
    init_cells(grid)

    tick_interval = Keyword.get(opts, :tick_interval_ms, Config.tick_interval_ms())
    hotspots = Hotspots.initial(grid, Config.hotspot_count())

    state = %{
      grid: grid,
      hotspots: hotspots,
      tick_interval_ms: tick_interval,
      tick_ref: nil,
      tick_count: 0
    }

    state = maybe_schedule_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot_stats, _from, state) do
    stats = %{
      cells: :ets.info(:cells, :size),
      population: :ets.info(:lenies, :size),
      total_resource: sum_cell_field(:resource),
      total_carcass: sum_cell_field(:carcass),
      tick_count: state.tick_count
    }

    {:reply, stats, state}
  end

  def handle_call(:tick_now, _from, state) do
    state = do_tick(state)
    {:reply, :ok, state}
  end

  def handle_call(:sterilize, _from, state) do
    terminate_all_lenies()
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    Tables.clear_all()
    init_cells(state.grid)
    hotspots = Hotspots.initial(state.grid, Config.hotspot_count())
    new_state = %{state | hotspots: hotspots, tick_count: 0, tick_ref: nil}
    new_state = maybe_schedule_tick(new_state)

    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "world:control",
      {:sterilized, System.system_time(:millisecond)}
    )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:action, action_spec}, _from, state) do
    {result, new_state} = do_action(action_spec, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    state = maybe_schedule_tick(%{state | tick_ref: nil})
    {:noreply, state}
  end

  # ----- internals -----

  defp init_cells({w, h}) do
    for x <- 0..(w - 1), y <- 0..(h - 1) do
      :ets.insert(:cells, {{x, y}, Cell.new()})
    end

    :ok
  end

  defp do_tick(state) do
    apply_radiation(state)
    apply_carcass_decay()

    hotspots = Hotspots.drift(state.hotspots, state.grid)

    Phoenix.PubSub.broadcast(
      Lenies.PubSub,
      "world:tick",
      {:tick, state.tick_count + 1}
    )

    %{state | hotspots: hotspots, tick_count: state.tick_count + 1}
  end

  defp apply_radiation(state) do
    deposit =
      Radiation.combined(
        state.grid,
        Config.radiation_per_tick(),
        state.hotspots,
        uniform_ratio: Config.radiation_uniform_ratio()
      )

    Enum.each(deposit, fn {{x, y}, amount} ->
      case :ets.lookup(:cells, {x, y}) do
        [{key, cell}] ->
          :ets.insert(:cells, {key, Cell.add_resource(cell, amount)})

        [] ->
          :ok
      end
    end)
  end

  defp apply_carcass_decay do
    rate = Config.carcass_decay()

    if rate > 0 do
      :ets.foldl(
        fn {key, cell}, _acc ->
          if cell.carcass > 0 do
            :ets.insert(:cells, {key, Cell.decay_carcass(cell, rate)})
          end

          nil
        end,
        nil,
        :cells
      )
    end
  end

  defp sum_cell_field(field) do
    :ets.foldl(
      fn {_key, cell}, acc -> acc + Map.get(cell, field, 0) end,
      0,
      :cells
    )
  end

  defp maybe_schedule_tick(%{tick_interval_ms: 0} = state), do: state
  defp maybe_schedule_tick(%{tick_interval_ms: nil} = state), do: state

  defp maybe_schedule_tick(state) do
    ref = Process.send_after(self(), :tick, state.tick_interval_ms)
    %{state | tick_ref: ref}
  end

  defp terminate_all_lenies do
    case Process.whereis(Lenies.LenieSupervisor) do
      nil ->
        :ok

      _pid ->
        Lenies.LenieSupervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_, child_pid, _, _} ->
          if is_pid(child_pid),
            do: DynamicSupervisor.terminate_child(Lenies.LenieSupervisor, child_pid)
        end)
    end
  end

  defp do_action({:sense_front, {x, y}, dir}, state) do
    front = front_cell({x, y}, dir, state.grid)

    case :ets.lookup(:cells, front) do
      [{_, cell}] ->
        result =
          cond do
            cell.lenie_id != nil -> {:lenie, cell.lenie_id}
            cell.resource > 0 -> {:resource, cell.resource}
            true -> :empty
          end

        {{:ok, result}, state}

      _ ->
        {{:ok, :empty}, state}
    end
  end

  defp do_action({:move, {x, y}, dir, lenie_id}, state) do
    front = front_cell({x, y}, dir, state.grid)

    case :ets.lookup(:cells, front) do
      [{_, %{lenie_id: nil} = front_cell}] ->
        # move successful
        [{src_key, src_cell}] = :ets.lookup(:cells, {x, y})
        :ets.insert(:cells, {src_key, %{src_cell | lenie_id: nil}})
        :ets.insert(:cells, {front, %{front_cell | lenie_id: lenie_id}})
        {{:ok, {:moved, front}}, state}

      _ ->
        {{:ok, :blocked}, state}
    end
  end

  defp do_action({:eat, {x, y}}, state) do
    case :ets.lookup(:cells, {x, y}) do
      [{key, cell}] ->
        eat_amount = Application.get_env(:lenies, :eat_amount, 20)
        taken = min(eat_amount, cell.resource)
        :ets.insert(:cells, {key, %{cell | resource: cell.resource - taken}})
        {{:ok, {:ate, taken}}, state}

      _ ->
        {{:ok, {:ate, 0}}, state}
    end
  end

  defp front_cell({x, y}, dir, {w, h}) do
    case dir do
      :n -> {x, Integer.mod(y - 1, h)}
      :e -> {Integer.mod(x + 1, w), y}
      :s -> {x, Integer.mod(y + 1, h)}
      :w -> {Integer.mod(x - 1, w), y}
    end
  end
end
