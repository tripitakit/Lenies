defmodule Lenies.Snippets.Store do
  @moduledoc """
  Persistent registry of user-saved codeome snippets (reusable opcode
  fragments for the editor).

  Backed by a JSON file at `priv/user_snippets.json` (configurable via the
  `:__test_user_snippets_file__` app env key — used by tests). State lives
  in an `Agent`. Mirrors `Lenies.Seeds.CustomStore`.

  A snippet is `%{id, name, opcodes}`. `id` is the caller-supplied slug;
  `save/1` upserts by `id`. Snippets are fragments — no length validation.
  `id` is required; `all/0` returns most-recently-saved first.

  ## Concurrency and atomicity

  Saves are serialized through the Agent: the state update and the disk write
  both happen inside `Agent.get_and_update/2`, so the Agent processes one
  write at a time. This means disk and in-memory state always agree after a
  write — no two concurrent callers can interleave their writes and produce
  a file that disagrees with the Agent state.

  Trade-off: because the disk write runs in the Agent process, a `save/1` or
  `delete/1` call briefly blocks concurrent `all/0` / `get/1` reads for the
  duration of the write. Saves are user-initiated and rare, so this is
  acceptable.
  """

  use Agent, restart: :transient

  @type snippet :: %{id: String.t(), name: String.t(), opcodes: [atom()]}

  def start_link(_opts) do
    Agent.start_link(fn -> load_from_disk() end, name: __MODULE__)
  end

  @spec all() :: [snippet()]
  def all, do: Agent.get(__MODULE__, & &1)

  @spec get(String.t()) :: nil | snippet()
  def get(id) when is_binary(id) do
    Agent.get(__MODULE__, fn snips -> Enum.find(snips, &(&1.id == id)) end)
  end

  @spec save(snippet()) ::
          :ok | {:error, :invalid_name | :invalid_opcodes | :io_error}
  def save(%{} = snippet) do
    with :ok <- validate_name(snippet),
         :ok <- validate_opcodes(snippet) do
      # State update and disk write are performed together inside Agent.get_and_update/2.
      # The Agent serializes messages, so no two concurrent saves can interleave their
      # writes — disk and in-memory state always agree after the call returns.
      Agent.get_and_update(__MODULE__, fn snips ->
        ns = [snippet | Enum.reject(snips, &(&1.id == snippet.id))]
        {safe_write(ns), ns}
      end)
    end
  end

  @spec delete(String.t()) :: :ok | {:error, :io_error}
  def delete(id) when is_binary(id) do
    Agent.get_and_update(__MODULE__, fn snips ->
      ns = Enum.reject(snips, &(&1.id == id))
      {safe_write(ns), ns}
    end)
  end

  # ----- write safety -----

  # Runs inside the Agent process (called from within Agent.get_and_update/2).
  # Must rescue filesystem errors AND JSON encode errors — an unhandled raise
  # here would crash the Agent.
  defp safe_write(snips) do
    try do
      write_to_disk(snips)
      :ok
    rescue
      _e in [File.Error, Jason.EncodeError, Protocol.UndefinedError] -> {:error, :io_error}
    end
  end

  # ----- validation -----

  defp validate_name(%{name: name, id: id}) when is_binary(name) and is_binary(id) do
    cond do
      String.trim(name) == "" -> {:error, :invalid_name}
      id == "" -> {:error, :invalid_name}
      not String.match?(name, ~r/[a-zA-Z0-9]/) -> {:error, :invalid_name}
      true -> :ok
    end
  end

  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_opcodes(%{opcodes: ops}) when is_list(ops) and ops != [] do
    whitelist = MapSet.new(Lenies.Codeome.Opcodes.all())

    if Enum.all?(ops, fn op -> is_atom(op) and MapSet.member?(whitelist, op) end) do
      :ok
    else
      {:error, :invalid_opcodes}
    end
  end

  defp validate_opcodes(_), do: {:error, :invalid_opcodes}

  # ----- file I/O -----

  defp file_path do
    case Application.get_env(:lenies, :__test_user_snippets_file__) do
      path when is_binary(path) -> path
      _ -> Path.join(:code.priv_dir(:lenies), "user_snippets.json")
    end
  end

  defp load_from_disk do
    # Force-load Codeome.Opcodes so the opcode atoms (:nop_0, :eat, …)
    # are registered in the BEAM atom table before decode_snippet/1 calls
    # String.to_existing_atom/1. Without this, the supervisor may start
    # Snippets.Store before any reference to the Opcodes module loads it,
    # and decoding would raise ArgumentError and silently drop every
    # snippet in user_snippets.json.
    Code.ensure_loaded!(Lenies.Codeome.Opcodes)

    path = file_path()

    case File.read(path) do
      {:ok, contents} -> parse_contents(contents, path)
      {:error, _} -> []
    end
  end

  defp parse_contents(contents, path) do
    case Jason.decode(contents) do
      {:ok, list} when is_list(list) ->
        list |> Enum.map(&decode_snippet/1) |> Enum.filter(& &1)

      _ ->
        # Corrupt JSON. Rename for forensics and start fresh.
        File.rename(path, path <> ".bak")
        []
    end
  end

  defp decode_snippet(%{} = m) do
    try do
      ops = Enum.map(m["opcodes"] || [], &String.to_existing_atom/1)
      %{id: m["id"], name: m["name"], opcodes: ops}
    rescue
      ArgumentError ->
        require Logger

        Logger.warning(
          "Lenies.Snippets.Store: dropping snippet #{inspect(m["id"])} — unknown opcode(s)"
        )

        nil
    end
  end

  defp decode_snippet(_), do: nil

  defp write_to_disk(snips) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))

    json =
      snips
      |> Enum.map(fn s ->
        %{"id" => s.id, "name" => s.name, "opcodes" => Enum.map(s.opcodes, &Atom.to_string/1)}
      end)
      |> Jason.encode!(pretty: true)

    # Unique suffix avoids any cross-process or cross-store tmp collision
    # and prevents stale-tmp reuse even if two OS processes share the dir.
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(tmp, json)
    File.rename!(tmp, path)
  end
end
