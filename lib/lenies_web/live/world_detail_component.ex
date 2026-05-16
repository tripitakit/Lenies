defmodule LeniesWeb.WorldDetailComponent do
  @moduledoc """
  Full-screen modal overlay showing the simulation world zoomed to fill
  viewport height, with a right pane listing every active species and
  letting the user click one to highlight its cells on the canvas.

  Stateful LiveComponent (single static root: the `<aside>`). State lives
  in the parent `DashboardLive` so the component is essentially a view
  layer over `@species`, `@grid`, and `@highlight_hash`.
  """

  use LeniesWeb, :live_component

  alias Lenies.SpeciesColor

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id="world-detail"
      class="panel codeome-editor-modal world-detail-modal flex flex-col gap-3 p-4"
    >
      <header class="flex items-center gap-2">
        <h2 class="text-xs flex-1">World detail</h2>
        <button
          id="world-detail-close"
          type="button"
          phx-click="close_world_detail"
          class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
          title="Close"
        >
          ×
        </button>
      </header>

      <div class="world-detail-body grid gap-4 min-h-0 flex-1">
        <section class="world-detail-canvas-pane">
          <canvas
            id="world-detail-canvas"
            phx-hook="WorldDetailCanvas"
            phx-update="ignore"
            data-grid-width={elem(@grid, 0)}
            data-grid-height={elem(@grid, 1)}
            data-highlight-hue={highlight_hue(@highlight_hash)}
            width={elem(@grid, 0) * 2}
            height={elem(@grid, 1) * 2}
            class="world-detail-canvas"
          >
          </canvas>
        </section>

        <section class="world-detail-species-pane">
          <div class="world-detail-species-header">
            Species — <span class="text-cyan-300">{length(@species)}</span> attive
          </div>
          <ul id="world-detail-species-list" class="world-detail-species-list">
            <%= if @species == [] do %>
              <li class="world-detail-species-empty">No active species</li>
            <% end %>
            <%= for sp <- Enum.sort_by(@species, & &1.population, :desc) do %>
              <li>
                <button
                  type="button"
                  phx-click="highlight_species_in_world"
                  phx-value-hash={sp.hash}
                  class={[
                    "world-detail-species-row",
                    @highlight_hash == sp.hash && "selected"
                  ]}
                >
                  <span
                    class="world-detail-species-swatch"
                    style={"background:#{SpeciesColor.hex(sp.hash)}"}
                  >
                  </span>
                  <span class="world-detail-species-hash">{String.slice(sp.hash, 0..7)}</span>
                  <span class="world-detail-species-pop">{sp.population}</span>
                  <span class="world-detail-species-gen">{Float.round(sp.avg_generation, 2)}</span>
                </button>
              </li>
            <% end %>
          </ul>
        </section>
      </div>
    </aside>
    """
  end

  # Map an optional hash to the 0..255 highlight hue byte we ship to the
  # canvas. 0 means "no highlight" — the hook renders normally.
  defp highlight_hue(nil), do: 0
  defp highlight_hue(hash) when is_binary(hash), do: SpeciesColor.hue_byte(hash)
end
