defmodule Lenies.Snapshot do
  @moduledoc """
  Save and restore the World's ETS state to/from disk.

  Uses Erlang's built-in `:ets.tab2file/2` and `:ets.file2tab/1` for compact
  binary serialization. The 4 tables saved: `:cells`, `:lenies`, `:child_slots`,
  `:history`.

  **Limitazione**: restore reloads the ETS records but does NOT respawn Lenie
  processes. The Lenies in `:lenies` after restore are "ghost" snapshots —
  visible in the Inspector but not running.

  For a real "resume" of a simulation, one would need to also save each Lenie's
  full process state (interpreter state, call_stack) and respawn them. SP7
  ships only the data-state save/restore.
  """

  @tables [:cells, :lenies, :child_slots, :history]

  @doc """
  Save all 4 ETS tables to files under `base_dir`. Creates the directory if missing.
  Returns `:ok` or `{:error, reason}`.
  """
  def save_to_disk(base_dir) do
    case File.mkdir_p(base_dir) do
      :ok ->
        Enum.reduce_while(@tables, :ok, fn table, _acc ->
          path = Path.join(base_dir, "#{table}.tab") |> String.to_charlist()

          case :ets.tab2file(table, path) do
            :ok -> {:cont, :ok}
            error -> {:halt, {:error, {table, error}}}
          end
        end)

      error ->
        error
    end
  end

  @doc """
  Restore all 4 ETS tables from files under `base_dir`. First sterilizes the
  current World (kills all Lenie processes + clears tables), then loads.
  Returns `:ok`, `{:error, :missing_file}`, or `{:error, reason}`.
  """
  def restore_from_disk(base_dir) do
    if all_files_exist?(base_dir) do
      Lenies.World.sterilize()
      Process.sleep(50)

      Enum.reduce_while(@tables, :ok, fn table, _acc ->
        path = Path.join(base_dir, "#{table}.tab") |> String.to_charlist()

        if :ets.whereis(table) != :undefined, do: :ets.delete(table)

        case :ets.file2tab(path) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, {:error, {table, error}}}
        end
      end)
    else
      {:error, :missing_file}
    end
  end

  defp all_files_exist?(base_dir) do
    Enum.all?(@tables, fn table ->
      File.exists?(Path.join(base_dir, "#{table}.tab"))
    end)
  end
end
