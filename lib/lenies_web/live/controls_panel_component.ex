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
    %{key: :carcass_decay, label: "Detritus decay/tick", min: 0.0, max: 0.05, step: 0.0005},
    %{
      key: :lenie_metabolize_delay_ms,
      label: "Lenie metabolize delay (ms)",
      min: 100,
      max: 500,
      step: 5
    },
    %{key: :tick_interval_ms, label: "World tick interval (ms)", min: 200, max: 1000, step: 10},
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
      key: :background_mutation_rate_per_1000_ticks,
      label: "BG mutations / 1000 ticks (0=off)",
      min: 0,
      max: 100,
      step: 1
    },
    %{key: :attack_damage, label: "Attack damage", min: 0, max: 50, step: 1}
  ]

  @impl true
  def mount(socket) do
    # The parent LiveView (Dashboard) passes :world_id and :world_handle
    # via update/2. Until the first update/2 we can't query the World,
    # so default :paused? to false; it gets refreshed at update/2 time.
    {:ok,
     socket
     |> assign(:sterilize_confirming, false)
     |> assign(:paused?, false)
     |> assign(:snapshot_status, nil)
     |> assign(:show_custom_manage, false)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.delete(assigns, :refresh_custom_seeds))
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    socket =
      if Map.get(assigns, :refresh_custom_seeds, false) or
           not Map.has_key?(socket.assigns, :custom_seeds) do
        assign(socket, :custom_seeds, custom_seeds(user))
      else
        socket
      end

    # Refresh the live :paused? mirror from the world we're now scoped to.
    # Defensive: if the world isn't running (some tests), keep the previous
    # value rather than crashing the LiveView mount.
    socket =
      case socket.assigns[:world_id] do
        nil ->
          socket

        world_id ->
          paused? =
            try do
              Lenies.Worlds.paused?(world_id)
            catch
              :exit, _ -> socket.assigns.paused?
            end

          assign(socket, :paused?, paused?)
      end

    # Default the selected seed to the first builtin seed on first render;
    # preserve the existing selection on subsequent re-renders.
    socket =
      assign_new(socket, :selected_seed_id, fn ->
        Lenies.Seeds.all() |> hd() |> Map.fetch!(:id) |> Atom.to_string()
      end)

    # Spawn cap status — read the world's current population vs configured
    # cap. Used by the template to disable the Spawn button when at cap.
    # :sys.get_state is acceptable here because update/2 runs only on
    # parent re-renders (not per simulation tick).
    at_spawn_cap = compute_at_spawn_cap(socket.assigns[:world_id])

    {:ok, assign(socket, :at_spawn_cap, at_spawn_cap)}
  end

  defp compute_at_spawn_cap(nil), do: false

  defp compute_at_spawn_cap(world_id) do
    case Lenies.Worlds.handle(world_id) do
      {:ok, h} ->
        cap =
          try do
            case :sys.get_state(h.pid) do
              %{config: %{spawn_cap: c}} -> c
              _ -> 10
            end
          catch
            :exit, _ -> 10
          end

        cap != :infinity and (:ets.info(h.tables.lenies, :size) || 0) >= cap

      _ ->
        false
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Dashboard's right-bottom row is narrower than the panel used to
          sit in, so Controls and Tuning stack vertically here. Each is
          full width of the right column; Tuning's internal slider grid
          remains 2-col. --%>
    <div class="grid grid-rows-[auto_minmax(0,1fr)] gap-2 min-h-0">
      <div class="panel p-2 flex flex-col gap-2">
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
            navigate={~p"/sandbox/editor/new"}
            class="px-2 py-0.5 border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40 whitespace-nowrap"
          >
            + New
          </.link>

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
          phx-change="select_seed"
          phx-target={@myself}
          class="flex items-center gap-2 text-[11px]"
        >
          <span class="text-[9px] tracking-widest opacity-50 w-9">SEED</span>
          <select name="seed_id" class="flex-1 text-xs">
            <%= for s <- Lenies.Seeds.all() do %>
              <option
                value={Atom.to_string(s.id)}
                selected={Atom.to_string(s.id) == @selected_seed_id}
              >
                {s.name}
              </option>
            <% end %>
            <%= for s <- @custom_seeds do %>
              <option
                value={"custom:" <> to_string(s.id)}
                selected={"custom:" <> to_string(s.id) == @selected_seed_id}
              >
                ★ {s.name}
              </option>
            <% end %>
          </select>
          <button
            id="spawn-btn"
            phx-hook="ActionFeedback"
            data-fx="success"
            type="submit"
            disabled={@at_spawn_cap}
            class={[
              "text-xs px-3 py-1 border border-cyan-500/60 bg-cyan-900/30 text-cyan-200 hover:bg-cyan-800/50",
              @at_spawn_cap && "opacity-50 cursor-not-allowed"
            ]}
          >
            Spawn
          </button>
          <.link
            id="seed-edit-btn"
            navigate={~p"/sandbox/editor/seed/#{@selected_seed_id}"}
            class="text-xs px-3 py-1 border border-cyan-500/60 bg-cyan-900/30 text-cyan-200 hover:bg-cyan-800/50"
          >
            Edit
          </.link>
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
          class="flex items-center gap-2 text-[11px]"
        >
          <span class="text-[9px] tracking-widest opacity-50 w-9">SNAP</span>
          <input type="text" name="snapshot_name" value="default" class="flex-1 text-xs" />
          <button
            id="snapshot-save-btn"
            phx-hook="ActionFeedback"
            data-fx="success"
            type="submit"
            name="action"
            value="save"
            class="text-xs px-2 py-1 border border-violet-500/60 bg-violet-900/30 text-violet-200 hover:bg-violet-800/50"
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
            class="text-xs px-2 py-1 border border-violet-500/60 bg-violet-900/30 text-violet-200 hover:bg-violet-800/50"
          >
            Restore
          </button>
        </form>
        <%= if @snapshot_status do %>
          <p class="text-[11px] text-violet-300 opacity-90 border-l-2 border-violet-500 pl-2">
            {@snapshot_status}
          </p>
        <% end %>
      </div>

      <div class="panel p-2 flex flex-col gap-2 min-h-0">
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
                  id={"slider-#{p.key}"}
                  type="range"
                  name="value"
                  min={p.min}
                  max={p.max}
                  step={p.step}
                  value={Application.get_env(:lenies, p.key, p.min)}
                  phx-hook="SliderValue"
                  data-value-target={"val-#{Atom.to_string(p.key)}"}
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
    :ok = Lenies.Worlds.sterilize(socket.assigns.world_id)
    {:noreply, assign(socket, :sterilize_confirming, false)}
  end

  def handle_event("sterilize_cancel", _, socket) do
    {:noreply, assign(socket, :sterilize_confirming, false)}
  end

  def handle_event("toggle_pause", _, socket) do
    if socket.assigns.paused? do
      :ok = Lenies.Worlds.resume(socket.assigns.world_id)
      {:noreply, assign(socket, :paused?, false)}
    else
      :ok = Lenies.Worlds.pause(socket.assigns.world_id)
      {:noreply, assign(socket, :paused?, true)}
    end
  end

  def handle_event("spawn_seed", %{"seed_id" => "custom:" <> id}, socket) do
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    case user && Lenies.Collection.get_codeome(user, id) do
      %Lenies.Collection.Codeome{} = seed ->
        codeome = Lenies.Codeome.from_list(Lenies.Collection.to_opcode_atoms(seed))
        hash = Lenies.Codeome.hash(codeome)
        # Color overrides are per-world; the parent dashboard passes the
        # world handle in @world_handle.
        Lenies.SpeciesColor.set_override(socket.assigns.world_handle, hash, seed.color_hex)

        plasmids = Lenies.Collection.to_plasmid_structs(seed)

        spawn_opts =
          [
            energy: seed.energy_default,
            dir: Enum.random([:n, :s, :e, :w]),
            seed_origin: "★ " <> seed.name
          ] ++ if(plasmids == [], do: [], else: [plasmids: plasmids])

        result = Lenies.Worlds.spawn_lenie(socket.assigns.world_id, codeome, spawn_opts)

        {:noreply, maybe_flash_cap_exceeded(socket, result)}

      _ ->
        {:noreply, assign(socket, :custom_seeds, custom_seeds(user))}
    end
  end

  def handle_event("spawn_seed", %{"seed_id" => seed_id_str}, socket) do
    seed_id = String.to_existing_atom(seed_id_str)

    case Lenies.Seeds.get(seed_id) do
      %{codeome: codeome, default_options: opts, name: seed_name} = seed ->
        energy = Map.get(opts, :energy, 500.0)
        plasmid_opcodes = Map.get(seed, :plasmid)

        plasmid_opt =
          if is_list(plasmid_opcodes) and plasmid_opcodes != [] do
            [plasmids: [Lenies.Plasmid.new(plasmid_opcodes)]]
          else
            []
          end

        spawn_opts =
          [
            energy: energy,
            dir: Enum.random([:n, :s, :e, :w]),
            seed_origin: seed_name
          ] ++ plasmid_opt

        result = Lenies.Worlds.spawn_lenie(socket.assigns.world_id, codeome, spawn_opts)
        {:noreply, maybe_flash_cap_exceeded(socket, result)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("select_seed", %{"seed_id" => seed_id}, socket) do
    {:noreply, assign(socket, :selected_seed_id, seed_id)}
  end

  def handle_event("tune_param", %{"key" => key_str, "value" => value_str}, socket) do
    key = String.to_existing_atom(key_str)
    value = parse_tune_value(value_str)
    # Lenies.Worlds.tune/3 is the single source of truth for live tuning: it
    # mutates state.config in the target world's GenServer and broadcasts a
    # :config_changed event on the world's control topic. The engine
    # (Lenies.World.cfg/2) reads directly from state.config, so no
    # Application.put_env shim is needed.
    _ = Lenies.Worlds.tune(socket.assigns.world_id, key, value)
    {:noreply, socket}
  end

  def handle_event("snapshot_action", %{"action" => "save", "snapshot_name" => name}, socket) do
    status =
      case Lenies.Worlds.save_snapshot(socket.assigns.world_id, name) do
        :ok -> "Saved as “#{name}”"
        {:error, :invalid_name} -> "Invalid name — use letters, digits, - and _ only"
        {:error, reason} -> "Save failed: #{inspect(reason)}"
      end

    {:noreply, assign(socket, :snapshot_status, status)}
  end

  def handle_event("snapshot_action", %{"action" => "restore", "snapshot_name" => name}, socket) do
    status =
      case Lenies.Worlds.restore_snapshot(socket.assigns.world_id, name) do
        :ok -> "Restored from “#{name}”"
        {:error, :invalid_name} -> "Invalid name — use letters, digits, - and _ only"
        {:error, :missing_file} -> "No snapshot named “#{name}”"
        {:error, {:corrupt, table}} -> "Snapshot “#{name}” is corrupt (#{table}); world unchanged"
        {:error, reason} -> "Restore failed: #{inspect(reason)}"
      end

    {:noreply, assign(socket, :snapshot_status, status)}
  end

  def handle_event("toggle_custom_manage", _params, socket) do
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    {:noreply,
     socket
     |> assign(:show_custom_manage, !socket.assigns.show_custom_manage)
     |> assign(:custom_seeds, custom_seeds(user))}
  end

  def handle_event("delete_custom_seed", %{"id" => id}, socket) do
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    case user && Lenies.Collection.delete_codeome(user, id) do
      {:ok, _} -> {:noreply, assign(socket, :custom_seeds, custom_seeds(user))}
      _ -> {:noreply, socket}
    end
  end

  defp custom_seeds(nil), do: []
  defp custom_seeds(%{id: _} = user), do: Lenies.Collection.list_codeomes(user)

  # When World rejects a spawn for hitting the cap, relay a flash to the
  # parent LiveView (LiveComponents can't put_flash directly).
  defp maybe_flash_cap_exceeded(socket, {:error, :spawn_cap_exceeded}) do
    send(self(), {:flash, :info, "Sandbox full: max 10 alive Lenies"})
    socket
  end

  defp maybe_flash_cap_exceeded(socket, _other), do: socket

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
