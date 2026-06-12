defmodule LeniesWeb.EditorComponents.DebugPanel do
  @moduledoc """
  Right-pane DEBUG tab of the codeome editor: the interpreter inspector
  (State / Slots / Stack / Call stack), the mini-world canvas with its
  seed picker, and the genome-size footer. The tab buttons live in the
  parent pane wrapper in EditorLive; this component renders the tab body.
  Events land on the parent LiveView (no phx-target).
  """
  use LeniesWeb, :html

  attr :session, :any, default: nil
  attr :grid_payload_json, :any, default: nil
  attr :current_user, :any, required: true

  def debug_panel(assigns) do
    ~H"""
    <%= if @session do %>
      <div class="editor-debug-panel">
        <section class="stepper-panel">
          <h3 class="stepper-panel-title">
            Mini-world {elem(@session.world.grid, 0)}×{elem(@session.world.grid, 1)}
            <%= if @session.place_seed_mode do %>
              <span class="stepper-place-hint">— click to place</span>
            <% end %>
          </h3>
          <form phx-change="stepper_select_seed" class="stepper-seed-picker">
            <label class="stepper-seed-label">Place:</label>
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
            </select>
          </form>
          <div
            id="stepper-canvas"
            phx-hook="StepperCanvas"
            phx-update="ignore"
            class={[
              "stepper-world-canvas",
              @session.place_seed_mode && "stepper-world-canvas-arm"
            ]}
            data-payload={@grid_payload_json}
          >
          </div>
          <div class="stepper-depth">
            Genome: {codeome_size_label(@session)} ops
            <%= if @session.halt_reason do %>
              · halt: {@session.halt_reason}
            <% end %>
          </div>
        </section>

        <section class="stepper-panel stepper-panel-state">
          <h3 class="stepper-panel-title">State</h3>
          <dl class="stepper-state-list">
            <dt>energy</dt>
            <dd>{Float.round(@session.interp.energy, 1)}</dd>
            <dt>ip</dt>
            <dd>{@session.interp.ip}/{Lenies.Codeome.size(@session.exec_codeome)}</dd>
            <dt>age</dt>
            <dd>{@session.interp.age}</dd>
            <dt>pos</dt>
            <dd>{inspect(@session.interp.pos)}</dd>
            <dt>dir</dt>
            <dd>{@session.interp.dir}</dd>
            <dt>size</dt>
            <dd>{Lenies.Codeome.size(@session.exec_codeome)}</dd>
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
          <% stack_capacity = 16
          depth = length(@session.interp.stack)
          # Pad to fixed length with nils. The CSS uses
          # flex-direction: column-reverse, so the LAST item in HTML
          # ends up visually at the top — that's where the top of the
          # stack belongs.
          padded =
            List.duplicate(nil, max(0, stack_capacity - depth)) ++
              Enum.reverse(Enum.take(@session.interp.stack, stack_capacity)) %>
          <ol class="stepper-stack stepper-stack-fixed">
            <%= for {v, idx} <- Enum.with_index(padded) do %>
              <li class={[
                "stepper-chip",
                is_nil(v) && "stepper-chip-empty",
                not is_nil(v) && idx == stack_capacity - 1 && "stepper-chip-top"
              ]}>
                {if not is_nil(v), do: v}
              </li>
            <% end %>
          </ol>
          <div class="stepper-depth">
            depth: {depth}{if depth > stack_capacity, do: " (showing top #{stack_capacity})"}
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
      </div>
    <% else %>
      <p class="codeome-snippets-empty">
        No active debug session — press ▶ in the header to start one.
      </p>
    <% end %>
    """
  end

  # "8" when plasmid-free, "8 (6 chromo + 2 plasmid)" when carrying plasmids.
  defp codeome_size_label(session) do
    exec = Lenies.Codeome.size(session.exec_codeome)
    chromo = Lenies.Codeome.size(session.codeome)

    if exec == chromo do
      Integer.to_string(exec)
    else
      "#{exec} (#{chromo} chromo + #{exec - chromo} plasmid)"
    end
  end
end
