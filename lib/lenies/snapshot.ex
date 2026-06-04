defmodule Lenies.Snapshot do
  @moduledoc """
  Save and restore a World's ETS state to/from disk.

  Uses Erlang's built-in `:ets.tab2file/2` and `:ets.file2tab/1` for compact
  binary serialization. As of T12 the 5 tables saved are: `:cells`, `:lenies`,
  `:child_slots`, `:history`, `:color_overrides`. Legacy 4-table snapshots
  (created before T12) are still loadable — the missing `color_overrides.tab`
  is treated as an empty table.

  ## Per-world directory layout (T12)

  Snapshots live under `<snapshot_root>/<id_to_path(world_id)>/<name>/`,
  where `snapshot_root` comes from `Application.get_env(:lenies,
  :snapshot_root, <tmp>/lenies-snapshots)` and `id_to_path/1` renders a
  `world_id` as a filesystem-safe string (`:arena → "arena"`,
  `{:sandbox, 42} → "sandbox-42"`).

  ## Identifying a snapshot by NAME (not a path)

  Snapshots are identified by a `name` matching `~r/\A[A-Za-z0-9_-]+\z/`.
  Because the name is restricted to `[A-Za-z0-9_-]`, the resolved directory
  can never escape `snapshot_root` (no `/`, `.`, `..`, or spaces are
  allowed), which closes the previous arbitrary-filesystem-write/read hole.

  ## Safety guarantees

  - **Atomic save**: each table is written to `<table>.tab.tmp` first, and only
    after ALL writes succeed are the temp files renamed onto `<table>.tab`. A
    crash mid-save therefore never leaves a half-written `.tab` set.
  - **Validate-before-destroy restore**: every required `.tab` file is
    validated with `:ets.tabfile_info/1` (read-only) BEFORE the live world is
    touched. A corrupt/partial file aborts the restore with the world left
    intact.
  - **Same-tid restore**: the live world's tids are reused; we
    `:ets.delete_all_objects/1` then re-insert from the snapshot. This means
    a handle cached by another process stays valid across a restore.

  **Limitazione**: restore reloads the ETS records but does NOT respawn Lenie
  processes. The Lenies in `:lenies` after restore are "ghost" snapshots —
  visible in the Inspector but not running.
  """

  @required_tables [:cells, :lenies, :child_slots, :history]
  @optional_tables [:color_overrides]
  @all_tables @required_tables ++ @optional_tables

  # Sidecar file with the codeome cache entries used by the snapshot's Lenies.
  # Format: Erlang term_to_binary of a list of {codeome_hash, [opcode]} tuples.
  # Filtered at save time to only hashes referenced by the world's :lenies — so
  # snapshots don't grow with cache from unrelated worlds.
  #
  # Why this file exists: `:species_codeomes` is a node-global in-memory cache
  # (see Lenies.Application). After a node restart the cache is empty, so
  # snapshots saved BEFORE the per-Lenie `:codeome` field existed would have
  # been unrecoverable. Saving the sidecar makes any post-fix snapshot
  # self-sufficient across restarts even if per-Lenie `:codeome` is ever
  # dropped from the snap shape, and pre-populates the cache so the species
  # table can compute size/cost/max_gain on the first render after restore.
  @species_codeomes_sidecar "species_codeomes.bin"

  # \A and \z anchor to the very start/end of the string (unlike ^ and $
  # which PCRE allows to match before a trailing newline), preventing names
  # like "foo\n" from slipping through the validation.
  @name_regex ~r/\A[A-Za-z0-9_-]+\z/

  @doc "The full list of snapshot-tracked tables (required ++ optional)."
  def tables, do: @all_tables

  @doc """
  Save all 5 ETS tables of `handle` to `<snapshot_root>/<id_to_path(id)>/<name>/`.

  `name` must match `~r/\\A[A-Za-z0-9_-]+\\z/`.

  Atomic: writes each table to `<table>.tab.tmp` then renames to `<table>.tab`
  only after all temp writes succeed. Returns `:ok`, `{:error, :invalid_name}`,
  or `{:error, {table, reason}}` / `{:error, :io_error}` on failure.
  """
  @spec save(Lenies.WorldHandle.t(), String.t()) ::
          :ok | {:error, :invalid_name | :io_error | {atom(), term()}}
  def save(%Lenies.WorldHandle{} = handle, name) do
    with :ok <- validate_name(name) do
      dir = snapshot_dir(handle.id, name)
      do_save(handle, dir)
    end
  end

  @doc """
  Restore the snapshot named `name` for `handle` from
  `<snapshot_root>/<id_to_path(id)>/<name>/`.

  Order of operations (validate-before-destroy):
  1. validate `name`
  2. all REQUIRED `.tab` files (cells, lenies, child_slots, history) must
     exist (else `{:error, :missing_file}`)
  3. validate each REQUIRED file with `:ets.tabfile_info/1` — read-only,
     does NOT create a table; a bad file returns `{:error, {:corrupt, table}}`
     and the live world is left UNTOUCHED
  4. only then `:ets.delete_all_objects/1` + reload each required table into
     the EXISTING tid via `:ets.file2tab/1` + foldl/insert
  5. OPTIONAL tables (currently `:color_overrides`) — if the `.tab` file
     exists, load it; otherwise wipe the live table empty (legacy snapshot
     tolerance)

  Returns `:ok`, `{:error, :invalid_name}`, `{:error, :missing_file}`,
  `{:error, {:corrupt, table}}`, or `{:error, {:restore_failed, table}}`.
  """
  @spec restore(Lenies.WorldHandle.t(), String.t()) :: :ok | {:error, term()}
  def restore(%Lenies.WorldHandle{} = handle, name) do
    with :ok <- validate(handle.id, name) do
      load_validated(handle, name)
    end
  end

  @doc """
  Read-only pre-check: confirms the snapshot named `name` is loadable for the
  given `world_id` WITHOUT touching any live ETS table.

  Returns `:ok`, `{:error, :invalid_name}`, `{:error, :missing_file}`, or
  `{:error, {:corrupt, table}}`.

  Used by `Lenies.World` so it can sterilize the world ONLY after the
  snapshot has been validated — preserving the C2 (validate-before-destroy)
  invariant even though the actual load runs after a sterilize.
  """
  @spec validate(term(), String.t()) ::
          :ok | {:error, :invalid_name | :missing_file | {:corrupt, atom()}}
  def validate(world_id, name) do
    with :ok <- validate_name(name) do
      dir = snapshot_dir(world_id, name)

      with :ok <- ensure_required_files_exist(dir) do
        validate_required_files(dir)
      end
    end
  end

  @doc """
  Load a pre-validated snapshot named `name` into `handle`'s live tables.

  Skips the read-only validation that `restore/2` does — intended for callers
  that already ran `validate/2`. Returns `:ok` or
  `{:error, {:restore_failed, table}}` if a file2tab call fails despite the
  header passing validation.
  """
  @spec load_validated(Lenies.WorldHandle.t(), String.t()) ::
          :ok | {:error, {:restore_failed, atom()}}
  def load_validated(%Lenies.WorldHandle{} = handle, name) do
    dir = snapshot_dir(handle.id, name)

    with :ok <- restore_required(handle, dir) do
      result = restore_optional(handle, dir)
      # Pre-populate the node-global :species_codeomes cache from the
      # sidecar BEFORE the World handler kicks off respawn_lenies — so
      # the codeome fallback in World.codeome_from_snap/1 can recover
      # codeomes from the cache for snaps that don't embed :codeome.
      _ = load_species_codeomes_sidecar(dir)
      result
    end
  end

  # ----- internals -----

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_regex, name), do: :ok, else: {:error, :invalid_name}
  end

  defp validate_name(_), do: {:error, :invalid_name}

  @doc """
  The root directory under which all world snapshots are written.

  Sourced from `Application.get_env(:lenies, :snapshot_root, ...)`; defaults to
  `Path.join(System.tmp_dir!(), "lenies-snapshots")` when no config is set.

  This is the single source of truth for snapshot path resolution. Callers
  that need to inspect snapshot paths (e.g. `Lenies.Sandboxes` for quarantine
  logic) MUST go through this function rather than re-deriving the default,
  so the default stays consistent across the codebase.
  """
  @spec snapshot_root() :: Path.t()
  def snapshot_root do
    Application.get_env(
      :lenies,
      :snapshot_root,
      Path.join(System.tmp_dir!(), "lenies-snapshots")
    )
  end

  # File at the snapshot root recording the grid dimensions the snapshots were
  # written with. Hidden (leading dot) and not a world dir, so the per-world
  # path helpers never collide with it.
  @grid_marker ".grid_dims"

  @doc """
  Wipe ALL snapshots when the world grid dimensions have changed.

  Snapshots are raw cell dumps keyed by `{x, y}`; restoring a dump from a
  different grid into the current world leaves off-grid cells and Lenies at
  coordinates outside the new bounds. Rather than partially restore an
  incompatible snapshot, we drop the whole store and let worlds cold-start
  fresh at the new size.

  Idempotent: a marker at the snapshot root records the current dimensions, so
  this only wipes when they actually differ (e.g. a one-off grid change). Run
  once at application start, before any world can restore.
  """
  @spec wipe_if_grid_changed() :: :ok
  def wipe_if_grid_changed do
    {w, h} = Lenies.Config.grid_size()
    current = "#{w}x#{h}"
    root = snapshot_root()
    marker = Path.join(root, @grid_marker)

    stored =
      case File.read(marker) do
        {:ok, content} -> String.trim(content)
        {:error, _} -> nil
      end

    if stored == current do
      :ok
    else
      if File.dir?(root) do
        require Logger

        Logger.info(
          "Lenies.Snapshot: grid changed (#{stored || "unknown"} -> #{current}); wiping #{root}"
        )

        File.rm_rf!(root)
      end

      File.mkdir_p!(root)
      File.write!(marker, current)
      :ok
    end
  rescue
    e ->
      require Logger
      Logger.error("Lenies.Snapshot.wipe_if_grid_changed failed: #{inspect(e)}")
      :ok
  end

  defp snapshot_dir(world_id, name) do
    Path.join([snapshot_root(), Lenies.Worlds.id_to_path(world_id), name])
  end

  defp tab_path(dir, table), do: Path.join(dir, "#{table}.tab")
  defp tmp_path(dir, table), do: tab_path(dir, table) <> ".tmp"

  defp do_save(handle, dir) do
    File.mkdir_p!(dir)

    write_result =
      Enum.reduce_while(@all_tables, :ok, fn table, _acc ->
        tmp = tmp_path(dir, table) |> String.to_charlist()
        tid = Map.fetch!(handle.tables, table)

        case :ets.tab2file(tid, tmp) do
          :ok -> {:cont, :ok}
          error -> {:halt, {:error, {table, error}}}
        end
      end)

    case write_result do
      :ok ->
        Enum.each(@all_tables, fn table ->
          File.rename!(tmp_path(dir, table), tab_path(dir, table))
        end)

        # Best-effort sidecar: failure to write the codeome cache is not
        # fatal — restore still works as long as per-Lenie `:codeome` is
        # embedded in the snap (which Lenie.maybe_write_snapshot/1 does
        # since 2026-06-01) OR the cache is otherwise populated.
        _ = save_species_codeomes_sidecar(handle, dir)

        :ok

      {:error, _} = err ->
        # Clean up any temp files we did write so a later restore can't be
        # confused by stragglers.
        Enum.each(@all_tables, fn table -> File.rm(tmp_path(dir, table)) end)
        err
    end
  rescue
    e in [File.Error, File.RenameError] ->
      _ = e
      {:error, :io_error}
  end

  defp save_species_codeomes_sidecar(handle, dir) do
    if :ets.info(:species_codeomes) != :undefined do
      hashes =
        handle.tables.lenies
        |> :ets.tab2list()
        |> Enum.flat_map(fn {_id, snap} ->
          case Map.get(snap, :codeome_hash) do
            hash when is_binary(hash) -> [hash]
            _ -> []
          end
        end)
        |> Enum.uniq()

      entries =
        Enum.flat_map(hashes, fn hash ->
          case :ets.lookup(:species_codeomes, hash) do
            [{^hash, opcodes}] when is_list(opcodes) -> [{hash, opcodes}]
            _ -> []
          end
        end)

      path = Path.join(dir, @species_codeomes_sidecar)
      tmp = path <> ".tmp"
      File.write!(tmp, :erlang.term_to_binary(entries))
      File.rename!(tmp, path)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp ensure_required_files_exist(dir) do
    if Enum.all?(@required_tables, fn table -> File.exists?(tab_path(dir, table)) end) do
      :ok
    else
      {:error, :missing_file}
    end
  end

  # Read-only validation: :ets.tabfile_info/1 inspects the dump header WITHOUT
  # creating a table, so it is safe to run before touching the live world.
  defp validate_required_files(dir) do
    Enum.reduce_while(@required_tables, :ok, fn table, _acc ->
      path = tab_path(dir, table) |> String.to_charlist()

      case :ets.tabfile_info(path) do
        {:ok, _info} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, {:corrupt, table}}}
      end
    end)
  end

  defp restore_required(handle, dir) do
    Enum.reduce_while(@required_tables, :ok, fn table, _acc ->
      case load_one(handle, dir, table) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, {:restore_failed, table}}}
      end
    end)
  end

  defp restore_optional(handle, dir) do
    Enum.each(@optional_tables, fn table ->
      path = tab_path(dir, table)

      if File.exists?(path) do
        _ = load_one(handle, dir, table)
      else
        # Legacy snapshot without this table → wipe the live table empty so
        # restoring an old snapshot is deterministic (no overrides from a
        # previous session leak through).
        target = Map.fetch!(handle.tables, table)

        try do
          :ets.delete_all_objects(target)
        rescue
          ArgumentError -> :ok
        end
      end
    end)

    :ok
  end

  defp load_species_codeomes_sidecar(dir) do
    path = Path.join(dir, @species_codeomes_sidecar)

    if File.exists?(path) and :ets.info(:species_codeomes) != :undefined do
      case File.read(path) do
        {:ok, content} ->
          # `:safe` mode rejects unknown atoms — but opcodes are atoms
          # already loaded in this BEAM (defined as enum in Disassembler),
          # so this is fine. Any decoding error from a truncated/malformed
          # sidecar is caught by the rescue below and the load proceeds
          # without cache pre-population (best-effort behaviour).
          try do
            term = :erlang.binary_to_term(content, [:safe])

            if is_list(term) do
              Enum.each(term, fn
                {hash, opcodes} when is_binary(hash) and is_list(opcodes) ->
                  case :ets.lookup(:species_codeomes, hash) do
                    [] -> :ets.insert(:species_codeomes, {hash, opcodes})
                    _ -> :ok
                  end

                _ ->
                  :ok
              end)
            end
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  # Load `<table>.tab` into the EXISTING tid for `table`. Uses an interim tid
  # from :ets.file2tab/1, copies its rows over, then deletes the interim tid.
  # Preserves the original tid so a handle cached by another process stays
  # valid across a restore.
  defp load_one(handle, dir, table) do
    path = tab_path(dir, table) |> String.to_charlist()

    case :ets.file2tab(path) do
      {:ok, loaded_tid} ->
        target_tid = Map.fetch!(handle.tables, table)
        :ets.delete_all_objects(target_tid)

        :ets.foldl(
          fn obj, _ -> :ets.insert(target_tid, obj) end,
          :ok,
          loaded_tid
        )

        :ets.delete(loaded_tid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
