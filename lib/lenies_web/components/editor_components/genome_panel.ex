defmodule LeniesWeb.EditorComponents.GenomePanel do
  @moduledoc """
  Right-pane GENOME tab of the codeome editor: the chromosome row, one row
  per plasmid (with goto-section + a two-step remove confirm), and the
  "+ Plasmid" button. The tab buttons live in the parent pane wrapper in
  EditorLive; this component renders the tab body. Events land on the
  parent LiveView (no phx-target).
  """
  use LeniesWeb, :html

  alias LeniesWeb.GenomeBuffer

  attr :genome, GenomeBuffer, required: true
  attr :plasmid_remove_confirming, :any, default: nil

  def genome_panel(assigns) do
    ~H"""
    <div class="codeome-genome-panel">
      <div class="codeome-genome-row">
        <button
          type="button"
          phx-click="goto_section"
          phx-value-section="chromosome"
          class="codeome-tool-btn"
        >
          Chromosome
        </button>
        <span class="opacity-70">{length(@genome.chromosome)} ops</span>
      </div>

      <%= for {buf, i} <- Enum.with_index(@genome.plasmids) do %>
        <div class="codeome-genome-row" data-plasmid-row={i}>
          <button
            type="button"
            phx-click="goto_section"
            phx-value-section={"p#{i}"}
            class="codeome-tool-btn"
          >
            Plasmid {plasmid_letter(i)}
          </button>
          <span class="opacity-70">{length(buf)}/{Lenies.Plasmid.max_length()}</span>
          <%= if @plasmid_remove_confirming == i do %>
            <span class="codeome-plasmid-confirm">
              <span class="codeome-plasmid-confirm-q">Delete?</span>
              <button
                type="button"
                phx-click="plasmid_remove_confirm"
                class="codeome-confirm-btn codeome-confirm-btn-danger"
              >
                Yes
              </button>
              <button
                type="button"
                phx-click="plasmid_remove_cancel"
                class="codeome-confirm-btn"
              >
                Cancel
              </button>
            </span>
          <% else %>
            <button
              type="button"
              phx-click="plasmid_remove_init"
              phx-value-index={i}
              class="codeome-plasmid-del-btn"
            >
              ⨯
            </button>
          <% end %>
        </div>
      <% end %>

      <button type="button" phx-click="add_plasmid" class="codeome-tool-btn">
        + Plasmid
      </button>
      <p class="codeome-snippets-empty">
        Plasmid code is edited in the central listing, below its divider.
      </p>
    </div>
    """
  end

  # twin of LeniesWeb.EditorComponents.Listing.plasmid_letter/1
  # Plasmid IDENTITY is shown as a letter (A, B, C…) so it never reads as a
  # quantity. Beyond 26 plasmids (never realistic) we fall back to a number.
  defp plasmid_letter(i) when i in 0..25, do: <<?A + i>>
  defp plasmid_letter(i), do: "##{i + 1}"
end
