defmodule LeniesWeb.EditorComponents.Listing do
  @moduledoc """
  Central sectioned-listing pane of the codeome editor: energy panel,
  toolbar, status banners, the genome listing with debug overlay (IP /
  breakpoint highlights, bp-toggle, runtime-plasmid tail), and the loop-arc
  gutter. Events land on the parent LiveView (no phx-target).
  """
  use LeniesWeb, :html

  alias LeniesWeb.{Disassembler, EditorHistory, GenomeBuffer, GenomeCaret}

  attr :genome, GenomeBuffer, required: true
  attr :caret, :any, required: true
  attr :anchor, :any, required: true
  attr :clipboard, :list, required: true
  attr :history, :any, required: true
  attr :economics, :map, required: true
  attr :jump_targets, :map, required: true
  attr :editing_addr, :any, default: nil
  attr :inline_edit_error, :string, default: nil
  attr :session, :any, default: nil
  attr :stepper_notice, :any, default: nil
  attr :loops, :list, default: []

  def listing(assigns) do
    ~H"""
    <section class="codeome-listing-pane min-h-0">
      <%!-- Static energy budget for one linear pass through the buffer
            — cost is exact, max gain assumes every EAT/ATTACK hits.
            Reflects current eat_amount / attack_damage tuning at the
            time the buffer last changed. --%>
      <div class="codeome-energy-panel" id="codeome-energy-panel">
        <div class="codeome-energy-panel-head">
          <span class="codeome-energy-panel-title">Energy / pass</span>
          <span class="codeome-energy-panel-note">
            {@economics.n_eat} eat × {fmt_num(@economics.eat_amount)} + {@economics.n_attack} attack × {fmt_num(
              @economics.attack_damage
            )} · allocate sized {@economics.alloc_size}
          </span>
        </div>
        <div class="grid grid-cols-3 gap-2 text-[11px]">
          <div class="codeome-energy-stat codeome-energy-stat-cost">
            <div class="codeome-energy-stat-label">cost</div>
            <div class="codeome-energy-stat-value">{fmt_num(@economics.cost)}</div>
          </div>
          <div class="codeome-energy-stat codeome-energy-stat-gain">
            <div class="codeome-energy-stat-label">max gain</div>
            <div class="codeome-energy-stat-value">{fmt_num(@economics.max_gain)}</div>
          </div>
          <div class={[
            "codeome-energy-stat",
            if(@economics.net >= 0,
              do: "codeome-energy-stat-gain",
              else: "codeome-energy-stat-cost"
            )
          ]}>
            <div class="codeome-energy-stat-label">net</div>
            <div class="codeome-energy-stat-value">
              {if @economics.net >= 0, do: "+", else: ""}{fmt_num(@economics.net)}
            </div>
          </div>
        </div>
      </div>
      <% range = GenomeCaret.derive_range({@caret, @anchor}) %>
      <div class="codeome-toolbar">
        <button
          type="button"
          phx-click="copy_selection"
          disabled={!has_selection?(range)}
          class="codeome-tool-btn"
          title="Copy (Ctrl/Cmd+C)"
        >
          Copy
        </button>
        <button
          type="button"
          phx-click="cut_selection"
          disabled={!has_selection?(range)}
          class="codeome-tool-btn"
          title="Cut (Ctrl/Cmd+X)"
        >
          Cut
        </button>
        <button
          type="button"
          phx-click="paste_clipboard"
          disabled={!has_clipboard?(@clipboard)}
          class="codeome-tool-btn"
          title="Paste (Ctrl/Cmd+V)"
        >
          Paste
        </button>
        <button
          type="button"
          phx-click="duplicate_selection"
          disabled={!has_selection?(range)}
          class="codeome-tool-btn"
          title="Duplicate (Ctrl/Cmd+D)"
        >
          Duplicate
        </button>
        <button
          type="button"
          phx-click="delete_selection"
          disabled={!has_selection?(range)}
          class="codeome-tool-btn"
          title="Delete (Del)"
        >
          Delete
        </button>
        <span class="codeome-toolbar-sep"></span>
        <button
          type="button"
          phx-click="undo"
          disabled={!EditorHistory.can_undo?(@history)}
          class="codeome-tool-btn"
          title="Undo (Ctrl/Cmd+Z)"
        >
          Undo
        </button>
        <button
          type="button"
          phx-click="redo"
          disabled={!EditorHistory.can_redo?(@history)}
          class="codeome-tool-btn"
          title="Redo (Ctrl/Cmd+Shift+Z)"
        >
          Redo
        </button>
        <span class="codeome-toolbar-sep"></span>
        <button
          type="button"
          phx-click="open_snippet_form"
          disabled={!has_selection?(range)}
          class="codeome-tool-btn"
          title="Save selection as snippet"
        >
          Save as snippet
        </button>
      </div>
      <div class="codeome-listing-pane-title">
        Genome — {length(GenomeBuffer.to_exec_list(@genome))} ops
      </div>
      <datalist id="opcode-datalist">
        <%= for op <- Lenies.Codeome.Opcodes.all() do %>
          <option value={Atom.to_string(op)}></option>
        <% end %>
      </datalist>
      <% template_nops = template_nop_indices(GenomeBuffer.to_exec_list(@genome)) %>
      <% overlay = debug_overlay(assigns) %>
      <% overlay_on? = overlay == :match or match?({:tail, _}, overlay) %>
      <%= if @stepper_notice == :invalid_genome do %>
        <div class="stepper-status-banner stepper-status-banner-halted">
          Debug session ended: the genome is no longer valid.
        </div>
      <% end %>
      <%= if @session do %>
        <%= cond do %>
          <% @session.status == :halted -> %>
            <div class="stepper-status-banner stepper-status-banner-halted">
              Halted: {@session.halt_reason}
            </div>
          <% @session.status == :breakpoint_hit -> %>
            <div class="stepper-status-banner stepper-status-banner-breakpoint">
              Stopped at breakpoint @ ip {@session.interp.ip}
            </div>
          <% @session.status == :safety_cap_reached -> %>
            <div class="stepper-status-banner stepper-status-banner-safety">
              Safety cap (10k steps) — paused
            </div>
          <% overlay == :diverged -> %>
            <div class="stepper-status-banner stepper-status-banner-safety">
              Runtime genome diverged (plasmids changed during execution) —
              row overlay suspended; ip {@session.interp.ip} shown in the inspector.
            </div>
          <% true -> %>
        <% end %>
      <% end %>
      <div
        id="codeome-listing"
        class="codeome-listing-sections"
        phx-hook="LoopArcs"
        data-loops={Jason.encode!(Enum.map(@loops, &Tuple.to_list/1))}
        data-ip={@session && @session.interp.ip}
      >
        <svg class="codeome-loop-gutter" aria-hidden="true"></svg>
        <%= for {section, buf} <- GenomeBuffer.sections(@genome) do %>
          <% sec = encode_section(section) %>
          <%= if section != :chromosome do %>
            <div class="codeome-section-divider" data-section-divider={sec}>
              ── plasmid {plasmid_letter(elem(section, 1))} ({length(buf)}/{Lenies.Plasmid.max_length()}) ──
            </div>
          <% end %>
          <div
            class="codeome-blocks"
            id={"codeome-blocks-" <> sec}
            data-section={sec}
            phx-hook="CodeomeSortable"
          >
            <%= for {opcode, idx} <- Enum.with_index(buf) do %>
              <% flat = GenomeBuffer.flat_index(@genome, section, idx) %>
              <div
                class={["codeome-gap", caret_here?(@caret, section, idx) && "codeome-gap-caret"]}
                data-section={sec}
                data-gap={idx}
                phx-click="place_caret"
                phx-value-section={sec}
                phx-value-gap={idx}
              >
              </div>
              <div
                class={[
                  "codeome-block codeome-block-editable op op-" <>
                    Atom.to_string(Disassembler.opcode_class(opcode)),
                  selected?(range, section, idx) && "codeome-block-selected",
                  MapSet.member?(template_nops, flat) && "codeome-template-nop",
                  overlay_on? && flat == @session.interp.ip && "codeome-block-ip",
                  overlay_on? && MapSet.member?(@session.breakpoints, flat) &&
                    "codeome-block-bp"
                ]}
                data-section={sec}
                data-idx={idx}
                data-flat={flat}
                data-current={overlay_on? && flat == @session.interp.ip && "true"}
              >
                <span class="codeome-drag-handle" title="Drag to reorder">≡</span>
                <%= if overlay_on? do %>
                  <button
                    type="button"
                    class="codeome-block-idx codeome-bp-toggle"
                    phx-click="stepper_toggle_bp"
                    phx-value-ip={flat}
                    title="Toggle breakpoint"
                  >
                    {String.pad_leading(Integer.to_string(flat), 3, "0")}
                  </button>
                <% else %>
                  <span class="codeome-block-idx">
                    {String.pad_leading(Integer.to_string(flat), 3, "0")}
                  </span>
                <% end %>
                <%= if @editing_addr == {section, idx} do %>
                  <form phx-submit="submit_replace" class="codeome-inline-edit">
                    <input type="hidden" name="section" value={sec} />
                    <input type="hidden" name="index" value={idx} />
                    <input
                      type="text"
                      name="opcode"
                      value={Atom.to_string(opcode)}
                      list="opcode-datalist"
                      autocomplete="off"
                      spellcheck="false"
                      phx-blur="cancel_inline_edit"
                      phx-keydown="cancel_inline_edit"
                      phx-key="Escape"
                      phx-mounted={JS.focus()}
                      class="codeome-inline-input"
                    />
                    <%= if @inline_edit_error do %>
                      <span class="codeome-inline-error" title={@inline_edit_error}>⚠</span>
                    <% end %>
                  </form>
                <% else %>
                  <span class="codeome-block-name">
                    {Atom.to_string(opcode) |> String.upcase()}
                  </span>
                <% end %>
                <%= case Map.get(@jump_targets, flat) do %>
                  <% {:ok, target} -> %>
                    <button
                      type="button"
                      phx-click="jump_to_flat"
                      phx-value-flat={target}
                      class="codeome-jump-badge"
                      title={"Jumps to ##{target}"}
                    >
                      → {String.pad_leading(Integer.to_string(target), 3, "0")}
                    </button>
                  <% :not_found -> %>
                    <span
                      class="codeome-jump-badge codeome-jump-badge-missing"
                      title="No template match"
                    >
                      → ✕
                    </span>
                  <% nil -> %>
                <% end %>
                <span class="codeome-block-actions">
                  <button
                    type="button"
                    phx-click="edit_delete"
                    phx-value-section={sec}
                    phx-value-index={idx}
                    class="codeome-action-btn"
                    title="Delete"
                  >
                    ⨯
                  </button>
                </span>
              </div>
            <% end %>
            <div
              class={[
                "codeome-gap codeome-gap-end",
                caret_here?(@caret, section, length(buf)) && "codeome-gap-caret"
              ]}
              data-section={sec}
              data-gap={length(buf)}
              phx-click="place_caret"
              phx-value-section={sec}
              phx-value-gap={length(buf)}
            >
            </div>
          </div>
        <% end %>
        <%= case overlay do %>
          <% {:tail, extra} -> %>
            <div class="codeome-section-divider">── runtime plasmids (read-only) ──</div>
            <div class="codeome-blocks codeome-blocks-runtime">
              <% base = length(GenomeBuffer.to_exec_list(@genome)) %>
              <%= for {op, off} <- Enum.with_index(extra) do %>
                <% flat = base + off %>
                <div
                  class={[
                    "codeome-block op op-" <> Atom.to_string(Disassembler.opcode_class(op)),
                    flat == @session.interp.ip && "codeome-block-ip",
                    MapSet.member?(@session.breakpoints, flat) && "codeome-block-bp"
                  ]}
                  data-flat={flat}
                  data-current={flat == @session.interp.ip && "true"}
                >
                  <button
                    type="button"
                    class="codeome-block-idx codeome-bp-toggle"
                    phx-click="stepper_toggle_bp"
                    phx-value-ip={flat}
                  >
                    {String.pad_leading(Integer.to_string(flat), 3, "0")}
                  </button>
                  <span class="codeome-block-name">{Atom.to_string(op) |> String.upcase()}</span>
                </div>
              <% end %>
            </div>
          <% _ -> %>
        <% end %>
      </div>
    </section>
    """
  end

  defp selected?(nil, _section, _idx), do: false
  defp selected?({s, {lo, hi}}, section, idx), do: s == section and idx >= lo and idx <= hi

  defp caret_here?({s, gap}, section, g), do: s == section and gap == g

  defp has_selection?(nil), do: false
  defp has_selection?(_range), do: true

  defp has_clipboard?([]), do: false
  defp has_clipboard?(list) when is_list(list), do: true

  # twin of EditorLive.encode_section/1 (the param/DOM section encoding).
  defp encode_section(:chromosome), do: "chromosome"
  defp encode_section({:plasmid, i}), do: "p#{i}"

  # Plasmid IDENTITY is shown as a letter (A, B, C…) so it never reads as a
  # quantity. Beyond 26 plasmids (never realistic) we fall back to a number.
  # See also EditorComponents.GenomePanel.plasmid_letter/1 (its twin).
  defp plasmid_letter(i) when i in 0..25, do: <<?A + i>>
  defp plasmid_letter(i), do: "##{i + 1}"

  # Session-vs-editor geography:
  #   :off               — no session
  #   :match             — exec list == authored flat list (the common case)
  #   {:tail, extra_ops} — execution GAINED plasmids (make_plasmid): authored
  #                        list is a strict prefix; extra rows render read-only
  #   :diverged          — plasmids were lost/replaced mid-run: flat indices
  #                        no longer line up; suppress row overlay (the
  #                        inspector still shows the ip) rather than lie.
  defp debug_overlay(%{session: nil}), do: :off

  defp debug_overlay(%{session: session, genome: genome}) do
    exec = Lenies.Codeome.to_list(session.exec_codeome)
    authored = GenomeBuffer.to_exec_list(genome)

    cond do
      exec == authored -> :match
      List.starts_with?(exec, authored) -> {:tail, Enum.drop(exec, length(authored))}
      true -> :diverged
    end
  end

  # Compact numeric display for the energy panel: integers as-is,
  # floats rounded to 1 decimal (drops the `.0` when whole).
  defp fmt_num(n) when is_integer(n), do: Integer.to_string(n)

  defp fmt_num(n) when is_float(n) do
    rounded = Float.round(n, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end

  @jump_opcodes LeniesWeb.JumpTargets.jump_opcodes()

  # Indices of nop_0/nop_1 that form the template immediately following a jump.
  defp template_nop_indices(buffer) do
    max_len = Application.get_env(:lenies, :template_max_len, 8)

    buffer
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {op, i} when op in @jump_opcodes ->
        Enum.reduce_while((i + 1)..(i + max_len)//1, [], fn j, acc ->
          case Enum.at(buffer, j) do
            n when n in [:nop_0, :nop_1] -> {:cont, [j | acc]}
            _ -> {:halt, acc}
          end
        end)

      _ ->
        []
    end)
    |> MapSet.new()
  end
end
