defmodule LeniesWeb.EditorComponents.Header do
  @moduledoc """
  Page header of the codeome editor: back link, title, validation summary,
  dirty indicator, the debug transport group (⏮ ⬅ ▶ ▶▶/⏸ ⏹ + speed slider
  + step counter), the Cancel/Spawn/Save buttons, and the dropdown forms
  that follow it (spawn form, save form, and the overwrite-confirm dialog).
  Events land on the parent LiveView (no phx-target).
  """
  use LeniesWeb, :html

  alias LeniesWeb.GenomeBuffer

  attr :mode, :atom, required: true
  attr :selected_hash, :string, default: nil
  attr :seed_name, :string, default: nil
  attr :validation, :any, required: true
  attr :dirty, :boolean, required: true
  attr :session, :any, default: nil
  attr :run_speed, :integer, required: true
  attr :show_spawn_form, :boolean, required: true
  attr :show_save_form, :boolean, required: true
  attr :save_form_error, :string, default: nil
  attr :save_confirm, :any, default: nil
  attr :save_prefill, :any, default: nil
  attr :genome, GenomeBuffer, required: true
  attr :world_handle, :any, default: nil

  def header(assigns) do
    ~H"""
    <header class="codeome-editor-page-header">
      <.link
        navigate={~p"/sandbox"}
        class="text-xs px-2 py-0.5 border border-cyan-500/40 hover:bg-cyan-500/10"
      >
        ← Back
      </.link>
      <h1 class="text-sm flex-1 min-w-0 truncate">
        <%= cond do %>
          <% @seed_name -> %>
            {@seed_name}
          <% @mode == :edit -> %>
            Edit: {String.slice(@selected_hash || "", 0..15)}…
          <% true -> %>
            New Seed
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

      <% valid? = match?({:ok, _}, @validation) %>
      <div
        class="editor-transport flex items-center gap-1"
        role="group"
        aria-label="Debug transport"
      >
        <button
          type="button"
          phx-click="stepper_reset"
          disabled={is_nil(@session)}
          class="stepper-btn"
          title="Reset (step 0)"
        >
          ⏮
        </button>
        <button
          type="button"
          phx-click="stepper_step_back"
          disabled={is_nil(@session)}
          class="stepper-btn"
          title="Step back"
        >
          ⬅
        </button>
        <button
          type="button"
          phx-click="stepper_step"
          disabled={!valid?}
          class="stepper-btn stepper-btn-primary"
          title="Step"
        >
          ▶
        </button>
        <%= if @session && @session.status == :running do %>
          <button type="button" phx-click="stepper_pause" class="stepper-btn" title="Pause">
            ⏸ Pause
          </button>
        <% else %>
          <button
            type="button"
            phx-click="stepper_run"
            disabled={!valid?}
            class="stepper-btn"
            title="Run"
          >
            ▶▶ Run
          </button>
        <% end %>
        <button
          type="button"
          phx-click="stepper_stop"
          disabled={is_nil(@session)}
          class="stepper-btn"
          title="Stop (close session)"
        >
          ⏹
        </button>
        <form phx-change="stepper_set_speed" class="stepper-speed-form">
          <label class="stepper-speed-label" for="stepper-run-speed">{@run_speed}/s</label>
          <input
            id="stepper-run-speed"
            type="range"
            name="value"
            min="1"
            max={Lenies.Stepper.world_ops_per_sec()}
            value={@run_speed}
            class="stepper-speed-slider"
          />
        </form>
        <%= if @session do %>
          <span class="stepper-step-counter">
            Step #{@session.step_count} · {status_label(@session.status)}
          </span>
        <% end %>
      </div>

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

      <%!-- Opens the save form (name/colour/energy). A name already in the
            user's collection — including the one this buffer was loaded from —
            prompts an overwrite confirm/cancel dialog; a fresh name creates a
            new entry. See Lenies.Collection.overwrite_codeome/2. --%>
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
            value={@save_prefill && @save_prefill.name}
            class="text-xs"
          />
        </label>
        <label class="flex gap-1 items-center">
          <span class="opacity-70">color</span>
          <input
            type="color"
            name="color_hex"
            value={
              (@save_prefill && @save_prefill.color_hex) ||
                suggested_color(@genome.chromosome, @world_handle)
            }
            class="w-12 h-6"
          />
        </label>
        <label class="flex gap-1 items-center">
          <span class="opacity-70">energy</span>
          <input
            type="number"
            name="energy_default"
            value={(@save_prefill && @save_prefill.energy_default) || 10_000}
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

      <%= if @save_confirm do %>
        <div
          class="flex gap-2 items-center justify-end text-[11px] p-2 border-b border-amber-500/40 bg-amber-950/30"
          role="alertdialog"
          aria-labelledby="overwrite-confirm-label"
        >
          <span id="overwrite-confirm-label" class="text-amber-200">
            Overwrite “{@save_confirm.name}”? The saved codeome will be replaced.
          </span>
          <button
            type="button"
            phx-click="confirm_overwrite"
            class="px-2 py-0.5 border border-amber-500/60 text-amber-200 hover:bg-amber-900/40"
          >
            Overwrite
          </button>
          <button
            type="button"
            phx-click="cancel_overwrite"
            class="px-2 py-0.5 border border-slate-500"
          >
            Cancel
          </button>
        </div>
      <% end %>
    <% end %>
    """
  end

  # status_label/1 lives here (its only render use is the transport step
  # counter); DebugPanel does not need it. If the Debug panel ever shows a
  # status string, duplicate this as its twin.
  defp status_label(:ready), do: "ready"
  defp status_label(:running), do: "running"
  defp status_label(:paused), do: "paused"
  defp status_label(:halted), do: "halted"
  defp status_label(:breakpoint_hit), do: "breakpoint"
  defp status_label(:safety_cap_reached), do: "safety cap"

  defp format_validation_error({:too_short, opts}),
    do: "too short (#{opts[:got]} ops, min #{opts[:min]})"

  defp format_validation_error({:too_long, opts}),
    do: "too long (#{opts[:got]} ops, max #{opts[:max]})"

  defp format_validation_error({:insufficient_non_nops, opts}),
    do: "too few non-nops (#{opts[:got]}, min #{opts[:min]})"

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
end
