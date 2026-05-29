defmodule Lenies.Worlds do
  @moduledoc """
  Facade for the multi-world simulation engine. Provides the per-world API
  surface that other modules call (LiveViews, Telemetry, tests, Lenies).

  ## world_id convention

  - Fixed worlds use atoms: `:arena`, `:test_world` (one atom per id, safe).
  - Dynamic worlds use tuples with bounded atoms: `{:sandbox, user_id}` where
    `user_id` is an integer. **Never** `String.to_atom("sandbox_\#{user_id}")`
    — would re-introduce the atom-table pollution that the multi-world design
    explicitly avoids.

  ## Facade entry points

  - Lifecycle: `start_world/2`, `stop_world/1`, `handle/1`, `list/0`, `alive?/1`
  - Per-world ops: `spawn_lenie/3`, `action/2`, `sterilize/1`, `pause/1`,
    `resume/1`, `paused?/1`, `tune/3`, `snapshot_stats/1`

  All per-world ops accept either a world id (`:arena`, `{:sandbox, 1}`, ...)
  OR an already-resolved `%Lenies.WorldHandle{}` for callers that can cache
  the handle in their state.
  """

  @doc """
  Render a `world_id` as a filesystem- and topic-safe string.

  Examples:
      iex> Lenies.Worlds.id_to_path(:arena)
      "arena"
      iex> Lenies.Worlds.id_to_path({:sandbox, 42})
      "sandbox-42"
  """
  @spec id_to_path(term()) :: String.t()
  def id_to_path(id) when is_atom(id), do: Atom.to_string(id)

  def id_to_path({atom, rest}) when is_atom(atom) do
    "#{atom}-#{rest}"
  end

  @doc """
  Start a new world with the given id and optional config overrides.
  Returns `{:ok, sup_pid}` (the per-world Supervisor pid) or `{:error, …}`.

  Spawns a `Lenies.World.Supervisor` (per-world `rest_for_one` Supervisor)
  under `Lenies.Worlds.Supervisor`. The per-world Supervisor in turn brings
  up `Lenies.World`, its per-world `Lenies.LenieSupervisor`, and the
  per-world `Lenies.Telemetry` collector.
  """
  @spec start_world(term(), map()) :: DynamicSupervisor.on_start_child()
  def start_world(world_id, config_overrides \\ %{}) do
    spec = {Lenies.World.Supervisor, world_id: world_id, config: config_overrides}
    DynamicSupervisor.start_child(Lenies.Worlds.Supervisor, spec)
  end

  @doc "Stop a world by id. Idempotent — returns :ok if not found."
  @spec stop_world(term()) :: :ok
  def stop_world(world_id) do
    case Registry.lookup(Lenies.Registry, {:world_sup, world_id}) do
      [{sup_pid, _}] ->
        DynamicSupervisor.terminate_child(Lenies.Worlds.Supervisor, sup_pid)
        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Look up the %WorldHandle{} for an id. Returns `{:ok, handle}` or `:error`.

  Accepts an already-built handle (returned as-is) for callsites that can
  cache it.
  """
  @spec handle(term() | Lenies.WorldHandle.t()) :: {:ok, Lenies.WorldHandle.t()} | :error
  def handle(%Lenies.WorldHandle{} = h), do: {:ok, h}

  def handle(world_id) do
    case Registry.lookup(Lenies.Registry, {:world, world_id}) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :get_handle)}
      [] -> :error
    end
  end

  @doc "List the ids of currently running worlds."
  @spec list() :: [term()]
  def list do
    Registry.select(Lenies.Registry, [{{{:world, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc "Is a world with this id alive?"
  @spec alive?(term()) :: boolean
  def alive?(world_id) do
    match?([{_, _}], Registry.lookup(Lenies.Registry, {:world, world_id}))
  end

  # ----- delegated operations -----

  @doc "Spawn a Lenie in the target world."
  def spawn_lenie(target, codeome, opts \\ []) do
    with {:ok, h} <- handle(target) do
      GenServer.call(h.pid, {:spawn_lenie, codeome, opts})
    end
  end

  @doc "Apply an action to the target world (used by Lenies in their hot path)."
  def action(target, action_spec) do
    with {:ok, h} <- handle(target) do
      GenServer.call(h.pid, {:action, action_spec})
    end
  end

  def sterilize(target), do: call(target, :sterilize)
  def pause(target), do: call(target, :pause)
  def resume(target), do: call(target, :resume)
  def paused?(target), do: call(target, :paused?)
  def snapshot_stats(target), do: call(target, :snapshot_stats)

  @doc "Force a single synchronous tick in `target` (deterministic tests)."
  def tick_now(target), do: call(target, :tick_now)

  @doc """
  Synchronous reconciliation sweep on `target`: frees cells and deletes
  :lenies records whose Lenie is no longer alive in the Registry.

  Returns `{freed_cells, deleted_records}`. Useful for tests and diagnostics;
  the same sweep runs automatically on the `:reconcile_interval_ms` timer.
  """
  def reconcile(target), do: call(target, :reconcile)

  @doc """
  Notify `target` that a Lenie has died (frees the cell, leaves a carcass).
  Async cast — does not return when the cell mutation is observable.

  `seeder_user_id` (default `nil`) is the Arena lineage tag; when set and
  the world is `:arena`, the World handler broadcasts
  `{:arena_lineage_changed, user_id}` on the user's per-user PubSub topic.
  """
  def lenie_died(target, id, pos, energy_at_death, codeome_hash, seeder_user_id \\ nil)
      when is_binary(codeome_hash) do
    with {:ok, h} <- handle(target) do
      GenServer.cast(
        h.pid,
        {:lenie_died, id, pos, energy_at_death, codeome_hash, seeder_user_id}
      )
    end
  end

  @doc """
  Save a named snapshot of `target`'s 5 ETS tables to disk, under
  `<snapshot_root>/<id_to_path(world_id)>/<name>/`. See `Lenies.Snapshot.save/2`.

  Runs inside the target world's GenServer so World owns the file I/O —
  consistent with restore, which has to run there anyway to mutate the
  world's tids.
  """
  def save_snapshot(target, name) do
    with {:ok, h} <- handle(target) do
      GenServer.call(h.pid, {:save_snapshot, name})
    end
  end

  @doc """
  Restore the named snapshot for `target`. See `Lenies.Snapshot.restore/2`.

  Three-step protocol so the live world is never half-loaded:
    1. `Lenies.Snapshot.validate/2` — read-only check that the snapshot is
       loadable; bails out without touching the world if not.
    2. `GenServer.call(world, :sterilize)` — terminates all Lenies. Issued as
       a SEPARATE call so the resulting `:lenie_died` casts land in the
       world's mailbox BEFORE the subsequent `:restore_snapshot` call (FIFO
       mailbox). Otherwise stale casts would clobber the freshly restored
       `:cells` / `:lenies` tables.
    3. `GenServer.call(world, {:restore_snapshot, name})` — does the actual
       load via `Lenies.Snapshot.load_validated/2`.
  """
  def restore_snapshot(target, name) do
    with {:ok, h} <- handle(target),
         :ok <- Lenies.Snapshot.validate(h.id, name) do
      :ok = GenServer.call(h.pid, :sterilize)
      GenServer.call(h.pid, {:restore_snapshot, name})
    end
  end

  @doc "Set a tunable on the target world."
  def tune(target, key, value) do
    with {:ok, h} <- handle(target) do
      GenServer.call(h.pid, {:tune, key, value})
    end
  end

  defp call(target, msg) do
    with {:ok, h} <- handle(target) do
      GenServer.call(h.pid, msg)
    end
  end
end
