defmodule LeniesWeb.DashboardLive do
  @moduledoc """
  Main dashboard for monitoring the Lenies sandbox.

  Four panels (per spec §7.1):
  1. World (canvas 512×512 with 3 toggleable layers)
  2. Telemetry (population over time)
  3. Species (placeholder — fully implemented in sub-project 6)
  4. Controls (Sterilize, Pause/Resume)
  """

  use LeniesWeb, :live_view

  alias LeniesWeb.GridRenderer

  @tunable_params [
    %{key: :radiation_per_tick, label: "Radiation per tick", min: 0, max: 1000, step: 10},
    %{
      key: :copy_substitution_rate,
      label: "Copy substitution rate",
      min: 0.0,
      max: 0.1,
      step: 0.001
    },
    %{key: :copy_insert_rate, label: "Copy insert rate", min: 0.0, max: 0.05, step: 0.0005},
    %{key: :copy_delete_rate, label: "Copy delete rate", min: 0.0, max: 0.05, step: 0.0005},
    %{
      key: :background_mutation_interval_ticks,
      label: "BG mutation interval (ticks, 0=off)",
      min: 0,
      max: 10000,
      step: 100
    },
    %{key: :attack_damage, label: "Attack damage", min: 0, max: 50, step: 1},
    %{key: :eat_amount, label: "Eat amount", min: 1, max: 1000, step: 10}
  ]

  defp tunable_params, do: @tunable_params

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
      |> assign(:sterilize_confirming, false)
      |> assign(:paused?, false)
      |> assign(:throttle_counter, 0)
      |> assign(:history, [])
      |> assign(:species, Lenies.Species.top_n(10))
      |> assign(:snapshot_status, nil)

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

        <div class="panel controls-panel">
          <h2>Controllo</h2>

          <%= if @sterilize_confirming do %>
            <p>Sei sicuro? Questo distrugge tutta la sandbox.</p>
            <button phx-click="sterilize_confirm">Sì, sterilizza</button>
            <button phx-click="sterilize_cancel">No, annulla</button>
          <% else %>
            <button phx-click="sterilize_init" class="btn-red">STERILIZE</button>
          <% end %>

          <button phx-click="toggle_pause">
            {if @paused?, do: "Resume", else: "Pause"}
          </button>

          <form phx-submit="spawn_seed" class="seed-form">
            <h3>Seed</h3>
            <label>
              Seed:
              <select name="seed_id">
                <%= for s <- Lenies.Seeds.all() do %>
                  <option value={Atom.to_string(s.id)}>{s.name}</option>
                <% end %>
              </select>
            </label>
            <label>
              Count: <input type="number" name="count" value="1" min="1" max="50" />
            </label>
            <button type="submit">Spawn</button>
          </form>

          <form phx-submit="snapshot_action" class="snapshot-form">
            <h3>Snapshot</h3>
            <label>
              Path: <input type="text" name="path" value="/tmp/lenies-snapshot" />
            </label>
            <button type="submit" name="action" value="save">Save</button>
            <button type="submit" name="action" value="restore">Restore</button>
          </form>
          <%= if @snapshot_status do %>
            <p class="snapshot-status">{@snapshot_status}</p>
          <% end %>
        </div>

        <div class="tuning-panel">
          <h3>Tuning Live</h3>
          <%= for p <- tunable_params() do %>
            <div id={"tune-#{p.key}"} phx-update="ignore" class="tuning-row">
              <form phx-change="tune_param">
                <label>
                  <span>{p.label}</span>
                  <input
                    type="range"
                    name="value"
                    min={p.min}
                    max={p.max}
                    step={p.step}
                    value={Application.get_env(:lenies, p.key, p.min)}
                    oninput={"document.getElementById('val-" <> Atom.to_string(p.key) <> "').textContent = this.value"}
                    phx-debounce="100"
                  />
                  <span id={"val-#{p.key}"} class="tuning-current">
                    {Application.get_env(:lenies, p.key, p.min)}
                  </span>
                </label>
                <input type="hidden" name="key" value={Atom.to_string(p.key)} />
              </form>
            </div>
          <% end %>
        </div>
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

  def handle_event("sterilize_init", _, socket) do
    {:noreply, assign(socket, :sterilize_confirming, true)}
  end

  def handle_event("sterilize_confirm", _, socket) do
    :ok = Lenies.World.sterilize()
    {:noreply, assign(socket, :sterilize_confirming, false)}
  end

  def handle_event("sterilize_cancel", _, socket) do
    {:noreply, assign(socket, :sterilize_confirming, false)}
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

  def handle_event("spawn_seed", %{"seed_id" => seed_id_str, "count" => count_str}, socket) do
    seed_id = String.to_existing_atom(seed_id_str)
    count = String.to_integer(count_str) |> max(1) |> min(50)

    case Lenies.Seeds.get(seed_id) do
      %{codeome: codeome, default_options: opts} ->
        energy = Map.get(opts, :energy, 500.0)

        for _ <- 1..count do
          Lenies.World.spawn_lenie(codeome, energy: energy)
        end

      nil ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_event("tune_param", %{"key" => key_str, "value" => value_str}, socket) do
    key = String.to_existing_atom(key_str)
    value = parse_tune_value(value_str)
    Application.put_env(:lenies, key, value)
    {:noreply, socket}
  end

  def handle_event("toggle_pause", _, socket) do
    if socket.assigns.paused? do
      :ok = Lenies.World.resume()
      {:noreply, assign(socket, :paused?, false)}
    else
      :ok = Lenies.World.pause()
      {:noreply, assign(socket, :paused?, true)}
    end
  end

  def handle_event("snapshot_action", %{"action" => "save", "path" => path}, socket) do
    status =
      case Lenies.Snapshot.save_to_disk(path) do
        :ok -> "Saved to #{path}"
        {:error, reason} -> "Save failed: #{inspect(reason)}"
      end

    {:noreply, assign(socket, :snapshot_status, status)}
  end

  def handle_event("snapshot_action", %{"action" => "restore", "path" => path}, socket) do
    status =
      case Lenies.Snapshot.restore_from_disk(path) do
        :ok -> "Restored from #{path}"
        {:error, :missing_file} -> "Missing snapshot files at #{path}"
        {:error, reason} -> "Restore failed: #{inspect(reason)}"
      end

    {:noreply, assign(socket, :snapshot_status, status)}
  end

  defp parse_tune_value(s) do
    case Float.parse(s) do
      {f, ""} ->
        if f == trunc(f), do: trunc(f), else: f

      _ ->
        case Integer.parse(s) do
          {i, ""} -> i
          _ -> s
        end
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
