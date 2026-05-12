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
    <div class="dashboard">
      <h1>Lenies Dashboard</h1>

      <div class="panels">
        <div class="panel world-panel">
          <h2>Mondo</h2>
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
          >
          </canvas>

          <div class="layer-controls">
            <label>
              <input
                type="checkbox"
                phx-click="toggle_layer"
                phx-value-layer="lenies"
                checked={@layers_visible.lenies}
              /> Lenies
            </label>
            <label>
              <input
                type="checkbox"
                phx-click="toggle_layer"
                phx-value-layer="resource"
                checked={@layers_visible.resource}
              /> Risorse
            </label>
            <label>
              <input
                type="checkbox"
                phx-click="toggle_layer"
                phx-value-layer="carcass"
                checked={@layers_visible.carcass}
              /> Carcasse
            </label>
          </div>
        </div>

        <div class="panel telemetry-panel">
          <h2>Telemetria</h2>
          <div class="telemetry-stats">
            <p>Tick: {@tick_count}</p>
            <p>Snapshot entries: {length(@history)}</p>
          </div>
          <svg width="300" height="100" style="background: #eee">
            <%= for {entry, idx} <- Enum.with_index(@history) do %>
              <% x = idx * 3 %>
              <% y = 100 - min(80, entry.population) %>
              <circle cx={x} cy={y} r="2" fill="blue" />
            <% end %>
          </svg>
        </div>

        <div class="panel species-panel">
          <h2>Specie ({length(@species)})</h2>
          <table class="species-table">
            <thead>
              <tr>
                <th>Hash</th>
                <th>Pop.</th>
                <th>Gen. media</th>
              </tr>
            </thead>
            <tbody>
              <%= for sp <- @species do %>
                <tr>
                  <td>
                    <.link navigate={~p"/species/#{sp.hash}"} class="species-link">
                      {String.slice(sp.hash, 0..7)}...
                    </.link>
                  </td>
                  <td>{sp.population}</td>
                  <td>{Float.round(sp.avg_generation, 2)}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
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
