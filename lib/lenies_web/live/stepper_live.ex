defmodule LeniesWeb.StepperLive do
  @moduledoc """
  Full-screen modal codeome stepper. See spec
  `docs/superpowers/specs/2026-06-01-codeome-stepper-design.md`.

  LiveComponent (not a separate LiveView) so the parent editor state
  (buffer, caret, selection) is preserved while the modal is open.
  """
  use LeniesWeb, :live_component

  alias Lenies.Stepper

  @impl true
  def update(%{tick: true}, socket) do
    session = socket.assigns.session

    if session.status == :running do
      {:ok, new_session} = Lenies.Stepper.step(session)

      cond do
        new_session.status == :halted ->
          {:ok, assign(socket, :session, new_session)}

        MapSet.member?(new_session.breakpoints, new_session.interp.ip) ->
          {:ok, assign(socket, :session, %{new_session | status: :breakpoint_hit})}

        true ->
          # `Stepper.step/1` resets status to :ready after every step. Restore
          # :running so subsequent ticks keep firing (and the Pause button
          # stays visible). Without this, Run advances exactly one opcode and
          # the button flickers Pause → Run on the next render.
          running_session = %{new_session | status: :running}
          # Delay the next tick so the animation is visible to the user.
          # 100ms ≈ 10 ops/sec, slow enough to follow state changes by eye.
          Process.send_after(self(), {:stepper_tick, socket.assigns.id}, 100)
          {:ok, assign(socket, :session, running_session)}
      end
    else
      {:ok, socket}
    end
  end

  # Canvas-click forwarded from the parent LiveView. See the matching
  # `handle_event("stepper:canvas_click", ...)` in EditorLive — the hook
  # is inside a `phx-update="ignore"` subtree so `pushEvent` (parent) +
  # send_update is the reliable path.
  def update(%{canvas_click: %{x: x, y: y}}, socket) do
    session = socket.assigns.session

    case session.place_seed_mode do
      nil ->
        {:ok, socket}

      %{seed_id: seed_ref} ->
        case resolve_seed(seed_ref, socket.assigns.current_user) do
          nil ->
            {:ok, socket}

          seed_map ->
            case Stepper.place_seed(session, seed_map, {x, y}) do
              {:ok, new_session} ->
                final = Stepper.set_place_seed_mode(new_session, nil)
                {:ok, assign(socket, :session, final)}

              {:error, _reason} ->
                {:ok, socket}
            end
        end
    end
  end

  def update(%{codeome: codeome} = assigns, socket) do
    session = Map.get(socket.assigns, :session) || Stepper.start_session(codeome, [])

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:session, session)
     |> assign_new(:current_user, fn -> nil end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-window-keydown="key"
      phx-target={@myself}
      class="stepper-modal-backdrop"
      data-stepper-modal="true"
    >
      <div class="stepper-modal" role="dialog" aria-labelledby="stepper-title">
        <header class="stepper-header">
          <div class="stepper-header-title">
            <span id="stepper-title">🐞 Codeome Stepper</span>
            <span class="stepper-step-counter">
              Step #{@session.step_count} · {status_label(@session.status)}
            </span>
          </div>
          <div class="stepper-controls">
            <button phx-click="reset" phx-target={@myself} class="stepper-btn" title="Reset (R)">
              ⏮
            </button>
            <button
              phx-click="step_back"
              phx-target={@myself}
              class="stepper-btn"
              title="Step back (F11)"
            >
              ⬅
            </button>
            <button
              phx-click="step"
              phx-target={@myself}
              class="stepper-btn stepper-btn-primary"
              title="Step (F10)"
            >
              ▶ Step
            </button>
            <%= if @session.status == :running do %>
              <button phx-click="pause" phx-target={@myself} class="stepper-btn" title="Pause (F5)">
                ⏸ Pause
              </button>
            <% else %>
              <button phx-click="run" phx-target={@myself} class="stepper-btn" title="Run (F5)">
                ▶▶ Run
              </button>
            <% end %>
          </div>
          <form phx-change="select_seed" phx-target={@myself} class="stepper-seed-picker">
            <label class="stepper-seed-label">🎯 Place:</label>
            <select name="value" class="stepper-seed-select">
              <option value="">(none)</option>
              <optgroup label="Built-in">
                <%= for seed <- Lenies.Seeds.all() do %>
                  <option
                    value={"builtin:" <> Atom.to_string(seed.id)}
                    selected={
                      @session.place_seed_mode &&
                        @session.place_seed_mode.seed_id == {:builtin, seed.id}
                    }
                  >
                    {seed.name}
                  </option>
                <% end %>
              </optgroup>
              <%= if @current_user do %>
                <optgroup label="My collection">
                  <%= for c <- Lenies.Collection.list_codeomes(@current_user) do %>
                    <option
                      value={"collection:" <> Integer.to_string(c.id)}
                      selected={
                        @session.place_seed_mode &&
                          @session.place_seed_mode.seed_id == {:collection, c.id}
                      }
                    >
                      {c.name}
                    </option>
                  <% end %>
                </optgroup>
              <% end %>
            </select>
            <%= if @session.place_seed_mode do %>
              <span class="stepper-seed-active">click on the canvas</span>
            <% end %>
          </form>
          <button
            phx-click="close"
            phx-target={@myself}
            class="stepper-close"
            aria-label="Close (Esc)"
          >
            ✕
          </button>
        </header>

        <%= cond do %>
          <% @session.status == :halted -> %>
            <div class="stepper-status-banner stepper-status-banner-halted">
              Halted: {@session.halt_reason}
            </div>
          <% @session.status == :breakpoint_hit -> %>
            <div class="stepper-status-banner stepper-status-banner-breakpoint">
              Stopped at breakpoint @ ip {@session.interp.ip}
            </div>
          <% @session.status == :safety_cap_reached -> %>
            <div class="stepper-status-banner stepper-status-banner-safety">
              Safety cap (10k steps) — paused
            </div>
          <% true -> %>
        <% end %>

        <div class="stepper-body">
          <aside class="stepper-inspector">
            <section class="stepper-panel">
              <h3 class="stepper-panel-title">State</h3>
              <dl class="stepper-state-list">
                <dt>energy</dt>
                <dd>{Float.round(@session.interp.energy, 1)}</dd>
                <dt>ip</dt>
                <dd>{@session.interp.ip}/{Lenies.Codeome.size(@session.codeome)}</dd>
                <dt>age</dt>
                <dd>{@session.interp.age}</dd>
                <dt>pos</dt>
                <dd>{inspect(@session.interp.pos)}</dd>
                <dt>dir</dt>
                <dd>{@session.interp.dir}</dd>
                <dt>size</dt>
                <dd>{Lenies.Codeome.size(@session.codeome)}</dd>
              </dl>
            </section>

            <section class="stepper-panel">
              <h3 class="stepper-panel-title">Slots</h3>
              <div class="stepper-slots">
                <%= for i <- 0..3 do %>
                  <div class="stepper-slot">
                    <div class="stepper-slot-value">{@session.interp.slots[i]}</div>
                    <div class="stepper-slot-label">s{i}</div>
                  </div>
                <% end %>
              </div>
            </section>

            <section class="stepper-panel">
              <h3 class="stepper-panel-title">Stack (top↑)</h3>
              <%
                stack_capacity = 16
                depth = length(@session.interp.stack)
                # Pad to fixed length with nils. The CSS uses
                # flex-direction: column-reverse, so the LAST item in HTML
                # ends up visually at the top — that's where the top of the
                # stack belongs.
                padded =
                  List.duplicate(nil, max(0, stack_capacity - depth)) ++
                    Enum.reverse(Enum.take(@session.interp.stack, stack_capacity))
              %>
              <ol class="stepper-stack stepper-stack-fixed">
                <%= for {v, idx} <- Enum.with_index(padded) do %>
                  <li class={[
                    "stepper-chip",
                    is_nil(v) && "stepper-chip-empty",
                    not is_nil(v) && idx == stack_capacity - 1 && "stepper-chip-top"
                  ]}>
                    <%= if not is_nil(v), do: v %>
                  </li>
                <% end %>
              </ol>
              <div class="stepper-depth">
                depth: {depth}<%= if depth > stack_capacity, do: " (showing top #{stack_capacity})" %>
              </div>
            </section>

            <section class="stepper-panel">
              <h3 class="stepper-panel-title">Call stack</h3>
              <ol class="stepper-callstack">
                <%= for ret_ip <- @session.interp.call_stack do %>
                  <li>→ ret to ip {ret_ip}</li>
                <% end %>
                <%= if @session.interp.call_stack == [] do %>
                  <li class="stepper-empty">empty</li>
                <% end %>
              </ol>
            </section>
          </aside>

          <section class="stepper-codeome">
            <h3 class="stepper-panel-title">Codeome ({Lenies.Codeome.size(@session.codeome)} ops)</h3>
            <ol class="stepper-codeome-list">
              <%= for {op, idx} <- Enum.with_index(Lenies.Codeome.to_list(@session.codeome)) do %>
                <li
                  class={[
                    "stepper-codeome-row",
                    idx == @session.interp.ip && "stepper-codeome-ip",
                    MapSet.member?(@session.breakpoints, idx) && "stepper-codeome-bp"
                  ]}
                  phx-click="toggle_bp"
                  phx-value-ip={idx}
                  phx-target={@myself}
                >
                  <span class="stepper-codeome-pos">
                    {String.pad_leading(Integer.to_string(idx), 3, "0")}
                  </span>
                  <span class="stepper-codeome-op">{op}</span>
                  <%= if idx == @session.interp.ip do %>
                    <span class="stepper-codeome-arrow">▸</span>
                  <% end %>
                </li>
              <% end %>
            </ol>
          </section>

          <aside class="stepper-world">
            <h3 class="stepper-panel-title">
              Mini-world 64×64
              <%= if @session.place_seed_mode do %>
                <span class="stepper-place-hint">— click to place</span>
              <% end %>
            </h3>
            <div
              id="stepper-canvas"
              phx-hook="StepperCanvas"
              phx-update="ignore"
              class={["stepper-world-canvas", @session.place_seed_mode && "stepper-world-canvas-arm"]}
              data-payload={Jason.encode!(Lenies.Stepper.World.encode_grid_payload(@session.world))}
            ></div>
          </aside>
        </div>

        <footer class="stepper-footer">
          <%= if @session.halt_reason do %>
            halt reason: {@session.halt_reason}
          <% else %>
            halt reason: —
          <% end %>
          ·  ⌨ F10 step  F11 back  F5 run  R reset  Esc close
        </footer>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("step", _params, socket) do
    {:ok, new_session} = Stepper.step(socket.assigns.session)
    {:noreply, assign(socket, :session, new_session)}
  end

  def handle_event("step_back", _params, socket) do
    {:ok, new_session} = Stepper.step_back(socket.assigns.session)
    {:noreply, assign(socket, :session, new_session)}
  end

  def handle_event("run", _params, socket) do
    new_session = %{socket.assigns.session | status: :running}
    send(self(), {:stepper_tick, socket.assigns.id})
    {:noreply, assign(socket, :session, new_session)}
  end

  def handle_event("pause", _params, socket) do
    new_session = %{socket.assigns.session | status: :paused}
    {:noreply, assign(socket, :session, new_session)}
  end

  def handle_event("reset", _params, socket) do
    new_session = Stepper.reset(socket.assigns.session)
    {:noreply, assign(socket, :session, new_session)}
  end

  def handle_event("toggle_bp", %{"ip" => ip_str}, socket) do
    ip = String.to_integer(ip_str)
    new_session = Stepper.toggle_breakpoint(socket.assigns.session, ip)
    {:noreply, assign(socket, :session, new_session)}
  end

  def handle_event("close", _params, socket) do
    send(self(), :close_stepper)
    {:noreply, socket}
  end

  def handle_event("select_seed", %{"value" => ""}, socket) do
    {:noreply, assign(socket, :session, Stepper.set_place_seed_mode(socket.assigns.session, nil))}
  end

  def handle_event("select_seed", %{"value" => "builtin:" <> id_str}, socket) do
    seed_id = {:builtin, String.to_atom(id_str)}

    {:noreply,
     assign(socket, :session, Stepper.set_place_seed_mode(socket.assigns.session, seed_id))}
  end

  def handle_event("select_seed", %{"value" => "collection:" <> id}, socket) do
    seed_id = {:collection, parse_int(id)}

    {:noreply,
     assign(socket, :session, Stepper.set_place_seed_mode(socket.assigns.session, seed_id))}
  end

  def handle_event("canvas_click", %{"x" => x, "y" => y}, socket) do
    case socket.assigns.session.place_seed_mode do
      nil ->
        {:noreply, socket}

      %{seed_id: seed_ref} ->
        case resolve_seed(seed_ref, socket.assigns.current_user) do
          nil ->
            {:noreply, socket}

          seed_map ->
            case Stepper.place_seed(socket.assigns.session, seed_map, {x, y}) do
              {:ok, new_session} ->
                # Auto-exit place-seed mode after a successful drop.
                final_session = Stepper.set_place_seed_mode(new_session, nil)
                {:noreply, assign(socket, :session, final_session)}

              {:error, _reason} ->
                {:noreply, socket}
            end
        end
    end
  end

  def handle_event("key", %{"key" => key}, socket) do
    case key do
      "F10" ->
        handle_event("step", %{}, socket)

      "F11" ->
        handle_event("step_back", %{}, socket)

      "F5" ->
        if socket.assigns.session.status == :running do
          handle_event("pause", %{}, socket)
        else
          handle_event("run", %{}, socket)
        end

      "r" ->
        handle_event("reset", %{}, socket)

      "R" ->
        handle_event("reset", %{}, socket)

      "Escape" ->
        handle_event("close", %{}, socket)

      " " ->
        if socket.assigns.session.status == :running do
          handle_event("pause", %{}, socket)
        else
          handle_event("run", %{}, socket)
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp resolve_seed({:builtin, id}, _user) do
    case Enum.find(Lenies.Seeds.all(), &(&1.id == id)) do
      nil ->
        nil

      seed ->
        plasmids =
          case Map.get(seed, :plasmid) do
            nil -> []
            [] -> []
            ops when is_list(ops) -> [ops]
          end

        %{codeome: seed.codeome, plasmids: plasmids}
    end
  end

  defp resolve_seed({:collection, _id}, nil), do: nil

  defp resolve_seed({:collection, id}, user) do
    case Lenies.Collection.get_codeome(user, id) do
      nil ->
        nil

      %Lenies.Collection.Codeome{} = c ->
        opcodes = Lenies.Collection.to_opcode_atoms(c)
        %{codeome: Lenies.Codeome.from_list(opcodes), plasmids: []}
    end
  end

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(_), do: nil

  defp status_label(:ready), do: "ready"
  defp status_label(:running), do: "running"
  defp status_label(:paused), do: "paused"
  defp status_label(:halted), do: "halted"
  defp status_label(:breakpoint_hit), do: "breakpoint"
  defp status_label(:safety_cap_reached), do: "safety cap"
end
