defmodule LeniesWeb.ControlsPanelComponent do
  @moduledoc """
  Stateful LiveComponent that owns the Controls + Tuning panels.

  Isolated from the parent DashboardLive so that the world's tick-driven
  re-renders (every N ticks) do not clobber form/input DOM state held here.
  """

  use LeniesWeb, :live_component

  @tunable_params [
    %{key: :radiation_per_tick, label: "Radiation per tick", min: 0, max: 20000, step: 100},
    %{key: :eat_amount, label: "Eat amount", min: 1, max: 1000, step: 10},
    %{key: :carcass_decay, label: "Carcass decay/tick", min: 0.0, max: 0.2, step: 0.005},
    %{
      key: :lenie_metabolize_delay_ms,
      label: "Lenie metabolize delay (ms)",
      min: 0,
      max: 500,
      step: 5
    },
    %{key: :tick_interval_ms, label: "World tick interval (ms)", min: 20, max: 1000, step: 10},
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
    %{key: :attack_damage, label: "Attack damage", min: 0, max: 50, step: 1}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:sterilize_confirming, false)
     |> assign(:paused?, false)
     |> assign(:snapshot_status, nil)
     |> assign(:show_custom_manage, false)
     |> assign(:custom_seeds, custom_seeds())}
  end

  @impl true
  def update(%{refresh_custom_seeds: true} = assigns, socket) do
    {:ok,
     socket
     |> assign(Map.delete(assigns, :refresh_custom_seeds))
     |> assign(:custom_seeds, custom_seeds())}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Controls is sized to comfortably fit its three secondary buttons
          on one line (~380-420px); Tuning is capped at ~1100px so the
          sliders don't sprawl across ultrawide displays. Any leftover
          space stays on the right. --%>
    <div class="grid grid-cols-[minmax(380px,420px)_minmax(0,1100px)] gap-3 min-h-0">
      <div class="panel p-3 flex flex-col gap-3">
        <h2 class="text-xs">▮ Controls</h2>

        <div class="flex gap-2">
          <%= if @sterilize_confirming do %>
            <div
              id="sterilize-confirm"
              phx-hook="ActionFeedback"
              data-fx="danger"
              class="flex-1 flex flex-col gap-1 p-2 border border-rose-500/60 bg-rose-950/40"
            >
              <p class="text-[11px] text-rose-200">Are you sure? This destroys the sandbox.</p>
              <div class="flex gap-1">
                <button
                  phx-click="sterilize_confirm"
                  phx-target={@myself}
                  class="flex-1 text-xs px-2 py-1 border border-rose-500 bg-rose-700/40 text-rose-100 hover:bg-rose-600/60"
                >
                  Yes, sterilize
                </button>
                <button
                  phx-click="sterilize_cancel"
                  phx-target={@myself}
                  class="flex-1 text-xs px-2 py-1 border border-slate-500 bg-slate-800 hover:bg-slate-700"
                >
                  Cancel
                </button>
              </div>
            </div>
          <% else %>
            <button
              id="sterilize-btn"
              phx-hook="ActionFeedback"
              data-fx="danger"
              phx-click="sterilize_init"
              phx-target={@myself}
              class="flex-1 text-xs px-2 py-2 border border-rose-500/60 bg-rose-900/30 text-rose-200 hover:bg-rose-800/50 hover:text-rose-100 tracking-widest"
            >
              ⌷ Sterilize
            </button>
          <% end %>

          <button
            id="pause-btn"
            phx-hook="ActionFeedback"
            data-fx={if @paused?, do: "resume", else: "pause"}
            phx-click="toggle_pause"
            phx-target={@myself}
            class={[
              "flex-1 text-xs px-2 py-2 border tracking-widest",
              if(@paused?,
                do:
                  "border-emerald-500/60 bg-emerald-900/30 text-emerald-200 hover:bg-emerald-800/50",
                else: "border-cyan-500/60 bg-cyan-900/30 text-cyan-200 hover:bg-cyan-800/50"
              )
            ]}
          >
            {if @paused?, do: "▶ Resume", else: "⏸ Pause"}
          </button>
        </div>

        <div class="flex items-center gap-2 text-xs">
          <.link
            id="open-codeome-editor"
            navigate={~p"/editor/new"}
            class="px-2 py-0.5 border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40 whitespace-nowrap"
          >
            + New Seed
          </.link>

          <button
            id="world-detail-open"
            type="button"
            phx-click="open_world_detail"
            phx-target={@myself}
            class="px-2 py-0.5 border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40 whitespace-nowrap"
            title="Open the zoomed world detail view"
          >
            ⛶ World detail
          </button>

          <button
            type="button"
            phx-click="toggle_custom_manage"
            phx-target={@myself}
            class="px-2 py-0.5 border border-cyan-500/30 hover:bg-cyan-500/10 whitespace-nowrap"
          >
            Manage
          </button>
        </div>

        <form
          phx-submit="spawn_seed"
          phx-target={@myself}
          class="flex flex-col gap-1.5 border border-cyan-500/20 p-2"
        >
          <h3 class="text-[10px]">▸ Seed</h3>
          <label class="flex items-center gap-2 text-[11px]">
            <span class="opacity-70 w-12">type</span>
            <select name="seed_id" class="flex-1 text-xs">
              <%= for s <- Lenies.Seeds.all() do %>
                <option value={Atom.to_string(s.id)}>{s.name}</option>
              <% end %>
              <%= for s <- @custom_seeds do %>
                <option value={"custom:#{s.id}"}>★ {s.name}</option>
              <% end %>
            </select>
          </label>
          <label class="flex items-center gap-2 text-[11px]">
            <span class="opacity-70 w-12">count</span>
            <input
              type="number"
              name="count"
              value="1"
              min="1"
              max="50"
              class="w-16 text-xs"
            />
            <button
              id="spawn-btn"
              phx-hook="ActionFeedback"
              data-fx="success"
              type="submit"
              class="ml-auto text-xs px-3 py-1 border border-cyan-500/60 bg-cyan-900/30 text-cyan-200 hover:bg-cyan-800/50"
            >
              Spawn
            </button>
          </label>
        </form>

        <%= if @show_custom_manage do %>
          <div class="text-[10px] border border-cyan-500/20 p-2 mt-1 flex flex-col gap-1">
            <%= for s <- @custom_seeds do %>
              <div class="flex items-center gap-2">
                <span class="inline-block w-2 h-2" style={"background:#{s.color_hex}"}></span>
                <span class="flex-1 truncate">{s.name}</span>
                <button
                  type="button"
                  phx-click="delete_custom_seed"
                  phx-value-id={s.id}
                  phx-target={@myself}
                  class="px-1 hover:text-rose-300"
                  title="Delete"
                >
                  ⨯
                </button>
              </div>
            <% end %>
            <%= if @custom_seeds == [] do %>
              <div class="opacity-50">No custom seeds yet.</div>
            <% end %>
          </div>
        <% end %>

        <form
          phx-submit="snapshot_action"
          phx-target={@myself}
          class="flex flex-col gap-1.5 border border-violet-500/20 p-2"
        >
          <h3 class="text-[10px]">▸ Snapshot</h3>
          <label class="flex items-center gap-2 text-[11px]">
            <span class="opacity-70 w-12">path</span>
            <input
              type="text"
              name="path"
              value="/tmp/lenies-snapshot"
              class="flex-1 text-xs"
            />
          </label>
          <div class="flex gap-1">
            <button
              id="snapshot-save-btn"
              phx-hook="ActionFeedback"
              data-fx="success"
              type="submit"
              name="action"
              value="save"
              class="flex-1 text-xs px-2 py-1 border border-violet-500/60 bg-violet-900/30 text-violet-200 hover:bg-violet-800/50"
            >
              Save
            </button>
            <button
              id="snapshot-restore-btn"
              phx-hook="ActionFeedback"
              data-fx="info"
              type="submit"
              name="action"
              value="restore"
              class="flex-1 text-xs px-2 py-1 border border-violet-500/60 bg-violet-900/30 text-violet-200 hover:bg-violet-800/50"
            >
              Restore
            </button>
          </div>
        </form>
        <%= if @snapshot_status do %>
          <p class="text-[11px] text-violet-300 opacity-90 border-l-2 border-violet-500 pl-2">
            {@snapshot_status}
          </p>
        <% end %>
      </div>

      <div class="panel p-3 flex flex-col gap-2 min-h-0">
        <h2 class="text-xs">▮ Tuning Live</h2>
        <div class="grid grid-cols-2 gap-x-4 gap-y-2 text-[11px]">
          <%= for p <- tunable_params() do %>
            <div id={"tune-#{p.key}"} phx-update="ignore">
              <form phx-change="tune_param" phx-target={@myself} class="flex flex-col">
                <div class="flex items-center justify-between">
                  <span class="opacity-80 truncate">{p.label}</span>
                  <span
                    id={"val-#{p.key}"}
                    class="text-cyan-300 font-bold tabular-nums ml-2 shrink-0"
                  >
                    {Application.get_env(:lenies, p.key, p.min)}
                  </span>
                </div>
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

  def handle_event("spawn_seed", %{"seed_id" => "custom:" <> id, "count" => count_str}, socket) do
    case Lenies.Seeds.CustomStore.get(id) do
      %{} = seed ->
        codeome = Lenies.Codeome.from_list(seed.opcodes)
        hash = Lenies.Codeome.hash(codeome)
        Lenies.SpeciesColor.set_override(hash, seed.color_hex)

        count = String.to_integer(count_str) |> max(1) |> min(50)
        dirs = [:n, :s, :e, :w]

        for _ <- 1..count do
          Lenies.World.spawn_lenie(codeome,
            energy: seed.energy_default,
            dir: Enum.random(dirs)
          )
        end

        {:noreply, socket}

      nil ->
        {:noreply, assign(socket, :custom_seeds, custom_seeds())}
    end
  end

  def handle_event("spawn_seed", %{"seed_id" => seed_id_str, "count" => count_str}, socket) do
    seed_id = String.to_existing_atom(seed_id_str)
    count = String.to_integer(count_str) |> max(1) |> min(50)

    case Lenies.Seeds.get(seed_id) do
      %{codeome: codeome, default_options: opts} ->
        energy = Map.get(opts, :energy, 500.0)
        dirs = [:n, :s, :e, :w]

        for _ <- 1..count do
          Lenies.World.spawn_lenie(codeome, energy: energy, dir: Enum.random(dirs))
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

  def handle_event("open_world_detail", _params, socket) do
    send(self(), :open_world_detail)
    {:noreply, socket}
  end

  def handle_event("toggle_custom_manage", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_custom_manage, !socket.assigns.show_custom_manage)
     |> assign(:custom_seeds, custom_seeds())}
  end

  def handle_event("delete_custom_seed", %{"id" => id}, socket) do
    case Lenies.Seeds.CustomStore.delete(id) do
      :ok -> {:noreply, assign(socket, :custom_seeds, custom_seeds())}
      {:error, _} -> {:noreply, socket}
    end
  end

  defp custom_seeds do
    if Process.whereis(Lenies.Seeds.CustomStore) do
      Lenies.Seeds.CustomStore.all()
    else
      []
    end
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
