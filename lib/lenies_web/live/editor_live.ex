defmodule LeniesWeb.EditorLive do
  @moduledoc """
  Full-page codeome editor. Owns drag-drop palette + listing, plus a
  collapsible left pane that renders the Lenies Programming Manual for
  in-editor study and reference.

  Routes:
    /editor/new          — empty buffer (new seed)
    /editor/edit/:hash   — buffer pre-loaded from a representative
                           Lenie of the given species hash
  """

  use LeniesWeb, :live_view

  @default_chapter "02-opcode-reference.md"

  @impl true
  def mount(params, _session, socket) do
    {mode, selected_hash, buffer} = init_for_route(socket.assigns.live_action, params)

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:selected_hash, selected_hash)
      |> assign(:buffer, buffer)
      |> assign(:current_chapter, @default_chapter)
      |> assign(:manual_collapsed?, false)

    {:ok, socket}
  end

  defp init_for_route(:new, _params) do
    {:new_seed, nil, []}
  end

  defp init_for_route(:edit, %{"hash" => hash}) do
    buffer =
      case Lenies.Species.for_hash(hash) do
        [{sample_id, _} | _] ->
          case safe_get_codeome(sample_id) do
            {:ok, codeome} -> Lenies.Codeome.to_list(codeome)
            _ -> []
          end

        [] ->
          []
      end

    {:edit, hash, buffer}
  end

  defp safe_get_codeome(id) do
    case Lenies.Registry.whereis(id) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :get_codeome, 1_000)
        catch
          :exit, _ -> {:error, :dead}
        end

      _ ->
        {:error, :not_alive}
    end
  end

  @impl true
  def handle_event("select_chapter", %{"chapter" => filename}, socket) do
    {:noreply,
     socket
     |> assign(:current_chapter, filename)
     |> push_event("persist_manual_state", %{chapter: filename})}
  end

  def handle_event("toggle_manual", _params, socket) do
    new_collapsed = !socket.assigns.manual_collapsed?

    {:noreply,
     socket
     |> assign(:manual_collapsed?, new_collapsed)
     |> push_event("persist_manual_state", %{collapsed: new_collapsed})}
  end

  def handle_event("restore_manual_state", payload, socket) do
    socket =
      socket
      |> maybe_assign(:current_chapter, payload["chapter"])
      |> maybe_assign(:manual_collapsed?, payload["collapsed"])

    {:noreply, socket}
  end

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="editor-root" phx-hook="RememberManualState" class="lenies-dashboard codeome-editor-page">
      <header class="codeome-editor-page-header">
        <.link navigate={back_to(@mode, @selected_hash)} class="text-xs px-2 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10">
          ← Back
        </.link>
        <h1 class="text-sm flex-1">
          <%= if @mode == :new_seed do %>
            New Seed
          <% else %>
            Edit: {String.slice(@selected_hash || "", 0..15)}…
          <% end %>
        </h1>
        <span class="text-[10px] opacity-60">{length(@buffer)} ops</span>
      </header>

      <div class={["editor-grid", @manual_collapsed? && "manual-collapsed"]}>
        <.live_component
          module={LeniesWeb.ManualPaneComponent}
          id="manual-pane"
          chapter={@current_chapter}
          collapsed?={@manual_collapsed?}
        />

        <section class="palette-pane-placeholder">
          <div class="text-xs opacity-60 p-2">Palette pane (Task 4)</div>
        </section>

        <section class="listing-pane-placeholder">
          <div class="text-xs opacity-60 p-2">Listing pane (Task 4)</div>
        </section>
      </div>
    </div>
    """
  end

  defp back_to(:new_seed, _hash), do: ~p"/"
  defp back_to(:edit, nil), do: ~p"/"
  defp back_to(:edit, hash), do: ~p"/species/#{hash}"
end
