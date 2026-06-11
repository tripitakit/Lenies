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

  alias LeniesWeb.CodeomeBuffer
  alias LeniesWeb.EditorComponents
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
      |> assign(:loops, LeniesWeb.JumpTargets.loops(GenomeBuffer.to_exec_list(genome)))
      |> assign(:show_spawn_form, false)
      |> assign(:show_save_form, false)
      |> assign(:save_form_error, nil)
      |> assign(:save_confirm, nil)
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
      |> assign(:session, nil)
      |> assign(:run_speed, 10)
      |> assign(:run_gen, 0)
      |> assign(:stepper_notice, nil)
      |> assign(:grid_payload_json, nil)
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
    {:noreply,
     assign(socket,
       show_save_form: true,
       show_spawn_form: false,
       save_form_error: nil,
       save_confirm: nil
     )}
  end

  def handle_event("cancel_save_form", _params, socket) do
    {:noreply, assign(socket, show_save_form: false, save_form_error: nil, save_confirm: nil)}
  end

  def handle_event(
        "submit_save_seed",
        %{"seed_name" => name, "color_hex" => color, "energy_default" => energy_str},
        socket
      ) do
    case socket.assigns.validation do
      {:ok, _} ->
        attrs = save_attrs(socket, name, color, energy_str)

        # Always-warn overwrite: any existing (owner, name) — including the
        # codeome this buffer was loaded from — must be confirmed explicitly.
        case Lenies.Collection.get_codeome_by_name(socket.assigns.current_scope.user, name) do
          nil ->
            {:noreply, do_create_seed(socket, attrs)}

          %Lenies.Collection.Codeome{} ->
            {:noreply, assign(socket, save_confirm: attrs, save_form_error: nil)}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm_overwrite", _params, socket) do
    case socket.assigns.save_confirm do
      nil ->
        {:noreply, socket}

      attrs ->
        case Lenies.Collection.overwrite_codeome(socket.assigns.current_scope.user, attrs) do
          {:ok, codeome} ->
            {:noreply, after_save(socket, codeome)}

          # Create-race (two tabs): the row appeared between dialog and
          # confirm under a changed content — fall back to the dialog again.
          {:error, :name_taken} ->
            {:noreply, assign(socket, :save_confirm, attrs)}

          {:error, %Ecto.Changeset{}} ->
            {:noreply,
             socket
             |> assign(:save_confirm, nil)
             |> assign(:save_form_error, "Invalid codeome — check the name, colour, and opcodes.")}
        end
    end
  end

  def handle_event("cancel_overwrite", _params, socket) do
    {:noreply, assign(socket, :save_confirm, nil)}
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

  ## ── Debug transport ────────────────────────────────────────────────

  def handle_event("stepper_step", _params, socket) do
    with {:ok, socket} <- ensure_session(socket) do
      {:ok, new_session} = Lenies.Stepper.step(socket.assigns.session)
      {:noreply, assign_session(socket, new_session)}
    else
      :invalid -> {:noreply, socket}
    end
  end

  def handle_event("stepper_step_back", _params, socket) do
    case socket.assigns.session do
      nil ->
        {:noreply, socket}

      session ->
        {:ok, new_session} = Lenies.Stepper.step_back(session)
        {:noreply, assign_session(socket, new_session)}
    end
  end

  def handle_event("stepper_run", _params, socket) do
    with {:ok, socket} <- ensure_session(socket) do
      gen = socket.assigns.run_gen + 1
      new_session = %{socket.assigns.session | status: :running}
      send(self(), {:stepper_tick, gen})
      {:noreply, socket |> assign(:run_gen, gen) |> assign_session(new_session)}
    else
      :invalid -> {:noreply, socket}
    end
  end

  def handle_event("stepper_pause", _params, socket) do
    case socket.assigns.session do
      nil ->
        {:noreply, socket}

      session ->
        {:noreply,
         socket
         |> assign(:run_gen, socket.assigns.run_gen + 1)
         |> assign_session(%{session | status: :paused})}
    end
  end

  def handle_event("stepper_stop", _params, socket) do
    {:noreply,
     socket
     |> assign(:run_gen, socket.assigns.run_gen + 1)
     |> assign(:session, nil)
     |> assign(:stepper_notice, nil)
     |> assign(:grid_payload_json, nil)
     |> assign(:loops, [])}
  end

  def handle_event("stepper_reset", _params, socket) do
    case socket.assigns.session do
      nil ->
        {:noreply, socket}

      session ->
        {:noreply,
         socket
         |> assign(:run_gen, socket.assigns.run_gen + 1)
         |> assign_session(Lenies.Stepper.reset(session))}
    end
  end

  def handle_event("stepper_toggle_bp", %{"ip" => ip_str}, socket) do
    case socket.assigns.session do
      nil ->
        {:noreply, socket}

      session ->
        {:noreply,
         assign_session(socket, Lenies.Stepper.toggle_breakpoint(session, to_int(ip_str)))}
    end
  end

  def handle_event("stepper_set_speed", %{"value" => value}, socket) do
    {:noreply, assign(socket, :run_speed, max(to_int(value), 1))}
  end

  def handle_event("stepper_select_seed", %{"value" => value}, socket) do
    case socket.assigns.session do
      nil ->
        {:noreply, socket}

      session ->
        seed_id =
          case value do
            "" -> nil
            "builtin:" <> id_str -> {:builtin, safe_seed_atom(id_str)}
            "collection:" <> id -> {:collection, to_int(id)}
            _ -> nil
          end

        {:noreply, assign_session(socket, Lenies.Stepper.set_place_seed_mode(session, seed_id))}
    end
  end

  # The mini-world canvas hook lives in a phx-update="ignore" subtree and
  # pushes straight to this LiveView (it always did — the modal used to
  # forward via send_update; now we just handle it).
  def handle_event("stepper:canvas_click", %{"x" => x, "y" => y}, socket) do
    with %Lenies.Stepper{} = session <- socket.assigns.session,
         %{seed_id: seed_ref} <- session.place_seed_mode,
         seed_map when not is_nil(seed_map) <-
           resolve_seed(seed_ref, socket.assigns.current_scope.user),
         {:ok, new_session} <- Lenies.Stepper.place_seed(session, seed_map, {x, y}) do
      {:noreply, assign_session(socket, Lenies.Stepper.set_place_seed_mode(new_session, nil))}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:sandboxes_manager_up, socket) do
    :ok = Lenies.Sandboxes.attach(socket.assigns.current_scope.user.id)
    {:noreply, socket}
  end

  def handle_info({:stepper_tick, gen}, socket) do
    session = socket.assigns.session

    # Stale-generation guard: run/pause/stop/reset/hot-restart bump
    # @run_gen, so a tick from a superseded loop is dropped WITHOUT
    # rescheduling — exactly one live loop at a time (same invariant the
    # modal enforced; see the old StepperLive update/2 for the history).
    if session != nil and gen == socket.assigns.run_gen and session.status == :running do
      {:ok, new_session} = Lenies.Stepper.step(session)

      cond do
        new_session.status == :halted ->
          {:noreply, assign_session(socket, new_session)}

        MapSet.member?(new_session.breakpoints, new_session.interp.ip) ->
          {:noreply, assign_session(socket, %{new_session | status: :breakpoint_hit})}

        true ->
          running = %{new_session | status: :running}
          delay = Lenies.Stepper.delay_ms_for(socket.assigns.run_speed)
          Process.send_after(self(), {:stepper_tick, gen}, delay)
          {:noreply, assign_session(socket, running)}
      end
    else
      {:noreply, socket}
    end
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
      <EditorComponents.Header.header
        mode={@mode}
        selected_hash={@selected_hash}
        validation={@validation}
        dirty={@dirty}
        session={@session}
        run_speed={@run_speed}
        show_spawn_form={@show_spawn_form}
        show_save_form={@show_save_form}
        save_form_error={@save_form_error}
        save_confirm={@save_confirm}
        save_prefill={@save_prefill}
        genome={@genome}
        world_handle={@world_handle}
      />

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

        <EditorComponents.Palette.palette
          text_input_value={@text_input_value}
          text_input_error={@text_input_error}
          snippets={@snippets}
          show_snippet_form={@show_snippet_form}
          snippet_form_error={@snippet_form_error}
        />

        <EditorComponents.Listing.listing
          genome={@genome}
          caret={@caret}
          anchor={@anchor}
          clipboard={@clipboard}
          history={@history}
          economics={@economics}
          jump_targets={@jump_targets}
          editing_addr={@editing_addr}
          inline_edit_error={@inline_edit_error}
          session={@session}
          stepper_notice={@stepper_notice}
          loops={@loops}
        />

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
            <EditorComponents.GenomePanel.genome_panel
              genome={@genome}
              plasmid_remove_confirming={@plasmid_remove_confirming}
            />
          <% else %>
            <EditorComponents.DebugPanel.debug_panel
              session={@session}
              grid_payload_json={@grid_payload_json}
              current_user={@current_scope.user}
            />
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
    old_genome = socket.assigns.genome

    socket
    |> assign(:genome, new_genome)
    |> assign(:validation, GenomeBuffer.validate(new_genome))
    |> assign(:economics, current_economics(new_genome))
    |> assign(:jump_targets, LeniesWeb.JumpTargets.targets(GenomeBuffer.to_exec_list(new_genome)))
    |> assign(:loops, LeniesWeb.JumpTargets.loops(GenomeBuffer.to_exec_list(new_genome)))
    |> put_caret(GenomeCaret.clamp(caret_pair(socket), new_genome))
    |> assign(:dirty, new_genome != socket.assigns.original_genome)
    |> hot_restart(old_genome, new_genome)
  end

  # Spec §6.1: any genome mutation with an active session restarts it from
  # the new genome — breakpoints remapped by {section, index}, placed seeds
  # re-applied, PAUSED at step 0 (no surprise execution after an edit).
  # An edit that invalidates the genome tears the session down instead.
  defp hot_restart(%{assigns: %{session: nil}} = socket, _old, _new), do: socket

  defp hot_restart(socket, old_genome, new_genome) do
    session = socket.assigns.session
    socket = assign(socket, :run_gen, socket.assigns.run_gen + 1)

    case GenomeBuffer.validate(new_genome) do
      {:ok, _} ->
        bps = GenomeBuffer.remap_breakpoints(old_genome, new_genome, session.breakpoints)

        new_session =
          Lenies.Stepper.restart(
            session,
            LeniesWeb.CodeomeBuffer.to_codeome(new_genome.chromosome),
            plasmids: plasmid_structs(new_genome),
            breakpoints: bps
          )

        socket
        |> assign(:stepper_notice, nil)
        |> assign_session(new_session)

      {:error, _} ->
        socket
        |> assign(:session, nil)
        |> assign(:stepper_notice, :invalid_genome)
        |> assign(:grid_payload_json, nil)
        |> assign(:loops, [])
    end
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

  # ── Embedded stepper session helpers ──────────────────────────────────

  # Lazily create a session from the current genome. :invalid when the
  # genome doesn't validate (transport is disabled in the UI too — this is
  # the server-side guard).
  defp ensure_session(socket) do
    cond do
      socket.assigns.session != nil ->
        {:ok, socket}

      match?({:ok, _}, socket.assigns.validation) ->
        session =
          Lenies.Stepper.start_session(
            LeniesWeb.CodeomeBuffer.to_codeome(socket.assigns.genome.chromosome),
            plasmids: plasmid_structs(socket.assigns.genome)
          )

        {:ok,
         socket
         |> assign(:right_tab, :debug)
         |> assign(:stepper_notice, nil)
         |> assign_session(session)}

      true ->
        :invalid
    end
  end

  # Session assign + derived view data (ported from StepperLive.assign_session/2,
  # minus the plasmid-region starts: Task 9 owns the listing overlay). Loops are
  # recomputed from the executing genome so the (Task 9) gutter stays in sync.
  defp assign_session(socket, session) do
    socket
    |> assign(:session, session)
    |> assign(
      :loops,
      LeniesWeb.JumpTargets.loops(Lenies.Codeome.to_list(session.exec_codeome))
    )
    |> assign(
      :grid_payload_json,
      Jason.encode!(Lenies.Stepper.World.encode_grid_payload(session.world))
    )
  end

  # Non-empty plasmid buffers as %Lenies.Plasmid{} structs — what the
  # session carries (empty buffers contribute no exec rows, so they're
  # rejected to keep the flat exec list aligned with GenomeBuffer).
  defp plasmid_structs(%GenomeBuffer{} = g) do
    g.plasmids |> Enum.reject(&(&1 == [])) |> Enum.map(&Lenies.Plasmid.new/1)
  end

  # Ported verbatim from StepperLive (no component coupling).
  defp resolve_seed({:builtin, id}, _user) do
    case Enum.find(Lenies.Seeds.all(), &(&1.id == id)) do
      nil ->
        nil

      seed ->
        plasmids =
          case Map.get(seed, :plasmid) do
            nil -> []
            [] -> []
            ops when is_list(ops) -> [Lenies.Plasmid.new(ops)]
          end

        %{codeome: seed.codeome, plasmids: plasmids}
    end
  end

  defp resolve_seed({:collection, _id}, nil), do: nil

  defp resolve_seed({:collection, id}, user) do
    case Lenies.Collection.get_codeome(user, id) do
      nil ->
        nil

      %Lenies.Collection.Codeome{} = c ->
        opcodes = Lenies.Collection.to_opcode_atoms(c)

        %{
          codeome: Lenies.Codeome.from_list(opcodes),
          plasmids: Lenies.Collection.to_plasmid_structs(c)
        }
    end
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

  defp save_attrs(socket, name, color, energy_str) do
    %{
      name: name,
      color_hex: color,
      energy_default: parse_clamped(energy_str, 1, 1_000_000, 10_000) * 1.0,
      opcodes: Enum.map(socket.assigns.genome.chromosome, &Atom.to_string/1),
      plasmids:
        socket.assigns.genome.plasmids
        |> Enum.reject(&(&1 == []))
        |> Enum.map(fn ops -> %{opcodes: Enum.map(ops, &Atom.to_string/1)} end)
    }
  end

  defp do_create_seed(socket, attrs) do
    case Lenies.Collection.create_codeome(socket.assigns.current_scope.user, attrs) do
      {:ok, codeome} ->
        after_save(socket, codeome)

      # Race: someone (another tab) took the name after our existence check.
      # Re-route through the confirm dialog instead of erroring.
      {:error, :name_taken} ->
        assign(socket, :save_confirm, attrs)

      {:error, %Ecto.Changeset{}} ->
        assign(socket, :save_form_error, "Invalid codeome — check the name, colour, and opcodes.")
    end
  end

  # Successful save (create or overwrite): the saved record becomes the
  # buffer's origin — dirty clears, the form closes, and we STAY in the
  # editor (the edit -> debug -> save loop keeps going; only Spawn leaves).
  defp after_save(socket, codeome) do
    socket
    |> assign(:original_genome, socket.assigns.genome)
    |> assign(:dirty, false)
    |> assign(:show_save_form, false)
    |> assign(:save_form_error, nil)
    |> assign(:save_confirm, nil)
    |> assign(:stepper_notice, nil)
    |> assign(:save_prefill, %{
      name: codeome.name,
      color_hex: codeome.color_hex,
      energy_default: trunc(codeome.energy_default)
    })
    |> put_flash(:info, "Saved “#{codeome.name}” ✓")
  end

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
end
