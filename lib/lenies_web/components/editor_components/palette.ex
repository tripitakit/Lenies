defmodule LeniesWeb.EditorComponents.Palette do
  @moduledoc """
  Left pane of the codeome editor: the free-text opcode input, the grouped
  opcode-chip palette (drag/dblclick source), and the snippets section.
  Events land on the parent LiveView (no phx-target).
  """
  use LeniesWeb, :html

  alias LeniesWeb.Disassembler

  attr :text_input_value, :string, required: true
  attr :text_input_error, :string, default: nil
  attr :snippets, :list, required: true
  attr :show_snippet_form, :boolean, required: true
  attr :snippet_form_error, :string, default: nil

  def palette(assigns) do
    ~H"""
    <section class="codeome-palette-pane min-h-0">
      <div class="codeome-palette-pane-title">
        Opcodes — drag, dblclick, or type → the caret's section
      </div>

      <form phx-submit="submit_opcode_text" class="palette-text-input-form">
        <input
          type="text"
          name="opcodes"
          value={@text_input_value}
          placeholder="e.g. push0 push1 add"
          autocomplete="off"
          spellcheck="false"
          class="palette-text-input"
        />
        <button type="submit" class="palette-text-input-submit" title="Append opcodes">
          +
        </button>
      </form>

      <%= if @text_input_error do %>
        <p class="palette-text-input-error">⚠ {@text_input_error}</p>
      <% end %>

      <div class="codeome-palette" id="palette-grid" phx-hook="CodeomePalette">
        <%= for {category, ops} <- grouped_opcodes() do %>
          <div class="palette-category">
            <div class="palette-category-label">{category_label(category)}</div>
            <div class="palette-category-chips">
              <%= for op <- ops do %>
                <div
                  class={"palette-chip op op-" <> Atom.to_string(Disassembler.opcode_class(op))}
                  data-opcode={Atom.to_string(op)}
                >
                  {Atom.to_string(op) |> String.upcase()}
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <div class="codeome-snippets" id="codeome-snippets">
        <div class="codeome-snippets-title">Snippets</div>
        <%= if @show_snippet_form do %>
          <form phx-submit="submit_snippet" class="codeome-snippet-form">
            <input
              type="text"
              name="snippet_name"
              required
              minlength="1"
              maxlength="40"
              placeholder="snippet name"
              autocomplete="off"
              class="palette-text-input"
            />
            <button type="submit" class="palette-text-input-submit" title="Save snippet">
              ✓
            </button>
            <button
              type="button"
              phx-click="cancel_snippet_form"
              class="palette-text-input-submit"
              title="Cancel"
            >
              ⨯
            </button>
            <%= if @snippet_form_error do %>
              <span class="text-red-400 text-[11px] mt-1 block" role="alert">
                {@snippet_form_error}
              </span>
            <% end %>
          </form>
        <% end %>
        <%= if @snippets == [] do %>
          <p class="codeome-snippets-empty">
            no snippets — select blocks and press Save as snippet
          </p>
        <% else %>
          <div class="codeome-snippets-list" id="codeome-snippets-list" phx-hook="SnippetDrag">
            <%= for s <- @snippets do %>
              <div class="codeome-snippet-row" data-snippet-id={s.id}>
                <button
                  type="button"
                  phx-click="insert_snippet"
                  phx-value-id={s.id}
                  class="codeome-snippet-insert"
                  title={"Insert (#{length(s.opcodes)} ops)"}
                >
                  {s.name}
                </button>
                <button
                  type="button"
                  phx-click="delete_snippet"
                  phx-value-id={s.id}
                  class="codeome-snippet-del"
                  title="Delete snippet"
                >
                  ⨯
                </button>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  defp grouped_opcodes do
    Lenies.Codeome.Opcodes.all()
    |> Enum.group_by(&Disassembler.opcode_class/1)
    |> Enum.sort_by(fn {class, _} -> class_order(class) end)
  end

  defp class_order(:template), do: 0
  defp class_order(:stack), do: 1
  defp class_order(:arith), do: 2
  defp class_order(:control), do: 3
  defp class_order(:sense), do: 4
  defp class_order(:action), do: 5
  defp class_order(:predation), do: 6
  defp class_order(:self_inspect), do: 7
  defp class_order(:replication), do: 8
  defp class_order(:memory), do: 9
  defp class_order(:hgt), do: 10
  defp class_order(_), do: 11

  # The palette category label is rendered (and CSS-uppercased) as-is for
  # most classes — the class atom doubles as the label. The horizontal-
  # transfer class is the exception: its atom (:hgt) is not a readable name.
  defp category_label(:hgt), do: "Horizontal Code Transfer"
  defp category_label(other), do: Atom.to_string(other)
end
