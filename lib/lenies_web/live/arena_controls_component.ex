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
    <div class="arena-controls">
      <%= cond do %>
        <% is_nil(@current_scope) or is_nil(@current_scope.user) -> %>
          <p>Log in to seed your Lenie in the Arena.</p>
          <.link navigate={~p"/users/log-in"}>Log in</.link>
        <% @codeomes == [] -> %>
          <p>Save a codeome in your Sandbox first.</p>
          <.link navigate={~p"/sandbox/editor/new"}>Open the editor</.link>
        <% @lineage_count == 0 -> %>
          <.form for={%{}} as={:seed} phx-submit="seed" phx-target={@myself}>
            <select name="codeome_id">
              <%= for c <- @codeomes do %>
                <option value={c.id}>{c.name}</option>
              <% end %>
            </select>
            <button type="submit">Seed your Lenie</button>
          </.form>
        <% @apoptosis_confirming -> %>
          <p>Stop all {@lineage_count} of your Lenies in the Arena?</p>
          <button type="button" phx-click="apoptosis_confirm" phx-target={@myself}>Confirm</button>
          <button type="button" phx-click="apoptosis_cancel" phx-target={@myself}>Cancel</button>
        <% true -> %>
          <p>Your lineage: {@lineage_count} Lenies alive</p>
          <button type="button" phx-click="apoptosis_init" phx-target={@myself}>
            Apoptosis ({@lineage_count})
          </button>
      <% end %>

      <%= if @flash_msg do %>
        <p class="flash">{@flash_msg}</p>
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
