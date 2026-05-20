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

  alias LeniesWeb.Disassembler

  @default_chapter "02-opcode-reference.md"

  @impl true
  def mount(params, _session, socket) do
    {mode, selected_hash, buffer} = init_for_route(socket.assigns.live_action, params)

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:selected_hash, selected_hash)
      |> assign(:buffer, buffer)
      |> assign(:original_buffer, buffer)
      |> assign(:dirty, false)
      |> assign(:validation, LeniesWeb.CodeomeBuffer.validate(buffer))
      |> assign(:economics, current_economics(buffer))
      |> assign(:show_spawn_form, false)
      |> assign(:show_save_form, false)
      |> assign(:current_chapter, @default_chapter)
      |> assign(:manual_collapsed?, false)
      |> assign(:text_input_value, "")
      |> assign(:text_input_error, nil)
      |> assign(:selection, nil)
      |> assign(:sel_anchor, nil)

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

  def handle_event("edit_delete", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    new_buffer = LeniesWeb.CodeomeBuffer.delete(socket.assigns.buffer, index)
    {:noreply, apply_buffer_change(socket, new_buffer)}
  end

  def handle_event("edit_reorder", %{"from" => from, "to" => to}, socket) do
    new_buffer = LeniesWeb.CodeomeBuffer.move(socket.assigns.buffer, from, to)
    {:noreply, apply_buffer_change(socket, new_buffer)}
  end

  def handle_event("edit_insert", %{"index" => index, "opcode" => opcode_str}, socket)
      when is_integer(index) and is_binary(opcode_str) do
    try do
      opcode = String.to_existing_atom(opcode_str)

      if Lenies.Codeome.Opcodes.known?(opcode) do
        new_buffer = LeniesWeb.CodeomeBuffer.insert(socket.assigns.buffer, index, opcode)
        {:noreply, apply_buffer_change(socket, new_buffer)}
      else
        {:noreply, socket}
      end
    rescue
      ArgumentError -> {:noreply, socket}
    end
  end

  def handle_event("open_spawn_form", _params, socket) do
    {:noreply, assign(socket, show_spawn_form: true, show_save_form: false)}
  end

  def handle_event("cancel_spawn_form", _params, socket) do
    {:noreply, assign(socket, :show_spawn_form, false)}
  end

  def handle_event("submit_spawn", %{"count" => count_str, "energy" => energy_str}, socket) do
    count = parse_clamped(count_str, 1, 50, 1)
    energy = parse_clamped(energy_str, 1, 1_000_000, 10_000)

    case socket.assigns.validation do
      {:ok, _} ->
        codeome = LeniesWeb.CodeomeBuffer.to_codeome(socket.assigns.buffer)
        dirs = [:n, :s, :e, :w]
        seed_origin = spawn_seed_origin(socket.assigns)

        Enum.each(1..count, fn _ ->
          Lenies.World.spawn_lenie(codeome,
            energy: energy * 1.0,
            dir: Enum.random(dirs),
            seed_origin: seed_origin
          )
        end)

        {:noreply, push_navigate(socket, to: ~p"/")}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("open_save_form", _params, socket) do
    {:noreply, assign(socket, show_save_form: true, show_spawn_form: false)}
  end

  def handle_event("cancel_save_form", _params, socket) do
    {:noreply, assign(socket, :show_save_form, false)}
  end

  def handle_event(
        "submit_save_seed",
        %{"seed_name" => name, "color_hex" => color, "energy_default" => energy_str},
        socket
      ) do
    case socket.assigns.validation do
      {:ok, _} ->
        seed = %{
          id: Lenies.Slug.slugify(name),
          name: name,
          color_hex: color,
          energy_default: parse_clamped(energy_str, 1, 1_000_000, 10_000) * 1.0,
          opcodes: socket.assigns.buffer
        }

        case Lenies.Seeds.CustomStore.save(seed) do
          :ok ->
            Phoenix.LiveView.send_update(LeniesWeb.ControlsPanelComponent,
              id: "controls",
              refresh_custom_seeds: true
            )

            {:noreply, push_navigate(socket, to: ~p"/")}

          {:error, _reason} ->
            {:noreply, socket}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_event("submit_opcode_text", %{"opcodes" => text}, socket) do
    case parse_opcode_text(text) do
      {:ok, []} ->
        {:noreply, assign(socket, text_input_value: "", text_input_error: nil)}

      {:ok, opcodes} ->
        new_buffer = socket.assigns.buffer ++ opcodes

        {:noreply,
         socket
         |> apply_buffer_change(new_buffer)
         |> assign(text_input_value: "", text_input_error: nil)}

      {:error, invalid} ->
        msg = "unknown: " <> Enum.join(invalid, ", ")
        {:noreply, assign(socket, text_input_value: text, text_input_error: msg)}
    end
  end

  def handle_event("select_block", %{"index" => index, "shift" => shift}, socket) do
    index = to_int(index)
    len = length(socket.assigns.buffer)

    if index < 0 or index >= len do
      {:noreply, socket}
    else
      # shift arrives as a boolean from the JS hook / render_hook; accept the
      # "true" string form too for robustness.
      {selection, anchor} =
        if shift in [true, "true"] and is_integer(socket.assigns.sel_anchor) do
          a = socket.assigns.sel_anchor
          {{min(a, index), max(a, index)}, a}
        else
          {{index, index}, index}
        end

      {:noreply, assign(socket, selection: selection, sel_anchor: anchor)}
    end
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selection: nil, sel_anchor: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="editor-root"
      phx-hook="RememberManualState"
      class="lenies-dashboard codeome-editor-page h-screen w-screen overflow-hidden"
    >
      <header class="codeome-editor-page-header">
        <.link
          navigate={~p"/"}
          class="text-xs px-2 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
        >
          ← Back
        </.link>
        <h1 class="text-sm flex-1">
          <%= if @mode == :new_seed do %>
            New Seed
          <% else %>
            Edit: {String.slice(@selected_hash || "", 0..15)}…
          <% end %>
        </h1>

        <span class="text-[10px]">
          <%= case @validation do %>
            <% {:ok, info} -> %>
              <span class="text-emerald-300">✓ valid</span>
              <span class="opacity-60">({info.len} ops, {info.non_nops} non-nop)</span>
            <% {:error, errors} -> %>
              <span class="text-amber-300">⚠</span>
              <span class="opacity-80">
                {Enum.map_join(errors, ", ", &format_validation_error/1)}
              </span>
          <% end %>
        </span>

        <%= if @dirty do %>
          <span class="text-amber-300 text-[10px]">●dirty</span>
        <% end %>

        <button
          type="button"
          phx-click="cancel_edit"
          data-confirm={if @dirty, do: "Discard codeome edits?"}
          class="text-xs px-2 py-0.5 border border-slate-500 hover:bg-slate-700"
        >
          Cancel
        </button>

        <button
          type="button"
          phx-click="open_spawn_form"
          disabled={!match?({:ok, _}, @validation)}
          class="text-xs px-2 py-0.5 border border-emerald-500/60 text-emerald-200 hover:bg-emerald-900/40 disabled:opacity-40"
        >
          Spawn
        </button>

        <%= if @mode == :new_seed do %>
          <button
            type="button"
            phx-click="open_save_form"
            disabled={!match?({:ok, _}, @validation)}
            class="text-xs px-2 py-0.5 border border-violet-500/60 text-violet-200 hover:bg-violet-900/40 disabled:opacity-40"
          >
            Save
          </button>
        <% end %>
      </header>

      <%= if @show_spawn_form do %>
        <form
          phx-submit="submit_spawn"
          class="flex gap-2 items-center text-[11px] p-2 border-b border-emerald-500/30"
        >
          <label class="flex gap-1 items-center">
            <span class="opacity-70">count</span>
            <input type="number" name="count" value="1" min="1" max="50" class="w-16 text-xs" />
          </label>
          <label class="flex gap-1 items-center">
            <span class="opacity-70">energy</span>
            <input
              type="number"
              name="energy"
              value="10000"
              min="1"
              max="1000000"
              class="w-24 text-xs"
            />
          </label>
          <button
            type="button"
            phx-click="cancel_spawn_form"
            class="px-2 py-0.5 border border-slate-500"
          >
            Cancel
          </button>
          <button type="submit" class="px-2 py-0.5 border border-emerald-500/60 text-emerald-200">
            Spawn
          </button>
        </form>
      <% end %>

      <%= if @show_save_form do %>
        <form
          phx-submit="submit_save_seed"
          class="flex gap-2 items-center text-[11px] p-2 border-b border-violet-500/30"
        >
          <label class="flex gap-1 items-center">
            <span class="opacity-70">name</span>
            <input
              type="text"
              name="seed_name"
              required
              minlength="1"
              maxlength="40"
              placeholder="my replicator v1"
              class="text-xs"
            />
          </label>
          <label class="flex gap-1 items-center">
            <span class="opacity-70">color</span>
            <input type="color" name="color_hex" value={suggested_color(@buffer)} class="w-12 h-6" />
          </label>
          <label class="flex gap-1 items-center">
            <span class="opacity-70">energy</span>
            <input
              type="number"
              name="energy_default"
              value="10000"
              min="1"
              max="1000000"
              class="w-24 text-xs"
            />
          </label>
          <button
            type="button"
            phx-click="cancel_save_form"
            class="px-2 py-0.5 border border-slate-500"
          >
            Cancel
          </button>
          <button type="submit" class="px-2 py-0.5 border border-violet-500/60 text-violet-200">
            Save
          </button>
        </form>
      <% end %>

      <div class={["editor-grid", @manual_collapsed? && "manual-collapsed"]}>
        <.live_component
          module={LeniesWeb.ManualPaneComponent}
          id="manual-pane"
          chapter={@current_chapter}
          collapsed?={@manual_collapsed?}
        />

        <section class="codeome-palette-pane min-h-0">
          <div class="codeome-palette-pane-title">
            Opcodes — drag, dblclick, or type
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
        </section>

        <section class="codeome-listing-pane min-h-0">
          <%!-- Static energy budget for one linear pass through the buffer
                — cost is exact, max gain assumes every EAT/ATTACK hits.
                Reflects current eat_amount / attack_damage tuning at the
                time the buffer last changed. --%>
          <div class="codeome-energy-panel" id="codeome-energy-panel">
            <div class="codeome-energy-panel-head">
              <span class="codeome-energy-panel-title">Energy / pass</span>
              <span class="codeome-energy-panel-note">
                {@economics.n_eat} eat × {fmt_num(@economics.eat_amount)}
                + {@economics.n_attack} attack × {fmt_num(@economics.attack_damage)}
                · allocate sized {@economics.alloc_size}
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
          <div class="codeome-listing-pane-title">Codeome — {length(@buffer)} ops</div>
          <div
            class="codeome-blocks"
            id={"codeome-blocks-#{@mode}-#{@selected_hash || "new"}"}
            phx-hook="CodeomeSortable"
          >
            <%= for {opcode, idx} <- Enum.with_index(@buffer) do %>
              <div
                class={[
                  "codeome-block codeome-block-editable op op-" <>
                    Atom.to_string(Disassembler.opcode_class(opcode)),
                  selected?(@selection, idx) && "codeome-block-selected"
                ]}
                data-idx={idx}
              >
                <span class="codeome-drag-handle" title="Drag to reorder">≡</span>
                <span class="codeome-block-idx">
                  {String.pad_leading(Integer.to_string(idx), 3, "0")}
                </span>
                <span class="codeome-block-name">{Atom.to_string(opcode) |> String.upcase()}</span>
                <span class="codeome-block-actions">
                  <button
                    type="button"
                    phx-click="edit_delete"
                    phx-value-index={idx}
                    class="codeome-action-btn"
                    title="Delete"
                  >
                    ⨯
                  </button>
                </span>
              </div>
            <% end %>
          </div>
        </section>
      </div>
    </div>
    """
  end

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

  # New-seed mode (blank canvas) has no parent → nil. Edit mode opens
  # an existing species, so the spawned Lenies inherit that species'
  # seed_origin (looked up via the first live representative). Result:
  # the chain "Minimal Replicator → mutated species X → user edits X
  # → spawns Y" keeps Y labelled as descending from Minimal Replicator.
  defp spawn_seed_origin(%{mode: :new_seed}), do: nil

  defp spawn_seed_origin(%{mode: :edit, selected_hash: hash}) when is_binary(hash) do
    case Lenies.Species.for_hash(hash) do
      [{_id, snap} | _] -> Map.get(snap, :seed_origin)
      _ -> nil
    end
  end

  defp spawn_seed_origin(_), do: nil

  defp selected?(nil, _idx), do: false
  defp selected?({lo, hi}, idx), do: idx >= lo and idx <= hi

  defp apply_buffer_change(socket, new_buffer) do
    original = socket.assigns[:original_buffer] || socket.assigns.buffer
    dirty = new_buffer != original

    socket
    |> assign(:buffer, new_buffer)
    |> assign(:dirty, dirty)
    |> assign(:validation, LeniesWeb.CodeomeBuffer.validate(new_buffer))
    |> assign(:economics, current_economics(new_buffer))
  end

  # Reads `eat_amount` / `attack_damage` from Application env at the
  # moment the buffer changes so the editor reflects whatever the user
  # has set on the dashboard's Tuning Live sliders. No PubSub
  # subscription on purpose: tuning rarely shifts mid-edit, and the
  # numbers refresh on the next buffer change anyway.
  defp current_economics(buffer) do
    eat_amount = Application.get_env(:lenies, :eat_amount, 20)
    attack_damage = Application.get_env(:lenies, :attack_damage, 10)
    LeniesWeb.CodeomeBuffer.economics(buffer, eat_amount, attack_damage)
  end

  # `select_block` indices come from the editor's own JS hook (always
  # numeric), but parse defensively: unparseable input becomes -1, which
  # the handler's `index < 0` guard treats as a no-op instead of crashing.
  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> -1
    end
  end

  defp parse_clamped(str, min, max, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n |> max(min) |> min(max)
      :error -> default
    end
  end

  defp parse_clamped(_, _, _, default), do: default

  defp suggested_color(buffer) do
    buffer
    |> Lenies.Codeome.from_list()
    |> Lenies.Codeome.hash()
    |> Lenies.SpeciesColor.hex()
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

  defp format_validation_error({:too_short, opts}),
    do: "too short (#{opts[:got]} ops, min #{opts[:min]})"

  defp format_validation_error({:too_long, opts}),
    do: "too long (#{opts[:got]} ops, max #{opts[:max]})"

  defp format_validation_error({:insufficient_non_nops, opts}),
    do: "too few non-nops (#{opts[:got]}, min #{opts[:min]})"

  # Splits a free-text input on whitespace and commas, lowercases, then
  # validates each token against the known opcode set. Returns
  # `{:ok, [atom]}` if every token is a known opcode, or `{:error, [string]}`
  # listing the unknown tokens. Empty input → `{:ok, []}`.
  defp parse_opcode_text(text) when is_binary(text) do
    tokens =
      text
      |> String.downcase()
      |> String.split(~r/[\s,]+/, trim: true)

    {valid, invalid} =
      Enum.reduce(tokens, {[], []}, fn token, {valid, invalid} ->
        case to_known_opcode(token) do
          {:ok, atom} -> {[atom | valid], invalid}
          :error -> {valid, [token | invalid]}
        end
      end)

    if invalid == [] do
      {:ok, Enum.reverse(valid)}
    else
      {:error, Enum.reverse(invalid)}
    end
  end

  defp to_known_opcode(token) do
    try do
      atom = String.to_existing_atom(token)
      if Lenies.Codeome.Opcodes.known?(atom), do: {:ok, atom}, else: :error
    rescue
      ArgumentError -> :error
    end
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
