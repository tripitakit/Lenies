defmodule LeniesWeb.ControlsPanelComponent do
  @moduledoc """
  Stateful LiveComponent that owns the Controls + Tuning panels.

  Isolated from the parent DashboardLive so that the world's tick-driven
  re-renders (every N ticks) do not clobber form/input DOM state held here.
  """

  use LeniesWeb, :live_component

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

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:sterilize_confirming, false)
     |> assign(:paused?, false)
     |> assign(:snapshot_status, nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="controls-root">
      <div class="panel controls-panel">
        <h2>Controllo</h2>

        <%= if @sterilize_confirming do %>
          <p>Sei sicuro? Questo distrugge tutta la sandbox.</p>
          <button phx-click="sterilize_confirm" phx-target={@myself}>Sì, sterilizza</button>
          <button phx-click="sterilize_cancel" phx-target={@myself}>No, annulla</button>
        <% else %>
          <button phx-click="sterilize_init" phx-target={@myself} class="btn-red">STERILIZE</button>
        <% end %>

        <button phx-click="toggle_pause" phx-target={@myself}>
          {if @paused?, do: "Resume", else: "Pause"}
        </button>

        <form phx-submit="spawn_seed" phx-target={@myself} class="seed-form">
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

        <form phx-submit="snapshot_action" phx-target={@myself} class="snapshot-form">
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

      <div class="panel tuning-panel">
        <h3>Tuning Live</h3>
        <%= for p <- tunable_params() do %>
          <div id={"tune-#{p.key}"} phx-update="ignore" class="tuning-row">
            <form phx-change="tune_param" phx-target={@myself}>
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
    """
  end

  @impl true
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

  def handle_event("toggle_pause", _, socket) do
    if socket.assigns.paused? do
      :ok = Lenies.World.resume()
      {:noreply, assign(socket, :paused?, false)}
    else
      :ok = Lenies.World.pause()
      {:noreply, assign(socket, :paused?, true)}
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

  defp tunable_params, do: @tunable_params

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
end
