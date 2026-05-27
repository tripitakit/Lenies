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
  alias LeniesWeb.CodeomeBuffer
  alias LeniesWeb.EditorHistory
  alias LeniesWeb.EditorCaret

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
      |> assign(:caret, length(buffer))
      |> assign(:anchor, length(buffer))
      |> assign(:clipboard, [])
      |> assign(:history, EditorHistory.new(100))
      |> assign(:snippets, Lenies.Snippets.Store.all())
      |> assign(:show_snippet_form, false)
      |> assign(:editing_index, nil)
      |> assign(:inline_edit_error, nil)
      |> assign(:jump_targets, LeniesWeb.JumpTargets.targets(buffer))

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

    {:noreply,
     socket
     |> put_caret(EditorCaret.place(length(new_buffer)))
     |> commit_buffer_change(new_buffer)}
  end

  def handle_event("edit_reorder", %{"from" => from, "to" => to}, socket) do
    new_buffer = LeniesWeb.CodeomeBuffer.move(socket.assigns.buffer, from, to)

    {:noreply,
     socket
     |> put_caret(EditorCaret.place(length(new_buffer)))
     |> commit_buffer_change(new_buffer)}
  end

  def handle_event("edit_insert", %{"index" => index, "opcode" => opcode_str}, socket)
      when is_integer(index) and is_binary(opcode_str) do
    try do
      opcode = String.to_existing_atom(opcode_str)

      if Lenies.Codeome.Opcodes.known?(opcode) do
        # `index` from a palette drop is authoritative for placement: move the
        # caret there first, then insert at the caret.
        socket = put_caret(socket, EditorCaret.place(index))
        {:noreply, insert_at_caret(socket, [opcode])}
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
        attrs = %{
          name: name,
          color_hex: color,
          energy_default: parse_clamped(energy_str, 1, 1_000_000, 10_000) * 1.0,
          opcodes: Enum.map(socket.assigns.buffer, &Atom.to_string/1)
        }

        case Lenies.Collection.create_codeome(socket.assigns.current_scope.user, attrs) do
          {:ok, _codeome} ->
            Phoenix.LiveView.send_update(LeniesWeb.ControlsPanelComponent,
              id: "controls",
              refresh_custom_seeds: true
            )

            {:noreply, push_navigate(socket, to: ~p"/")}

          {:error, %Ecto.Changeset{}} ->
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
        {:noreply,
         socket
         |> insert_at_caret(opcodes)
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
      pair = caret_pair(socket)

      new_pair =
        if shift in [true, "true"] do
          EditorCaret.extend_to_block(pair, index)
        else
          EditorCaret.select_block(index)
        end

      {:noreply, put_caret(socket, new_pair)}
    end
  end

  def handle_event("place_caret", %{"gap" => gap} = params, socket) do
    gap = to_int(gap) |> max(0) |> min(length(socket.assigns.buffer))
    shift = params["shift"]

    new_pair =
      if shift in [true, "true"] do
        EditorCaret.extend_to_gap(caret_pair(socket), gap)
      else
        EditorCaret.place(gap)
      end

    {:noreply, put_caret(socket, new_pair)}
  end

  def handle_event("move_caret", %{"dir" => dir} = params, socket) do
    len = length(socket.assigns.buffer)
    d = if dir == "up", do: :up, else: :down
    pair = caret_pair(socket)

    new_pair =
      if params["extend"] in [true, "true"] do
        EditorCaret.extend(pair, d, len)
      else
        EditorCaret.move(pair, d, len)
      end

    {:noreply, put_caret(socket, new_pair)}
  end

  def handle_event("move_caret_end", %{"to" => to}, socket) do
    gap = if to == "start", do: 0, else: length(socket.assigns.buffer)
    {:noreply, put_caret(socket, EditorCaret.place(gap))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, put_caret(socket, EditorCaret.place(socket.assigns.caret))}
  end

  def handle_event("copy_selection", _params, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      range ->
        {:noreply, assign(socket, :clipboard, CodeomeBuffer.slice(socket.assigns.buffer, range))}
    end
  end

  def handle_event("cut_selection", _params, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      range ->
        clip = CodeomeBuffer.slice(socket.assigns.buffer, range)
        new_buffer = CodeomeBuffer.delete_range(socket.assigns.buffer, range)

        {:noreply,
         socket
         |> assign(:clipboard, clip)
         |> put_caret(EditorCaret.after_delete_range(range))
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("paste_clipboard", _params, socket) do
    case socket.assigns.clipboard do
      [] -> {:noreply, socket}
      clip -> {:noreply, insert_at_caret(socket, clip)}
    end
  end

  def handle_event("duplicate_selection", _params, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      {_lo, hi} = range ->
        clip = CodeomeBuffer.slice(socket.assigns.buffer, range)
        at = hi + 1
        new_buffer = CodeomeBuffer.insert_many(socket.assigns.buffer, at, clip)
        dup = EditorCaret.select_inserted(at, length(clip))

        {:noreply,
         socket
         |> put_caret(dup)
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("delete_selection", _params, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      range ->
        new_buffer = CodeomeBuffer.delete_range(socket.assigns.buffer, range)

        {:noreply,
         socket
         |> put_caret(EditorCaret.after_delete_range(range))
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("move_range", %{"to" => to}, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      {lo, hi} = range ->
        to_gap = to_int(to) |> max(0) |> min(length(socket.assigns.buffer))
        new_buffer = CodeomeBuffer.move_range(socket.assigns.buffer, range, to_gap)
        n = hi - lo + 1
        new_lo = if to_gap <= lo, do: to_gap, else: to_gap - n
        new_lo = if to_gap > lo and to_gap <= hi + 1, do: lo, else: new_lo

        {:noreply,
         socket
         |> put_caret(EditorCaret.select_inserted(new_lo, n))
         |> commit_buffer_change(new_buffer)}
    end
  end

  def handle_event("move_range_step", %{"dir" => dir}, socket) do
    len = length(socket.assigns.buffer)

    case current_range(socket) do
      nil ->
        {:noreply, socket}

      {lo, hi} = range ->
        to_gap = if dir == "up", do: max(lo - 1, 0), else: min(hi + 2, len)

        if (dir == "up" and lo == 0) or (dir == "down" and hi + 1 >= len) do
          {:noreply, socket}
        else
          new_buffer = CodeomeBuffer.move_range(socket.assigns.buffer, range, to_gap)
          n = hi - lo + 1
          new_lo = if dir == "up", do: lo - 1, else: lo + 1

          {:noreply,
           socket
           |> put_caret(EditorCaret.select_inserted(new_lo, n))
           |> commit_buffer_change(new_buffer)}
        end
    end
  end

  def handle_event("undo", _params, socket) do
    case EditorHistory.undo(socket.assigns.history, socket.assigns.buffer) do
      :none ->
        {:noreply, socket}

      {prev_buffer, history} ->
        {:noreply,
         socket
         |> assign(:history, history)
         |> put_caret(EditorCaret.place(length(prev_buffer)))
         |> apply_buffer_change(prev_buffer)}
    end
  end

  def handle_event("redo", _params, socket) do
    case EditorHistory.redo(socket.assigns.history, socket.assigns.buffer) do
      :none ->
        {:noreply, socket}

      {next_buffer, history} ->
        {:noreply,
         socket
         |> assign(:history, history)
         |> put_caret(EditorCaret.place(length(next_buffer)))
         |> apply_buffer_change(next_buffer)}
    end
  end

  def handle_event("open_snippet_form", _params, socket) do
    {:noreply, assign(socket, show_snippet_form: true)}
  end

  def handle_event("cancel_snippet_form", _params, socket) do
    {:noreply, assign(socket, show_snippet_form: false)}
  end

  def handle_event("submit_snippet", %{"snippet_name" => name}, socket) do
    with range when not is_nil(range) <- current_range(socket),
         opcodes <- CodeomeBuffer.slice(socket.assigns.buffer, range),
         id <- Lenies.Slug.slugify(name),
         :ok <- Lenies.Snippets.Store.save(%{id: id, name: name, opcodes: opcodes}) do
      {:noreply,
       socket
       |> assign(:snippets, Lenies.Snippets.Store.all())
       |> assign(:show_snippet_form, false)}
    else
      # No selection: nothing to save, close the form.
      nil ->
        {:noreply, assign(socket, :show_snippet_form, false)}

      # Store rejected the save (e.g. empty/invalid name): keep the form open
      # so the user can correct it, mirroring submit_save_seed's error handling.
      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("insert_snippet", %{"id" => id}, socket) do
    case Lenies.Snippets.Store.get(id) do
      %{opcodes: ops} when ops != [] -> {:noreply, insert_at_caret(socket, ops)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("insert_snippet_at", %{"id" => id, "index" => index}, socket) do
    at = to_int(index) |> max(0) |> min(length(socket.assigns.buffer))

    case Lenies.Snippets.Store.get(id) do
      %{opcodes: ops} when ops != [] ->
        socket = put_caret(socket, EditorCaret.place(at))
        {:noreply, insert_at_caret(socket, ops)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_snippet", %{"id" => id}, socket) do
    Lenies.Snippets.Store.delete(id)
    {:noreply, assign(socket, :snippets, Lenies.Snippets.Store.all())}
  end

  def handle_event("submit_replace", %{"index" => index, "opcode" => opcode_str}, socket) do
    idx = to_int(index)

    cond do
      idx < 0 or idx >= length(socket.assigns.buffer) ->
        {:noreply, assign(socket, editing_index: nil, inline_edit_error: nil)}

      true ->
        case to_known_opcode(String.downcase(to_string(opcode_str))) do
          {:ok, opcode} ->
            new_buffer = CodeomeBuffer.replace(socket.assigns.buffer, idx, opcode)

            {:noreply,
             socket
             |> assign(editing_index: nil, inline_edit_error: nil)
             |> commit_buffer_change(new_buffer)}

          :error ->
            {:noreply, assign(socket, editing_index: idx, inline_edit_error: "unknown opcode")}
        end
    end
  end

  def handle_event("start_inline_edit", %{"index" => index}, socket) do
    {:noreply, assign(socket, editing_index: to_int(index), inline_edit_error: nil)}
  end

  def handle_event("cancel_inline_edit", _params, socket) do
    {:noreply, assign(socket, editing_index: nil, inline_edit_error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="editor-root"
      phx-hook="RememberManualState"
      class="lenies-dashboard codeome-editor-page h-screen w-screen overflow-hidden"
    >
      <Layouts.flash_group flash={@flash} />
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

      <div
        id="editor-grid"
        phx-hook="EditorKeyboard"
        class={["editor-grid", @manual_collapsed? && "manual-collapsed"]}
      >
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
          <% range = EditorCaret.derive_range({@caret, @anchor}) %>
          <% len = length(@buffer) %>
          <% template_nops = template_nop_indices(@buffer) %>
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
          <div class="codeome-listing-pane-title">Codeome — {len} ops</div>
          <datalist id="opcode-datalist">
            <%= for op <- Lenies.Codeome.Opcodes.all() do %>
              <option value={Atom.to_string(op)}></option>
            <% end %>
          </datalist>
          <div
            class="codeome-blocks"
            id={"codeome-blocks-#{@mode}-#{@selected_hash || "new"}"}
            phx-hook="CodeomeSortable"
          >
            <%= for {opcode, idx} <- Enum.with_index(@buffer) do %>
              <div
                class={["codeome-gap", caret_here?(@caret, idx) && "codeome-gap-caret"]}
                data-gap={idx}
                data-caret-at={(caret_here?(@caret, idx) && idx) || nil}
                phx-click="place_caret"
                phx-value-gap={idx}
              >
              </div>
              <div
                class={[
                  "codeome-block codeome-block-editable op op-" <>
                    Atom.to_string(Disassembler.opcode_class(opcode)),
                  selected?(range, idx) && "codeome-block-selected",
                  MapSet.member?(template_nops, idx) && "codeome-template-nop"
                ]}
                data-idx={idx}
              >
                <span class="codeome-drag-handle" title="Drag to reorder">≡</span>
                <span class="codeome-block-idx">
                  {String.pad_leading(Integer.to_string(idx), 3, "0")}
                </span>
                <%= if idx == @editing_index do %>
                  <form phx-submit="submit_replace" class="codeome-inline-edit">
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
                  <span class="codeome-block-name">{Atom.to_string(opcode) |> String.upcase()}</span>
                <% end %>
                <%= case Map.get(@jump_targets, idx) do %>
                  <% {:ok, target} -> %>
                    <button
                      type="button"
                      phx-click="place_caret"
                      phx-value-gap={target}
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
              class={["codeome-gap codeome-gap-end", caret_here?(@caret, len) && "codeome-gap-caret"]}
              data-gap={len}
              data-caret-at={(caret_here?(@caret, len) && len) || nil}
              phx-click="place_caret"
              phx-value-gap={len}
            >
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  defp caret_pair(socket), do: {socket.assigns.caret, socket.assigns.anchor}

  defp put_caret(socket, {c, a}), do: assign(socket, caret: c, anchor: a)

  defp current_range(socket), do: EditorCaret.derive_range(caret_pair(socket))

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

  defp caret_here?(caret, gap), do: caret == gap

  defp has_selection?(nil), do: false
  defp has_selection?({_lo, _hi}), do: true

  defp has_clipboard?([]), do: false
  defp has_clipboard?(list) when is_list(list), do: true

  # Central buffer-mutation entry point: records the pre-change buffer onto
  # the undo history (clearing redo) before applying the new buffer.
  # NOTE: history snapshots only the buffer list. If it ever expands to
  # capture selection/UI state, this must be called BEFORE any such assign
  # mutation on the socket (paste/duplicate set selection before committing).
  defp commit_buffer_change(socket, new_buffer) do
    history = EditorHistory.record(socket.assigns.history, socket.assigns.buffer)

    socket
    |> assign(:history, history)
    |> apply_buffer_change(new_buffer)
  end

  defp apply_buffer_change(socket, new_buffer) do
    original = socket.assigns[:original_buffer] || socket.assigns.buffer
    dirty = new_buffer != original

    socket
    |> assign(:buffer, new_buffer)
    |> assign(:dirty, dirty)
    |> assign(:validation, LeniesWeb.CodeomeBuffer.validate(new_buffer))
    |> assign(:economics, current_economics(new_buffer))
    |> assign(:jump_targets, LeniesWeb.JumpTargets.targets(new_buffer))
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

  # Inserts `opcodes` at the caret. If a selection is active, deletes it first
  # (replace-on-insert), then inserts at the range start, leaving a collapsed
  # caret immediately after the inserted run.
  defp insert_at_caret(socket, opcodes) when is_list(opcodes) do
    {buffer, at} =
      case current_range(socket) do
        nil ->
          {socket.assigns.buffer, socket.assigns.caret}

        {lo, _hi} = range ->
          {CodeomeBuffer.delete_range(socket.assigns.buffer, range), lo}
      end

    new_buffer = CodeomeBuffer.insert_many(buffer, at, opcodes)

    socket
    |> put_caret(EditorCaret.after_insert(at, length(opcodes)))
    |> commit_buffer_change(new_buffer)
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
