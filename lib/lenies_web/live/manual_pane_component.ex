defmodule LeniesWeb.ManualPaneComponent do
  @moduledoc """
  Collapsible pane that renders one Lenies Programming Manual chapter
  at a time. Owns no state — receives `chapter` (filename) and
  `collapsed?` from the parent LiveView and bubbles `select_chapter`
  and `toggle_manual` events up.
  """

  use LeniesWeb, :live_component

  alias Lenies.Manual

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:chapters, fn -> Manual.list_chapters() end)
      |> assign(:entry, Manual.get(assigns.chapter))

    ~H"""
    <aside id={@id} class={["manual-pane", @collapsed? && "manual-pane-collapsed"]}>
      <%= if @collapsed? do %>
        <button
          type="button"
          phx-click="toggle_manual"
          class="manual-ribbon"
          title="Show manual"
        >
          ▶ Manual
        </button>
      <% else %>
        <header class="manual-pane-header">
          <form phx-change="select_chapter">
            <select
              id="manual-chapter-select"
              name="chapter"
              class="manual-chapter-select"
            >
              <%= for ch <- @chapters do %>
                <option value={ch.filename} selected={ch.filename == @chapter}>
                  {ch.title}
                </option>
              <% end %>
            </select>
          </form>
          <button
            type="button"
            phx-click="toggle_manual"
            class="manual-collapse-btn"
            title="Hide manual"
          >
            ◀
          </button>
        </header>

        <div
          id={"manual-content-" <> @chapter}
          phx-hook="ManualLinkInterceptor"
          phx-update="ignore"
          class="manual-content"
        >
          <%= if @entry do %>
            {Phoenix.HTML.raw(@entry.html)}
          <% else %>
            <p class="manual-unavailable">Manual chapter unavailable.</p>
          <% end %>
        </div>
      <% end %>
    </aside>
    """
  end
end
