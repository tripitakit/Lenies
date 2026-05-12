defmodule LeniesWeb.DashboardLive do
  @moduledoc """
  Main dashboard for monitoring the Lenies sandbox.

  Four panels (per spec §7.1):
  1. World (canvas 512×512 with 3 toggleable layers)
  2. Telemetry (population over time)
  3. Species (top-N table)
  4. Controls (delegated to LeniesWeb.ControlsPanelComponent — see file)

  Only the world canvas and telemetry/species panels re-render on tick;
  controls live in a LiveComponent so form/input state is preserved.
  """

  use LeniesWeb, :live_view

  alias LeniesWeb.GridRenderer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:tick")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:control")
    end

    grid = Lenies.Config.grid_size()

    socket =
      socket
      |> assign(:grid, grid)
      |> assign(:tick_count, 0)
      |> assign(:layers_visible, %{lenies: true, resource: true, carcass: true})
      |> assign(:throttle_counter, 0)
      |> assign(:history, [])
      |> assign(:species, Lenies.Species.top_n(10))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="lenies-dashboard h-screen w-screen overflow-hidden flex flex-col p-3 gap-3">
      <header class="flex items-center justify-between px-2 shrink-0">
        <h1 class="text-lg font-bold tracking-widest">⬡ LENIES · SANDBOX</h1>
        <div class="flex items-center gap-4 text-xs">
          <span class="flex items-center gap-1.5">
            <span class="pulse-dot inline-block w-2 h-2 rounded-full bg-cyan-400 shadow-[0_0_8px_#22d3ee]">
            </span>
            <span class="opacity-70">TICK</span>
            <span class="text-cyan-300 font-bold tabular-nums">{@tick_count}</span>
          </span>
          <span class="opacity-70">
            GRID <span class="text-cyan-300">{elem(@grid, 0)}×{elem(@grid, 1)}</span>
          </span>
          <span class="opacity-70">
            SPECIE <span class="text-violet-300">{length(@species)}</span>
          </span>
          <button
            id="audio-toggle"
            phx-update="ignore"
            type="button"
            title="Toggle audio feedback"
            onclick="(function(b){var m=window.LeniesAudio&&window.LeniesAudio.isMuted();if(m){window.LeniesAudio.unmute();b.textContent='♪ AUDIO';b.dataset.muted='';}else{window.LeniesAudio&&window.LeniesAudio.mute();b.textContent='∅ MUTE';b.dataset.muted='1';}})(this)"
            class="text-[10px] px-2 py-1 border border-cyan-500/40 hover:border-cyan-300 hover:text-cyan-200"
          >
            ♪ AUDIO
          </button>
        </div>
      </header>

      <div class="flex-1 flex flex-col gap-3 min-h-0">
        <div class="flex gap-3 min-h-0 shrink-0">
          <div class="panel p-3 flex flex-col gap-2 shrink-0">
            <h2 class="text-xs">▮ Mondo</h2>
            <div class="canvas-frame">
              <canvas
                id="grid-canvas"
                phx-hook="GridCanvas"
                data-grid-width={elem(@grid, 0)}
                data-grid-height={elem(@grid, 1)}
                data-show-lenies={@layers_visible.lenies}
                data-show-resource={@layers_visible.resource}
                data-show-carcass={@layers_visible.carcass}
                width="512"
                height="512"
                class="block"
              >
              </canvas>
            </div>
            <div class="flex gap-3 text-xs">
              <label class="flex items-center gap-1.5 cursor-pointer">
                <input
                  type="checkbox"
                  phx-click="toggle_layer"
                  phx-value-layer="lenies"
                  checked={@layers_visible.lenies}
                  class="accent-cyan-400"
                />
                <span>Lenies</span>
              </label>
              <label class="flex items-center gap-1.5 cursor-pointer">
                <input
                  type="checkbox"
                  phx-click="toggle_layer"
                  phx-value-layer="resource"
                  checked={@layers_visible.resource}
                  class="accent-emerald-400"
                />
                <span>Risorse</span>
              </label>
              <label class="flex items-center gap-1.5 cursor-pointer">
                <input
                  type="checkbox"
                  phx-click="toggle_layer"
                  phx-value-layer="carcass"
                  checked={@layers_visible.carcass}
                  class="accent-rose-400"
                />
                <span>Carcasse</span>
              </label>
            </div>
          </div>

          <div class="flex-1 grid grid-rows-2 gap-3 min-h-0">
            <div class="panel p-3 flex flex-col gap-2 min-h-0">
              <h2 class="text-xs">▮ Telemetria</h2>
              <div class="grid grid-cols-2 gap-2 text-[11px]">
                <div class="border border-cyan-500/30 px-2 py-1">
                  <div class="opacity-60">tick</div>
                  <div class="text-cyan-300 font-bold tabular-nums text-base">{@tick_count}</div>
                </div>
                <div class="border border-violet-500/30 px-2 py-1">
                  <div class="opacity-60">snapshot</div>
                  <div class="text-violet-300 font-bold tabular-nums text-base">
                    {length(@history)}
                  </div>
                </div>
              </div>
              <svg
                viewBox="0 0 300 100"
                preserveAspectRatio="none"
                class="w-full flex-1 min-h-[60px] bg-slate-950/60 border border-cyan-500/20"
              >
                <%= for {entry, idx} <- Enum.with_index(@history) do %>
                  <% x = idx * 3 %>
                  <% y = 100 - min(80, entry.population) %>
                  <circle cx={x} cy={y} r="2" fill="#22d3ee" opacity="0.85" />
                <% end %>
              </svg>
            </div>

            <div class="panel p-3 flex flex-col gap-2 min-h-0">
              <h2 class="text-xs">▮ Specie ({length(@species)})</h2>
              <div class="flex-1 min-h-0 overflow-auto">
                <table class="w-full text-[11px] tabular-nums">
                  <thead class="text-cyan-300/80 sticky top-0 bg-slate-950/80">
                    <tr>
                      <th class="text-left py-1">Hash</th>
                      <th class="text-right py-1">Pop</th>
                      <th class="text-right py-1">Gen</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for sp <- @species do %>
                      <tr class="hover:bg-cyan-500/10">
                        <td class="py-0.5">
                          <.link
                            navigate={~p"/species/#{sp.hash}"}
                            class="text-cyan-400 hover:text-cyan-200 hover:underline"
                          >
                            {String.slice(sp.hash, 0..7)}
                          </.link>
                        </td>
                        <td class="text-right">{sp.population}</td>
                        <td class="text-right">{Float.round(sp.avg_generation, 2)}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>

        <.live_component module={LeniesWeb.ControlsPanelComponent} id="controls" />
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_layer", %{"layer" => layer}, socket) do
    layer_atom = String.to_existing_atom(layer)
    new_visible = Map.update!(socket.assigns.layers_visible, layer_atom, &(!&1))
    {:noreply, assign(socket, :layers_visible, new_visible)}
  end

  def handle_event("cell_clicked", %{"x" => x, "y" => y}, socket)
      when is_integer(x) and is_integer(y) do
    case :ets.lookup(:cells, {x, y}) do
      [{_, %{lenie_id: id}}] when is_binary(id) ->
        {:noreply, push_navigate(socket, to: ~p"/lenie/#{id}")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:tick, n}, socket) do
    throttle = Application.get_env(:lenies, :dashboard_throttle_ticks, 5)
    new_counter = socket.assigns.throttle_counter + 1

    socket =
      socket
      |> assign(:tick_count, n)
      |> assign(:throttle_counter, new_counter)

    if rem(new_counter, throttle) == 0 do
      socket =
        socket
        |> assign(:history, Lenies.Telemetry.history(:last_n, 100))
        |> assign(:species, Lenies.Species.top_n(10))

      payload = GridRenderer.encode_payload(socket.assigns.grid)
      {:noreply, push_event(socket, "render_frame", payload)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:sterilized, _ts}, socket) do
    payload = GridRenderer.encode_payload(socket.assigns.grid)
    {:noreply, push_event(socket, "render_frame", payload)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
