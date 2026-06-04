defmodule LeniesWeb.ArenaControlsComponent do
  @moduledoc """
  Read-mostly controls for the Arena. Four states:

  - Anonymous: "Log in to seed" prompt + link.
  - Authenticated, empty collection: "Save a codeome in your Sandbox first" + link.
  - Authenticated, lineage=0: codeome dropdown + Seed button.
  - Authenticated, lineage>0: lineage count + Apoptosis (with confirm) button.
  """
  use LeniesWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:apoptosis_confirming, fn -> false end)
     |> assign_new(:flash_msg, fn -> nil end)
     |> assign(:codeomes, codeomes_for(assigns[:current_scope]))}
  end

  defp codeomes_for(nil), do: []
  defp codeomes_for(%{user: nil}), do: []
  defp codeomes_for(%{user: user}), do: Lenies.Collection.list_codeomes(user)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="arena-controls flex flex-col gap-2">
      <%= cond do %>
        <% is_nil(@current_scope) or is_nil(@current_scope.user) -> %>
          <p class="text-[11px] opacity-80">Log in to seed your Lenie in the Arena.</p>
          <.link
            navigate={~p"/users/log-in"}
            class="self-start px-2 py-1 text-xs border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40 whitespace-nowrap"
          >
            Log in
          </.link>
        <% @codeomes == [] -> %>
          <p class="text-[11px] opacity-80">Save a codeome in your Sandbox first.</p>
          <.link
            navigate={~p"/sandbox/editor/new"}
            class="self-start px-2 py-1 text-xs border border-cyan-500/60 text-cyan-200 hover:bg-cyan-900/40 whitespace-nowrap"
          >
            Open the editor
          </.link>
        <% @lineage_count == 0 -> %>
          <.form
            for={%{}}
            as={:seed}
            phx-submit="seed"
            phx-target={@myself}
            class="flex items-center gap-2"
          >
            <select name="codeome_id" class="flex-1 text-xs">
              <%= for c <- @codeomes do %>
                <option value={c.id}>{c.name}</option>
              <% end %>
            </select>
            <button
              id="arena-seed-btn"
              phx-hook="ActionFeedback"
              data-fx="success"
              type="submit"
              class="text-xs px-3 py-1 border border-cyan-500/60 bg-cyan-900/30 text-cyan-200 hover:bg-cyan-800/50 whitespace-nowrap"
            >
              Seed your Lenie
            </button>
          </.form>
        <% @apoptosis_confirming -> %>
          <div
            id="apoptosis-confirm"
            phx-hook="ActionFeedback"
            data-fx="danger"
            class="flex flex-col gap-1 p-2 border border-rose-500/60 bg-rose-950/40"
          >
            <p class="text-[11px] text-rose-200">
              Stop all {@lineage_count} of your Lenies in the Arena?
            </p>
            <div class="flex gap-1">
              <button
                type="button"
                phx-click="apoptosis_confirm"
                phx-target={@myself}
                class="flex-1 text-xs px-2 py-1 border border-rose-500 bg-rose-700/40 text-rose-100 hover:bg-rose-600/60"
              >
                Confirm
              </button>
              <button
                type="button"
                phx-click="apoptosis_cancel"
                phx-target={@myself}
                class="flex-1 text-xs px-2 py-1 border border-slate-500 bg-slate-800 hover:bg-slate-700"
              >
                Cancel
              </button>
            </div>
          </div>
        <% true -> %>
          <p class="text-[11px] opacity-80">Your lineage: {@lineage_count} Lenies alive</p>
          <button
            id="apoptosis-btn"
            phx-hook="ActionFeedback"
            data-fx="danger"
            type="button"
            phx-click="apoptosis_init"
            phx-target={@myself}
            class="self-start text-xs px-2 py-2 border border-rose-500/60 bg-rose-900/30 text-rose-200 hover:bg-rose-800/50 hover:text-rose-100 tracking-widest"
          >
            ⌷ Apoptosis ({@lineage_count})
          </button>
      <% end %>

      <%= if @flash_msg do %>
        <p class="flash text-[11px] text-cyan-200">{@flash_msg}</p>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("seed", %{"codeome_id" => codeome_id_str}, socket) do
    codeome_id = String.to_integer(codeome_id_str)
    user = socket.assigns.current_scope.user

    case Lenies.Arena.seed(user, codeome_id) do
      {:ok, :seeded} ->
        send(self(), {:arena_lineage_changed, user.id})
        {:noreply, assign(socket, :flash_msg, "Seeded!")}

      {:error, :lineage_alive, n} ->
        send(self(), {:arena_lineage_changed, user.id})
        {:noreply, assign(socket, :flash_msg, "Your lineage is alive (#{n}).")}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Seed failed: #{inspect(reason)}")}
    end
  end

  def handle_event("apoptosis_init", _, socket),
    do: {:noreply, assign(socket, :apoptosis_confirming, true)}

  def handle_event("apoptosis_cancel", _, socket),
    do: {:noreply, assign(socket, :apoptosis_confirming, false)}

  def handle_event("apoptosis_confirm", _, socket) do
    user = socket.assigns.current_scope.user
    {:ok, count} = Lenies.Arena.apoptosis(user)
    send(self(), {:arena_lineage_changed, user.id})

    {:noreply,
     socket
     |> assign(:apoptosis_confirming, false)
     |> assign(:flash_msg, "Apoptosis: #{count} Lenies stopped.")}
  end
end
