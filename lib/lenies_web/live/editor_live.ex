defmodule LeniesWeb.EditorLive do
  @moduledoc """
  Full-page codeome editor. Owns drag-drop palette + listing, plus a
  collapsible left pane that renders the Lenies Programming Manual for
  in-editor study and reference.

  Routes:
    /editor/new          — empty buffer (new seed)
    /editor/edit/:hash   — buffer pre-loaded from a representative
                           Lenie of the given species hash
    /editor/seed/:seed_id — buffer pre-loaded from a builtin or custom seed
  """

  use LeniesWeb, :live_view

  alias LeniesWeb.Disassembler
  alias LeniesWeb.CodeomeBuffer
  alias LeniesWeb.EditorHistory
  alias LeniesWeb.{GenomeBuffer, GenomeCaret}

  require Logger

  @default_chapter "02-opcode-reference.md"

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_scope.user
    user_id = user.id
    world_id = Lenies.Sandboxes.world_id_for(user_id)

    :ok = Lenies.Sandboxes.attach(user_id)
    {:ok, world_handle} = Lenies.Worlds.handle(world_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "sandboxes:manager_up")
    end

    scope = socket.assigns.current_scope

    {mode, selected_hash, genome, save_prefill} =
      init_for_route(socket.assigns.live_action, params, world_id, world_handle, scope)

    socket =
      socket
      |> assign(:world_id, world_id)
      |> assign(:world_handle, world_handle)
      |> assign(:mode, mode)
      |> assign(:selected_hash, selected_hash)
      |> assign(:genome, genome)
      |> assign(:original_genome, genome)
      |> assign(:dirty, false)
      |> assign(:validation, GenomeBuffer.validate(genome))
      |> assign(:economics, current_economics(genome))
      |> assign(:jump_targets, LeniesWeb.JumpTargets.targets(GenomeBuffer.to_exec_list(genome)))
      |> assign(:show_spawn_form, false)
      |> assign(:show_save_form, false)
      |> assign(:save_form_error, nil)
      |> assign(:save_prefill, save_prefill)
      |> assign(:current_chapter, @default_chapter)
      |> assign(:manual_collapsed?, false)
      |> assign(:text_input_value, "")
      |> assign(:text_input_error, nil)
      |> assign(:clipboard, [])
      |> assign(:history, EditorHistory.new(100))
      |> assign(:snippets, Lenies.Snippets.Store.all())
      |> assign(:show_snippet_form, false)
      |> assign(:snippet_form_error, nil)
      |> assign(:editing_addr, nil)
      |> assign(:inline_edit_error, nil)
      |> assign(:right_tab, :genome)
      |> assign(:plasmid_remove_confirming, nil)
      |> put_caret(GenomeCaret.end_of(genome))

    {:ok, socket}
  end

  defp init_for_route(:new, _params, _world_id, _handle, _scope) do
    {:new_seed, nil, GenomeBuffer.new(), nil}
  end

  defp init_for_route(:edit, %{"hash" => hash}, world_id, handle, _scope) do
    {buffer, plasmid_buffers} =
      case Lenies.Species.for_hash(handle, hash) do
        [{sample_id, snap} | _] ->
          chromosome =
            case safe_get_codeome(world_id, sample_id) do
              {:ok, codeome} -> Lenies.Codeome.to_list(codeome)
              _ -> []
            end

          # The sample member's carried plasmids ride in its ETS snapshot as
          # `%Lenies.Plasmid{}` structs; load them so the panel shows the whole
          # organism the species-table badge advertises ("+ N plasmids").
          plasmids = snap |> Map.get(:plasmids, []) |> Enum.map(& &1.opcodes)
          {chromosome, plasmids}

        [] ->
          {[], []}
      end

    {:edit, hash, GenomeBuffer.new(buffer, plasmid_buffers), nil}
  end

  # Custom seed: "custom:<id>" — scoped to the current user.
  defp init_for_route(:seed, %{"seed_id" => "custom:" <> id}, _world_id, _handle, scope) do
    case Lenies.Collection.get_codeome(scope.user, id) do
      %Lenies.Collection.Codeome{} = entry ->
        genome =
          GenomeBuffer.new(
            Lenies.Collection.to_opcode_atoms(entry),
            Lenies.Collection.to_plasmid_structs(entry) |> Enum.map(& &1.opcodes)
          )

        # Loading one of your saved codeomes pre-fills the save form so the
        # edit -> save (overwrite) loop doesn't ask you to retype anything.
        prefill = %{
          name: entry.name,
          color_hex: entry.color_hex,
          energy_default: trunc(entry.energy_default)
        }

        {:new_seed, nil, genome, prefill}

      _ ->
        {:new_seed, nil, GenomeBuffer.new(), nil}
    end
  end

  # Builtin seed by id atom.
  defp init_for_route(:seed, %{"seed_id" => sid}, _world_id, _handle, _scope) do
    genome =
      case safe_seed_atom(sid) do
        nil ->
          GenomeBuffer.new()

        atom ->
          case Lenies.Seeds.get(atom) do
            %{codeome: codeome} = seed ->
              plasmids =
                case Map.get(seed, :plasmid) do
                  nil -> []
                  ops -> [ops]
                end

              GenomeBuffer.new(Lenies.Codeome.to_list(codeome), plasmids)

            _ ->
              GenomeBuffer.new()
          end
      end

    {:new_seed, nil, genome, nil}
  end

  # Resolve a seed-id string to its atom. We match against the ids returned by
  # `Lenies.Seeds.all/0` rather than `String.to_existing_atom/1`: on a cold VM
  # the built-in codeome modules (and thus their id atoms) may not be loaded
  # yet, which would make a first-open of a built-in seed spuriously resolve to
  # nil. Walking `Seeds.all/0` loads them and guarantees the atom exists.
  defp safe_seed_atom(sid) do
    Enum.find_value(Lenies.Seeds.all(), fn %{id: id} ->
      if Atom.to_string(id) == sid, do: id
    end)
  end

  defp safe_get_codeome(world_id, id) do
    case Registry.lookup(Lenies.Registry, {:lenie, world_id, id}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :get_codeome, 1_000)
        catch
          :exit, _ -> {:error, :dead}
        end

      [] ->
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

  def handle_event("edit_delete", %{"section" => sec, "index" => index}, socket) do
    section = decode_section(sec)
    idx = to_int(index)

    new_genome =
      GenomeBuffer.update_section(socket.assigns.genome, section, &CodeomeBuffer.delete(&1, idx))

    {:noreply,
     socket
     |> put_caret(GenomeCaret.place(section, max(idx, 0)))
     |> commit_genome_change(new_genome)}
  end

  def handle_event("edit_reorder", %{"section" => sec, "from" => from, "to" => to}, socket) do
    section = decode_section(sec)

    new_genome =
      GenomeBuffer.update_section(
        socket.assigns.genome,
        section,
        &CodeomeBuffer.move(&1, to_int(from), to_int(to))
      )

    {:noreply,
     socket
     |> put_caret(
       GenomeCaret.place(
         section,
         min(to_int(to) + 1, length(GenomeBuffer.get_section(new_genome, section) || []))
       )
     )
     |> commit_genome_change(new_genome)}
  end

  def handle_event(
        "edit_insert",
        %{"section" => sec, "index" => index, "opcode" => opcode_str},
        socket
      )
      when is_binary(opcode_str) do
    section = decode_section(sec)

    case to_known_opcode(String.downcase(opcode_str)) do
      {:ok, opcode} ->
        socket = put_caret(socket, GenomeCaret.place(section, to_int(index)))
        {:noreply, insert_at_caret(socket, [opcode])}

      :error ->
        {:noreply, socket}
    end
  end

  # Palette double-click: append at the caret, wherever it lives.
  def handle_event("edit_insert_at_caret", %{"opcode" => opcode_str}, socket) do
    case to_known_opcode(String.downcase(to_string(opcode_str))) do
      {:ok, opcode} -> {:noreply, insert_at_caret(socket, [opcode])}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("open_spawn_form", _params, socket) do
    {:noreply, assign(socket, show_spawn_form: true, show_save_form: false)}
  end

  def handle_event("cancel_spawn_form", _params, socket) do
    {:noreply, assign(socket, :show_spawn_form, false)}
  end

  def handle_event("submit_spawn", _params, socket) do
    # Single Lenie per click (UX simplification matching the controls panel
    # cleanup in sandbox-resource-protection). Energy is the project default
    # 500.0 — the form no longer collects count or energy.
    case socket.assigns.validation do
      {:ok, _} ->
        codeome = LeniesWeb.CodeomeBuffer.to_codeome(socket.assigns.genome.chromosome)
        seed_origin = spawn_seed_origin(socket.assigns)

        Lenies.Worlds.spawn_lenie(socket.assigns.world_id, codeome,
          energy: 500.0,
          dir: Enum.random([:n, :s, :e, :w]),
          seed_origin: seed_origin
        )

        {:noreply, push_navigate(socket, to: ~p"/sandbox")}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("open_save_form", _params, socket) do
    {:noreply, assign(socket, show_save_form: true, show_spawn_form: false, save_form_error: nil)}
  end

  def handle_event("cancel_save_form", _params, socket) do
    {:noreply, assign(socket, show_save_form: false, save_form_error: nil)}
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
          opcodes: Enum.map(socket.assigns.genome.chromosome, &Atom.to_string/1),
          plasmids:
            socket.assigns.genome.plasmids
            |> Enum.reject(&(&1 == []))
            |> Enum.map(fn ops -> %{opcodes: Enum.map(ops, &Atom.to_string/1)} end)
        }

        case Lenies.Collection.create_codeome(socket.assigns.current_scope.user, attrs) do
          {:ok, _codeome} ->
            Phoenix.LiveView.send_update(LeniesWeb.ControlsPanelComponent,
              id: "controls",
              refresh_custom_seeds: true
            )

            {:noreply, push_navigate(socket, to: ~p"/sandbox")}

          {:error, :name_taken} ->
            # Fork-only flow: refuse to silently overwrite a prior save.
            # Keep the form open with an inline error so the user can pick
            # a fresh name without re-typing their colour/energy.
            {:noreply,
             assign(
               socket,
               :save_form_error,
               "A codeome named “#{name}” is already taken — pick another name."
             )}

          {:error, %Ecto.Changeset{}} ->
            {:noreply,
             assign(
               socket,
               :save_form_error,
               "Invalid codeome — check the name, colour, and opcodes."
             )}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sandbox")}
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

  def handle_event("place_caret", %{"section" => sec, "gap" => gap} = params, socket) do
    section = decode_section(sec)
    len = length(GenomeBuffer.get_section(socket.assigns.genome, section) || [])
    gap = to_int(gap) |> max(0) |> min(len)

    new_pair =
      if params["shift"] in [true, "true"] do
        GenomeCaret.extend_to_gap(caret_pair(socket), section, gap)
      else
        GenomeCaret.place(section, gap)
      end

    {:noreply, put_caret(socket, new_pair)}
  end

  def handle_event("select_block", %{"section" => sec, "index" => index} = params, socket) do
    section = decode_section(sec)
    idx = to_int(index)
    buf = GenomeBuffer.get_section(socket.assigns.genome, section) || []

    if idx < 0 or idx >= length(buf) do
      {:noreply, socket}
    else
      new_pair =
        if params["shift"] in [true, "true"] do
          GenomeCaret.extend_to_block(caret_pair(socket), section, idx)
        else
          GenomeCaret.select_block(section, idx)
        end

      {:noreply, put_caret(socket, new_pair)}
    end
  end

  def handle_event("move_caret", %{"dir" => dir} = params, socket) do
    d = if dir == "up", do: :up, else: :down

    new_pair =
      if params["extend"] in [true, "true"] do
        GenomeCaret.extend(caret_pair(socket), d, socket.assigns.genome)
      else
        GenomeCaret.move(caret_pair(socket), d, socket.assigns.genome)
      end

    {:noreply, put_caret(socket, new_pair)}
  end

  def handle_event("move_caret_end", %{"to" => to}, socket) do
    pair =
      if to == "start",
        do: GenomeCaret.place(:chromosome, 0),
        else: GenomeCaret.end_of(socket.assigns.genome)

    {:noreply, put_caret(socket, pair)}
  end

  def handle_event("clear_selection", _params, socket) do
    {section, gap} = socket.assigns.caret
    {:noreply, put_caret(socket, GenomeCaret.place(section, gap))}
  end

  def handle_event("copy_selection", _params, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      {section, range} ->
        buf = GenomeBuffer.get_section(socket.assigns.genome, section)
        {:noreply, assign(socket, :clipboard, CodeomeBuffer.slice(buf, range))}
    end
  end

  def handle_event("cut_selection", _params, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      {section, range} ->
        buf = GenomeBuffer.get_section(socket.assigns.genome, section)
        clip = CodeomeBuffer.slice(buf, range)

        new_genome =
          GenomeBuffer.update_section(
            socket.assigns.genome,
            section,
            &CodeomeBuffer.delete_range(&1, range)
          )

        {:noreply,
         socket
         |> assign(:clipboard, clip)
         |> put_caret(GenomeCaret.after_delete_range(section, range))
         |> commit_genome_change(new_genome)}
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

      {section, {_lo, hi} = range} ->
        buf = GenomeBuffer.get_section(socket.assigns.genome, section)
        clip = CodeomeBuffer.slice(buf, range)
        at = hi + 1

        new_genome =
          GenomeBuffer.update_section(
            socket.assigns.genome,
            section,
            &CodeomeBuffer.insert_many(&1, at, clip)
          )

        {:noreply,
         socket
         |> put_caret(GenomeCaret.select_inserted(section, at, length(clip)))
         |> commit_genome_change(new_genome)}
    end
  end

  def handle_event("delete_selection", _params, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      {section, range} ->
        new_genome =
          GenomeBuffer.update_section(
            socket.assigns.genome,
            section,
            &CodeomeBuffer.delete_range(&1, range)
          )

        {:noreply,
         socket
         |> put_caret(GenomeCaret.after_delete_range(section, range))
         |> commit_genome_change(new_genome)}
    end
  end

  def handle_event("move_range", %{"section" => sec, "to" => to}, socket) do
    with {section, {lo, hi} = range} <- current_range(socket),
         true <- decode_section(sec) == section do
      buf = GenomeBuffer.get_section(socket.assigns.genome, section)
      to_gap = to_int(to) |> max(0) |> min(length(buf))

      new_genome =
        GenomeBuffer.update_section(
          socket.assigns.genome,
          section,
          &CodeomeBuffer.move_range(&1, range, to_gap)
        )

      n = hi - lo + 1
      new_lo = if to_gap <= lo, do: to_gap, else: to_gap - n
      new_lo = if to_gap > lo and to_gap <= hi + 1, do: lo, else: new_lo

      {:noreply,
       socket
       |> put_caret(GenomeCaret.select_inserted(section, new_lo, n))
       |> commit_genome_change(new_genome)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("move_range_step", %{"dir" => dir}, socket) do
    case current_range(socket) do
      nil ->
        {:noreply, socket}

      {section, {lo, hi} = range} ->
        buf = GenomeBuffer.get_section(socket.assigns.genome, section)
        len = length(buf)
        to_gap = if dir == "up", do: max(lo - 1, 0), else: min(hi + 2, len)

        if (dir == "up" and lo == 0) or (dir == "down" and hi + 1 >= len) do
          {:noreply, socket}
        else
          new_genome =
            GenomeBuffer.update_section(
              socket.assigns.genome,
              section,
              &CodeomeBuffer.move_range(&1, range, to_gap)
            )

          n = hi - lo + 1
          new_lo = if dir == "up", do: lo - 1, else: lo + 1

          {:noreply,
           socket
           |> put_caret(GenomeCaret.select_inserted(section, new_lo, n))
           |> commit_genome_change(new_genome)}
        end
    end
  end

  def handle_event("undo", _params, socket) do
    case EditorHistory.undo(socket.assigns.history, socket.assigns.genome) do
      :none ->
        {:noreply, socket}

      {prev_genome, history} ->
        {:noreply,
         socket
         |> assign(:history, history)
         |> apply_genome_change(prev_genome)}
    end
  end

  def handle_event("redo", _params, socket) do
    case EditorHistory.redo(socket.assigns.history, socket.assigns.genome) do
      :none ->
        {:noreply, socket}

      {next_genome, history} ->
        {:noreply,
         socket
         |> assign(:history, history)
         |> apply_genome_change(next_genome)}
    end
  end

  def handle_event("open_snippet_form", _params, socket) do
    {:noreply, assign(socket, show_snippet_form: true, snippet_form_error: nil)}
  end

  def handle_event("cancel_snippet_form", _params, socket) do
    {:noreply, assign(socket, show_snippet_form: false, snippet_form_error: nil)}
  end

  def handle_event("submit_snippet", %{"snippet_name" => name}, socket) do
    with {section, range} <- current_range(socket),
         buf <- GenomeBuffer.get_section(socket.assigns.genome, section),
         opcodes <- CodeomeBuffer.slice(buf, range),
         id <- Lenies.Slug.slugify(name),
         :ok <- Lenies.Snippets.Store.save(%{id: id, name: name, opcodes: opcodes}) do
      {:noreply,
       socket
       |> assign(:snippets, Lenies.Snippets.Store.all())
       |> assign(:show_snippet_form, false)
       |> assign(:snippet_form_error, nil)}
    else
      # No range selected (caret == anchor, or no anchor set). Keep the form
      # open with an inline message so the user knows what's missing — the
      # previous "silently close" behaviour was indistinguishable from a
      # successful save UI-wise.
      nil ->
        {:noreply,
         assign(
           socket,
           :snippet_form_error,
           "Select a range of opcodes in the buffer first, then click ✓."
         )}

      # Store rejected the save: surface the specific reason so the user
      # can act on it (the previous silent {:noreply, socket} gave zero
      # feedback — exactly the bug we're fixing here).
      {:error, reason} ->
        Logger.warning("submit_snippet rejected by Store.save: #{inspect(reason)}")

        msg =
          case reason do
            :invalid_name ->
              "Snippet name must contain at least one letter or digit."

            :invalid_opcodes ->
              "Selected range has no valid opcodes — pick a non-empty range of real opcodes."

            :io_error ->
              "Failed to write snippet to disk — check the server log."

            other ->
              "Couldn't save snippet (#{inspect(other)})."
          end

        {:noreply, assign(socket, :snippet_form_error, msg)}
    end
  end

  def handle_event("insert_snippet", %{"id" => id}, socket) do
    case Lenies.Snippets.Store.get(id) do
      %{opcodes: ops} when ops != [] -> {:noreply, insert_at_caret(socket, ops)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("insert_snippet_at", %{"id" => id, "section" => sec, "index" => index}, socket) do
    section = decode_section(sec)
    len = length(GenomeBuffer.get_section(socket.assigns.genome, section) || [])
    at = to_int(index) |> max(0) |> min(len)

    case Lenies.Snippets.Store.get(id) do
      %{opcodes: ops} when ops != [] ->
        socket = put_caret(socket, GenomeCaret.place(section, at))
        {:noreply, insert_at_caret(socket, ops)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_snippet", %{"id" => id}, socket) do
    Lenies.Snippets.Store.delete(id)
    {:noreply, assign(socket, :snippets, Lenies.Snippets.Store.all())}
  end

  def handle_event(
        "submit_replace",
        %{"section" => sec, "index" => index, "opcode" => opcode_str},
        socket
      ) do
    section = decode_section(sec)
    idx = to_int(index)
    buf = GenomeBuffer.get_section(socket.assigns.genome, section) || []

    cond do
      idx < 0 or idx >= length(buf) ->
        {:noreply, assign(socket, editing_addr: nil, inline_edit_error: nil)}

      true ->
        case to_known_opcode(String.downcase(to_string(opcode_str))) do
          {:ok, opcode} ->
            new_genome =
              GenomeBuffer.update_section(
                socket.assigns.genome,
                section,
                &CodeomeBuffer.replace(&1, idx, opcode)
              )

            {:noreply,
             socket
             |> assign(editing_addr: nil, inline_edit_error: nil)
             |> commit_genome_change(new_genome)}

          :error ->
            {:noreply,
             assign(socket, editing_addr: {section, idx}, inline_edit_error: "unknown opcode")}
        end
    end
  end

  def handle_event("start_inline_edit", %{"section" => sec, "index" => index}, socket) do
    {:noreply,
     assign(socket, editing_addr: {decode_section(sec), to_int(index)}, inline_edit_error: nil)}
  end

  def handle_event("cancel_inline_edit", _params, socket) do
    {:noreply, assign(socket, editing_addr: nil, inline_edit_error: nil)}
  end

  def handle_event("jump_to_flat", %{"flat" => flat}, socket) do
    case GenomeBuffer.section_at(socket.assigns.genome, to_int(flat)) do
      nil -> {:noreply, socket}
      {section, idx} -> {:noreply, put_caret(socket, GenomeCaret.place(section, idx))}
    end
  end

  def handle_event("add_plasmid", _params, socket) do
    new_genome = GenomeBuffer.add_plasmid(socket.assigns.genome)
    new_section = {:plasmid, GenomeBuffer.plasmid_count(new_genome) - 1}

    {:noreply,
     socket
     |> assign(:plasmid_remove_confirming, nil)
     |> put_caret(GenomeCaret.place(new_section, 0))
     |> commit_genome_change(new_genome)}
  end

  def handle_event("plasmid_remove_init", %{"index" => index}, socket) do
    idx = to_int(index)

    if idx >= 0 and idx < GenomeBuffer.plasmid_count(socket.assigns.genome) do
      {:noreply, assign(socket, :plasmid_remove_confirming, idx)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("plasmid_remove_cancel", _params, socket) do
    {:noreply, assign(socket, :plasmid_remove_confirming, nil)}
  end

  def handle_event("plasmid_remove_confirm", _params, socket) do
    case socket.assigns.plasmid_remove_confirming do
      nil ->
        {:noreply, socket}

      idx ->
        new_genome = GenomeBuffer.remove_plasmid(socket.assigns.genome, idx)

        {:noreply,
         socket
         |> assign(:plasmid_remove_confirming, nil)
         |> commit_genome_change(new_genome)}
    end
  end

  def handle_event("set_right_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :right_tab, if(tab == "debug", do: :debug, else: :genome))}
  end

  def handle_event("goto_section", %{"section" => sec}, socket) do
    section = decode_section(sec)

    case GenomeBuffer.get_section(socket.assigns.genome, section) do
      nil -> {:noreply, socket}
      _buf -> {:noreply, put_caret(socket, GenomeCaret.place(section, 0))}
    end
  end

  @impl true
  def handle_info(:sandboxes_manager_up, socket) do
    :ok = Lenies.Sandboxes.attach(socket.assigns.current_scope.user.id)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="editor-root"
      phx-hook="RememberManualState"
      class="lenies-dashboard codeome-editor-page h-full w-full overflow-hidden"
    >
      <Layouts.flash_group flash={@flash} />
      <header class="codeome-editor-page-header">
        <.link
          navigate={~p"/sandbox"}
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

        <%!-- Visible in BOTH :new_seed and :edit modes. In :edit mode it
              opens a fork-only save form (server-side uniqueness check on
              (owner, name) — see Lenies.Collection.create_codeome/2), which
              is the missing piece of the "evolve in Sandbox → save → seed
              in Arena" loop. --%>
        <button
          type="button"
          phx-click="open_save_form"
          disabled={!match?({:ok, _}, @validation)}
          class="text-xs px-2 py-0.5 border border-violet-500/60 text-violet-200 hover:bg-violet-900/40 disabled:opacity-40"
        >
          Save
        </button>
      </header>

      <%= if @show_spawn_form do %>
        <form
          phx-submit="submit_spawn"
          class="flex gap-2 items-center text-[11px] p-2 border-b border-emerald-500/30"
        >
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
          id="save-seed-form"
          phx-submit="submit_save_seed"
          class="flex flex-wrap gap-2 items-center justify-end text-[11px] p-2 border-b border-violet-500/30"
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
            <input
              type="color"
              name="color_hex"
              value={suggested_color(@genome.chromosome, @world_handle)}
              class="w-12 h-6"
            />
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
          <%= if @save_form_error do %>
            <span class="text-red-400 text-[11px] ml-2" role="alert">{@save_form_error}</span>
          <% end %>
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
          <div id="codeome-listing" class="codeome-listing-sections">
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
                      MapSet.member?(template_nops, flat) && "codeome-template-nop"
                    ]}
                    data-section={sec}
                    data-idx={idx}
                    data-flat={flat}
                  >
                    <span class="codeome-drag-handle" title="Drag to reorder">≡</span>
                    <span class="codeome-block-idx">
                      {String.pad_leading(Integer.to_string(flat), 3, "0")}
                    </span>
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
          </div>
        </section>

        <section class="codeome-plasmid-pane min-h-0">
          <div class="codeome-plasmid-chips" role="tablist">
            <button
              type="button"
              role="tab"
              aria-selected={@right_tab == :genome}
              phx-click="set_right_tab"
              phx-value-tab="genome"
              class={["codeome-tool-btn", @right_tab == :genome && "codeome-tool-btn-active"]}
            >
              Genome
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={@right_tab == :debug}
              phx-click="set_right_tab"
              phx-value-tab="debug"
              class={["codeome-tool-btn", @right_tab == :debug && "codeome-tool-btn-active"]}
            >
              Debug
            </button>
          </div>

          <%= if @right_tab == :genome do %>
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
          <% else %>
            <p class="codeome-snippets-empty">No active debug session.</p>
          <% end %>
        </section>
      </div>
    </div>
    """
  end

  defp caret_pair(socket), do: {socket.assigns.caret, socket.assigns.anchor}

  defp put_caret(socket, {caret, anchor}), do: assign(socket, caret: caret, anchor: anchor)

  defp current_range(socket), do: GenomeCaret.derive_range(caret_pair(socket))

  # Param/DOM section encoding: "chromosome" | "p0", "p1", ...
  defp decode_section("chromosome"), do: :chromosome
  defp decode_section("p" <> i), do: {:plasmid, to_int(i)}
  defp decode_section(_), do: :chromosome

  defp encode_section(:chromosome), do: "chromosome"
  defp encode_section({:plasmid, i}), do: "p#{i}"

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

  # New-seed mode (blank canvas) has no parent → nil. Edit mode opens
  # an existing species, so the spawned Lenies inherit that species'
  # seed_origin (looked up via the first live representative). Result:
  # the chain "Minimal Replicator → mutated species X → user edits X
  # → spawns Y" keeps Y labelled as descending from Minimal Replicator.
  defp spawn_seed_origin(%{mode: :new_seed}), do: nil

  defp spawn_seed_origin(%{mode: :edit, selected_hash: hash, world_handle: handle})
       when is_binary(hash) do
    case Lenies.Species.for_hash(handle, hash) do
      [{_id, snap} | _] -> Map.get(snap, :seed_origin)
      _ -> nil
    end
  end

  defp spawn_seed_origin(_), do: nil

  defp selected?(nil, _section, _idx), do: false
  defp selected?({s, {lo, hi}}, section, idx), do: s == section and idx >= lo and idx <= hi

  defp caret_here?({s, gap}, section, g), do: s == section and gap == g

  defp has_selection?(nil), do: false
  defp has_selection?(_range), do: true

  defp has_clipboard?([]), do: false
  defp has_clipboard?(list) when is_list(list), do: true

  # Central genome-mutation entry point: snapshot the pre-change genome for
  # undo, then apply. Task 9 adds the hot-restart side effect inside
  # apply_genome_change — keep all mutations flowing through here.
  defp commit_genome_change(socket, new_genome) do
    history = EditorHistory.record(socket.assigns.history, socket.assigns.genome)

    socket
    |> assign(:history, history)
    |> apply_genome_change(new_genome)
  end

  defp apply_genome_change(socket, new_genome) do
    socket
    |> assign(:genome, new_genome)
    |> assign(:validation, GenomeBuffer.validate(new_genome))
    |> assign(:economics, current_economics(new_genome))
    |> assign(:jump_targets, LeniesWeb.JumpTargets.targets(GenomeBuffer.to_exec_list(new_genome)))
    |> put_caret(GenomeCaret.clamp(caret_pair(socket), new_genome))
    |> assign(:dirty, new_genome != socket.assigns.original_genome)
  end

  # Reads `eat_amount` / `attack_damage` from Application env at the
  # moment the genome changes so the editor reflects whatever the user
  # has set on the dashboard's Tuning Live sliders. No PubSub
  # subscription on purpose: tuning rarely shifts mid-edit, and the
  # numbers refresh on the next genome change anyway.
  defp current_economics(genome) do
    eat_amount = Application.get_env(:lenies, :eat_amount, 20)
    attack_damage = Application.get_env(:lenies, :attack_damage, 10)
    GenomeBuffer.economics(genome, eat_amount, attack_damage)
  end

  # Inserts `opcodes` at the caret (replace-on-insert when a selection is
  # active). The caret's section decides where the run lands.
  defp insert_at_caret(socket, opcodes) when is_list(opcodes) do
    {genome, section, at} =
      case current_range(socket) do
        nil ->
          {section, gap} = socket.assigns.caret
          {socket.assigns.genome, section, gap}

        {section, {lo, _hi} = range} ->
          {GenomeBuffer.update_section(
             socket.assigns.genome,
             section,
             &CodeomeBuffer.delete_range(&1, range)
           ), section, lo}
      end

    new_genome =
      GenomeBuffer.update_section(genome, section, &CodeomeBuffer.insert_many(&1, at, opcodes))

    socket
    |> put_caret(GenomeCaret.after_insert(section, at, length(opcodes)))
    |> commit_genome_change(new_genome)
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

  defp suggested_color(buffer, world_handle) do
    hash =
      buffer
      |> Lenies.Codeome.from_list()
      |> Lenies.Codeome.hash()

    case world_handle do
      %Lenies.WorldHandle{} = handle -> Lenies.SpeciesColor.hex(handle, hash)
      _ -> hash |> :erlang.phash2(255) |> Kernel.+(1) |> Lenies.SpeciesColor.byte_to_hex()
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

  # Plasmid IDENTITY is shown as a letter (A, B, C…) so it never reads as a
  # quantity — counts (e.g. the species-table "N plasmids" badge) stay numeric.
  # Beyond 26 plasmids (never realistic) we fall back to a 1-based number.
  defp plasmid_letter(i) when i in 0..25, do: <<?A + i>>
  defp plasmid_letter(i), do: "##{i + 1}"
end
