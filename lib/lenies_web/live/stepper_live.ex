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
  def update(%{codeome: codeome} = assigns, socket) do
    session = Map.get(socket.assigns, :session) || Stepper.start_session(codeome, [])

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:session, session)}
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
            <button phx-click="run" phx-target={@myself} class="stepper-btn" title="Run (F5)">
              ▶▶ Run
            </button>
          </div>
          <button
            phx-click="close"
            phx-target={@myself}
            class="stepper-close"
            aria-label="Close (Esc)"
          >
            ✕
          </button>
        </header>

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
              <h3 class="stepper-panel-title">Stack (top↑)</h3>
              <ol class="stepper-stack">
                <%= for {v, idx} <- Enum.with_index(Enum.reverse(@session.interp.stack)) do %>
                  <li class={[
                    "stepper-chip",
                    idx == length(@session.interp.stack) - 1 && "stepper-chip-top"
                  ]}>
                    {v}
                  </li>
                <% end %>
                <%= if @session.interp.stack == [] do %>
                  <li class="stepper-empty">empty</li>
                <% end %>
              </ol>
              <div class="stepper-depth">depth: {length(@session.interp.stack)}</div>
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
            <h3 class="stepper-panel-title">Mini-world 64×64</h3>
            <div
              id="stepper-canvas"
              phx-hook="StepperCanvas"
              phx-update="ignore"
              class="stepper-world-canvas"
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
    {:ok, new_session} = Stepper.run(socket.assigns.session, max_steps: 1_000)
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

  def handle_event("canvas_click", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("key", %{"key" => key}, socket) do
    case key do
      "F10" -> handle_event("step", %{}, socket)
      "F11" -> handle_event("step_back", %{}, socket)
      "F5" -> handle_event("run", %{}, socket)
      "r" -> handle_event("reset", %{}, socket)
      "R" -> handle_event("reset", %{}, socket)
      "Escape" -> handle_event("close", %{}, socket)
      _ -> {:noreply, socket}
    end
  end

  defp status_label(:ready), do: "ready"
  defp status_label(:running), do: "running"
  defp status_label(:paused), do: "paused"
  defp status_label(:halted), do: "halted"
  defp status_label(:breakpoint_hit), do: "breakpoint"
  defp status_label(:safety_cap_reached), do: "safety cap"
end
