defmodule LeniesWeb.SpeciesInspectorComponent do
  @moduledoc """
  Read-only side panel showing the disassembled codeome of the selected species.

  Rendered as the third column of the dashboard top row, visible only when the
  parent `LeniesWeb.DashboardLive` has a non-nil `selected_hash`. The codeome
  is immutable per hash, so the component caches the disassembled lines and
  refetches only when `selected_hash` changes. Population and average
  generation come from the parent via `species_record` and refresh on every
  parent update (same throttle as the species table).
  """

  use LeniesWeb, :live_component

  alias Lenies.SpeciesColor
  alias LeniesWeb.Disassembler

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:codeome_lines, [])
     |> assign(:fetch_status, :ok)
     |> assign(:cached_codeome_hash, nil)}
  end

  @impl true
  def update(%{selected_hash: hash} = assigns, socket)
      when is_binary(hash) and hash != "" do
    if hash == socket.assigns.cached_codeome_hash do
      {:ok, assign(socket, assigns)}
    else
      {status, lines} = fetch_codeome(hash)

      {:ok,
       socket
       |> assign(assigns)
       |> assign(:codeome_lines, lines)
       |> assign(:fetch_status, status)
       |> assign(:cached_codeome_hash, hash)}
    end
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id="species-inspector"
      class="panel w-[320px] shrink-0 flex flex-col gap-2 p-3 min-h-0"
    >
      <header class="flex items-center gap-2">
        <span
          class="inline-block w-3 h-3 shrink-0"
          style={"background:#{SpeciesColor.hex(@selected_hash)}"}
        >
        </span>
        <h2 class="text-xs flex-1 truncate">
          {String.slice(@selected_hash, 0..15)}…
        </h2>
        <.link
          navigate={~p"/species/#{@selected_hash}"}
          class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
          title="Open full species page"
        >
          ↗
        </.link>
        <button
          phx-click="select_species"
          phx-value-hash={@selected_hash}
          class="text-xs px-1.5 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
        >
          ×
        </button>
      </header>

      <div class="grid grid-cols-3 gap-2 text-[11px]">
        <div class="border border-cyan-500/30 px-2 py-1">
          <div class="opacity-60">pop.</div>
          <div class="text-cyan-300 font-bold tabular-nums text-base">
            {population(@species_record)}
          </div>
        </div>
        <div class="border border-violet-500/30 px-2 py-1">
          <div class="opacity-60">gen.</div>
          <div class="text-violet-300 font-bold tabular-nums text-base">
            {avg_gen(@species_record)}
          </div>
        </div>
        <div class="border border-emerald-500/30 px-2 py-1">
          <div class="opacity-60">ops</div>
          <div class="text-emerald-300 font-bold tabular-nums text-base">
            {length(@codeome_lines)}
          </div>
        </div>
      </div>

      <%= if @fetch_status == :no_sample do %>
        <p class="text-[10px] opacity-60">
          Nessun Lenie vivo di questa specie. Codeome non disponibile.
        </p>
      <% end %>

      <div class="flex-1 min-h-0 overflow-auto">
        <div class="text-[10px] leading-tight font-mono">
          <%= for line <- @codeome_lines do %>
            <div class="flex gap-2">
              <span class="opacity-50 tabular-nums w-8 shrink-0">
                {String.pad_leading(Integer.to_string(line.index), 3, " ")}
              </span>
              <span class={"op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
                {Atom.to_string(line.opcode)}
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </aside>
    """
  end

  defp population(%{population: n}), do: n
  defp population(_), do: 0

  defp avg_gen(%{avg_generation: g}) when is_float(g), do: Float.round(g, 2)
  defp avg_gen(%{avg_generation: g}) when is_integer(g), do: g
  defp avg_gen(_), do: 0

  # Pull a representative Lenie process for the species and disassemble its
  # codeome. Returns {:ok, lines} | {:no_sample, []} | {:error, []}.
  defp fetch_codeome(hash) do
    case Lenies.Species.for_hash(hash) do
      [] ->
        {:no_sample, []}

      [{sample_id, _} | _] ->
        case safe_whereis(sample_id) do
          pid when is_pid(pid) ->
            try do
              case GenServer.call(pid, :get_codeome, 1_000) do
                {:ok, codeome} -> {:ok, Disassembler.disassemble(codeome, nil)}
                _ -> {:error, []}
              end
            catch
              :exit, _ -> {:error, []}
            end

          _ ->
            {:no_sample, []}
        end
    end
  end

  defp safe_whereis(id) do
    try do
      Lenies.Registry.whereis(id)
    catch
      :exit, _ -> nil
    end
  end
end
