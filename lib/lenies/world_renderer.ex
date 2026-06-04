defmodule Lenies.WorldRenderer do
  @moduledoc """
  Per-world canvas frame encoder. Subscribes to its world's `:tick` and
  `:control` PubSub topics, encodes the grid into transport-ready binary
  layers (via `Lenies.WorldFrame`) at the dashboard throttle cadence, and
  broadcasts the result on the world's `:frame` topic.

  ## Why a dedicated process

  Encoding a 128×128 grid is the single most expensive operation on the UI
  path. Doing it inside each LiveView socket meant **N** independent encodes
  per frame (one per viewer) — on the Arena, with several spectators, that
  saturated the scheduler and made every click queue behind a heavy encode
  in the socket's mailbox.

  Doing it inside the `World` GenServer would instead serialise the encode
  with the simulation's `handle_call`s (spawn / tune / pause), so those
  clicks would lag.

  A separate per-world process isolates the encode from **both**: the World
  keeps answering calls, the sockets keep handling clicks, and the frame is
  computed exactly once per cadence regardless of viewer count. Runs at
  `:priority, :low` so the web tier always preempts it.

  Registered via `{:via, Registry, {Lenies.Registry, {:renderer, world_id}}}`.
  """

  use GenServer

  alias Lenies.{Config, WorldFrame}

  # ----- Public API -----

  def start_link(opts) do
    world_id = Keyword.fetch!(opts, :world_id)
    GenServer.start_link(__MODULE__, {world_id, opts}, name: via(world_id))
  end

  @doc "Via-tuple name for the renderer of `world_id`."
  def via(world_id),
    do: {:via, Registry, {Lenies.Registry, {:renderer, world_id}}}

  @doc """
  Latest encoded frame, for instant paint on LiveView mount (the canvas would
  otherwise stay black until the next throttled tick). Encodes one on demand
  if none is cached yet. Returns `nil` if the renderer isn't running.
  """
  @spec current_frame(term()) :: map() | nil
  def current_frame(world_id) do
    GenServer.call(via(world_id), :current_frame)
  catch
    :exit, _ -> nil
  end

  # ----- Server -----

  @impl true
  def init({world_id, opts}) do
    # Frame encoding is presentation, not gameplay — keep it below the
    # :normal-priority web tier so HTTP/LiveView/PubSub always preempt it.
    Process.flag(:priority, :low)

    throttle =
      Keyword.get(
        opts,
        :throttle_ticks,
        Application.get_env(:lenies, :dashboard_throttle_ticks, 5)
      )

    handle =
      case fetch_handle(world_id) do
        {:ok, h} -> h
        :error -> nil
      end

    prefix =
      if handle, do: handle.pubsub_prefix, else: "world:" <> Lenies.Worlds.id_to_path(world_id)

    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:tick")
    Phoenix.PubSub.subscribe(Lenies.PubSub, "#{prefix}:control")

    {:ok,
     %{
       world_id: world_id,
       handle: handle,
       prefix: prefix,
       throttle: max(throttle, 1),
       counter: 0,
       frame: nil
     }}
  end

  @impl true
  def handle_call(:current_frame, _from, state) do
    state = ensure_handle(state)
    frame = state.frame || encode(state)
    {:reply, frame, %{state | frame: frame}}
  end

  @impl true
  def handle_info({:tick, _n, _stats}, state) do
    state = ensure_handle(state)
    counter = state.counter + 1
    state = %{state | counter: counter}

    if rem(counter, state.throttle) == 0 do
      {:noreply, encode_and_broadcast(state)}
    else
      {:noreply, state}
    end
  end

  # Sterilize / restore can fire while the world is paused (no upcoming tick
  # to drive the normal cadence), so encode + broadcast immediately to keep
  # viewers' canvases in sync.
  def handle_info({:sterilized, _ts}, state),
    do: {:noreply, encode_and_broadcast(ensure_handle(state))}

  def handle_info({:restored, _ts, _stats}, state),
    do: {:noreply, encode_and_broadcast(ensure_handle(state))}

  def handle_info(_msg, state), do: {:noreply, state}

  defp encode_and_broadcast(state) do
    frame = encode(state)
    Phoenix.PubSub.broadcast(Lenies.PubSub, "#{state.prefix}:frame", {:frame, frame})
    %{state | frame: frame}
  end

  defp encode(state), do: WorldFrame.encode_payload(state.handle, Config.grid_size())

  # World may have restarted (tids inside the cached handle are dead): if the
  # cached handle points at a dead table OR is nil, refresh it. Mirrors
  # `Lenies.Telemetry.ensure_handle/1`.
  defp ensure_handle(%{handle: %{tables: %{cells: tid}}} = state) do
    if :ets.info(tid, :size) != :undefined do
      state
    else
      refresh_handle(state)
    end
  end

  defp ensure_handle(state), do: refresh_handle(state)

  defp refresh_handle(state) do
    case fetch_handle(state.world_id) do
      {:ok, h} -> %{state | handle: h, prefix: h.pubsub_prefix}
      :error -> state
    end
  end

  defp fetch_handle(world_id) do
    Lenies.Worlds.handle(world_id)
  catch
    :exit, _ -> :error
  end
end
