defmodule Lenies.Snapshot do
  @moduledoc """
  Save and restore the World's ETS state to/from disk.

  Uses Erlang's built-in `:ets.tab2file/2` and `:ets.file2tab/1` for compact
  binary serialization. The 4 tables saved: `:cells`, `:lenies`, `:child_slots`,
  `:history`.

  ## Identifying a snapshot by NAME (not a path)

  Snapshots are identified by a `name` matching `~r/\A[A-Za-z0-9_-]+\z/`. The
  on-disk directory is `Path.join(root, name)` where `root` comes from
  `Application.get_env(:lenies, :snapshot_root, <tmp>/lenies-snapshots)`.
  Because the name is restricted to `[A-Za-z0-9_-]`, the resolved directory can
  never escape `root` (no `/`, `.`, `..`, or spaces are allowed), which closes
  the previous arbitrary-filesystem-write/read hole.

  ## Safety guarantees

  - **Atomic save**: each table is written to `<table>.tab.tmp` first, and only
    after ALL writes succeed are the temp files renamed onto `<table>.tab`. A
    crash mid-save therefore never leaves a half-written `.tab` set.
  - **Validate-before-destroy restore**: every `.tab` file is validated with
    `:ets.tabfile_info/1` (read-only) BEFORE the live world is touched. A
    corrupt/partial file aborts the restore with the world left intact.
  - **Ownership**: the actual table swap happens inside the `Lenies.World`
    process (via `World.restore_tables/1`), so World — not the calling LiveView
    — owns the reloaded tables.

  **Limitazione**: restore reloads the ETS records but does NOT respawn Lenie
  processes. The Lenies in `:lenies` after restore are "ghost" snapshots —
  visible in the Inspector but not running.
  """

  @tables [:cells, :lenies, :child_slots, :history]

  # \A and \z anchor to the very start/end of the string (unlike ^ and $
  # which PCRE allows to match before a trailing newline), preventing names
  # like "foo\n" from slipping through the validation.
  @name_regex ~r/\A[A-Za-z0-9_-]+\z/

  @doc "The 4 ETS tables managed by snapshots (single source of truth)."
  def tables, do: @tables

  @doc """
  Resolve the on-disk directory for a snapshot `name`, under the configured
  root. Does NOT validate the name or touch the filesystem.
  """
  def dir_for(name) do
    Path.join(snapshot_root(), name)
  end

  @doc """
  Save all 4 ETS tables to files under `root/name`. `name` must match
  `~r/\\A[A-Za-z0-9_-]+\\z/`.

  Atomic: writes each table to `<table>.tab.tmp` then renames to `<table>.tab`
  only after all temp writes succeed. Returns `:ok`, `{:error, :invalid_name}`,
  or `{:error, :io_error}` / `{:error, {table, reason}}` on failure.
  """
  def save_to_disk(name) do
    with :ok <- validate_name(name) do
      dir = dir_for(name)
      do_save(dir)
    end
  end

  @doc """
  Restore all 4 ETS tables from files under `root/name`. `name` must match
  `~r/\\A[A-Za-z0-9_-]+\\z/`.

  Order of operations (validate-before-destroy):
  1. validate name
  2. all 4 `.tab` files must exist (else `{:error, :missing_file}`)
  3. validate each file with `:ets.tabfile_info/1` — read-only, does NOT create
     a table; a bad file returns `{:error, {:corrupt, table}}` and the live
     world is left UNTOUCHED
  4. only then `World.sterilize/0` followed by `World.restore_tables/1`

  Returns `:ok`, `{:error, :invalid_name}`, `{:error, :missing_file}`, or
  `{:error, {:corrupt, table}}`.
  """
  def restore_from_disk(name) do
    with :ok <- validate_name(name),
         dir = dir_for(name),
         :ok <- ensure_all_files_exist(dir),
         :ok <- validate_all_files(dir) do
      # Sterilize FIRST as a separate GenServer.call: it terminates the old
      # Lenies, and the `:lenie_died` casts they enqueue are drained by World
      # BEFORE the subsequent `restore_tables` call is processed (FIFO mailbox).
      # This prevents stale `:lenie_died` casts from clobbering the freshly
      # restored :cells / :lenies tables.
      Lenies.World.sterilize()
      Lenies.World.restore_tables(dir)
    end
  end

  # ----- internals -----

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_regex, name), do: :ok, else: {:error, :invalid_name}
  end

  defp validate_name(_), do: {:error, :invalid_name}

  defp snapshot_root do
    Application.get_env(
      :lenies,
      :snapshot_root,
      Path.join(System.tmp_dir!(), "lenies-snapshots")
    )
  end

  defp tab_path(dir, table), do: Path.join(dir, "#{table}.tab")
  defp tmp_path(dir, table), do: tab_path(dir, table) <> ".tmp"

  defp do_save(dir) do
    File.mkdir_p!(dir)

    write_result =
      Enum.reduce_while(@tables, :ok, fn table, _acc ->
        tmp = tmp_path(dir, table) |> String.to_charlist()

        case :ets.tab2file(table, tmp) do
          :ok -> {:cont, :ok}
          error -> {:halt, {:error, {table, error}}}
        end
      end)

    case write_result do
      :ok ->
        Enum.each(@tables, fn table ->
          File.rename!(tmp_path(dir, table), tab_path(dir, table))
        end)

        :ok

      {:error, _} = err ->
        # Clean up any temp files we did write so a later restore can't be
        # confused by stragglers.
        Enum.each(@tables, fn table -> File.rm(tmp_path(dir, table)) end)
        err
    end
  rescue
    e in [File.Error, File.RenameError] ->
      _ = e
      {:error, :io_error}
  end

  defp ensure_all_files_exist(dir) do
    if Enum.all?(@tables, fn table -> File.exists?(tab_path(dir, table)) end) do
      :ok
    else
      {:error, :missing_file}
    end
  end

  # Read-only validation: :ets.tabfile_info/1 inspects the dump header WITHOUT
  # creating a table, so it is safe to run before touching the live world.
  defp validate_all_files(dir) do
    Enum.reduce_while(@tables, :ok, fn table, _acc ->
      path = tab_path(dir, table) |> String.to_charlist()

      case :ets.tabfile_info(path) do
        {:ok, _info} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, {:corrupt, table}}}
      end
    end)
  end
end
