defmodule Lenies.Seeds.CustomStore do
  @moduledoc """
  Persistent registry of user-created seed Codeomes.

  Backed by a JSON file at `priv/user_seeds.json` (configurable via the
  `:__test_user_seeds_file__` app env key — used by tests). State lives in
  an `Agent` so reads (which happen on every dropdown render) are cheap.

  Validation rules (enforced by both `save/1` and the load path):
  - `id` must be a non-empty binary
  - `name` must be a non-empty string after trimming
  - `color_hex` must match `^#[0-9a-fA-F]{6}$`
  - `opcodes` must be a non-empty list of known opcodes from `Lenies.Codeome.Opcodes.all/0`
  - `energy_default` must be a number (integer or float); an absent key defaults to 10_000.0
  - `opcodes` length must not exceed the codeome upper bound (currently 1000)

  When loading from disk, rows that fail any of these rules are silently dropped
  with a `Logger.warning` naming the seed id and the reason. This means a
  hand-edited `priv/user_seeds.json` can never inject invalid data at runtime.

  ## File format (MH4 versioned envelope)

  The JSON file is written in a versioned envelope format:

      {"version": 1, "items": [...]}

  **Backward compatibility**: old bare-array files (`[{...}, ...]`) are still
  read correctly and upgraded to the envelope format on the next write. This
  means existing `priv/user_seeds.json` files from before this change load
  with zero data loss.

  **Unknown future versions**: if the file carries a `version` number greater
  than `@schema_version`, the store logs a warning and starts fresh. This
  prevents an old build from silently mangling a file written by a newer build
  that uses a different schema.

  ## Payload-size cap (MH1 DoS hardening)

  During load, rows whose `opcodes` list exceeds `@max_opcodes_from_config`
  (derived from `Lenies.Config.codeome_length_bounds/0`, currently 1000) are
  dropped before the expensive `String.to_existing_atom/1` conversion. This
  prevents a hand-crafted multi-million-element array from blocking the
  supervisor start.

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

  # Schema version written to disk. Bump when the JSON shape changes in a
  # backward-incompatible way. The read path handles v1 (current) and the
  # old bare-array format. Files with an unknown (higher) version are refused
  # and the store starts fresh rather than silently mangling foreign data.
  @schema_version 1

  # Opcodes cap: derived from the codeome upper bound so the guard is always
  # consistent with the rest of the system. Evaluated at compile time.
  @max_opcodes_from_config elem(Lenies.Config.codeome_length_bounds(), 1)

  @type seed :: %{
          id: String.t(),
          name: String.t(),
          color_hex: String.t(),
          energy_default: float(),
          opcodes: [atom()]
        }

  @hex_re ~r/^#[0-9a-fA-F]{6}$/

  def start_link(_opts) do
    Agent.start_link(fn -> load_from_disk() end, name: __MODULE__)
  end

  @spec all() :: [seed()]
  def all do
    Agent.get(__MODULE__, & &1)
  end

  @spec get(String.t()) :: nil | seed()
  def get(id) when is_binary(id) do
    Agent.get(__MODULE__, fn seeds -> Enum.find(seeds, &(&1.id == id)) end)
  end

  @spec save(seed()) ::
          :ok | {:error, :invalid_name | :invalid_color | :invalid_opcodes | :io_error}
  def save(%{} = seed) do
    with :ok <- validate_name(seed),
         :ok <- validate_color(seed),
         :ok <- validate_opcodes(seed) do
      # State update and disk write are performed together inside Agent.get_and_update/2.
      # The Agent serializes messages, so no two concurrent saves can interleave their
      # writes — disk and in-memory state always agree after the call returns.
      Agent.get_and_update(__MODULE__, fn seeds ->
        ns = [seed | Enum.reject(seeds, &(&1.id == seed.id))]
        {safe_write(ns), ns}
      end)
    end
  end

  @spec delete(String.t()) :: :ok | {:error, :io_error}
  def delete(id) when is_binary(id) do
    Agent.get_and_update(__MODULE__, fn seeds ->
      ns = Enum.reject(seeds, &(&1.id == id))
      {safe_write(ns), ns}
    end)
  end

  # ----- write safety -----

  # Runs inside the Agent process (called from within Agent.get_and_update/2).
  # Must rescue filesystem errors AND JSON encode errors — an unhandled raise
  # here would crash the Agent.
  defp safe_write(seeds) do
    try do
      write_to_disk(seeds)
      :ok
    rescue
      _e in [File.Error, Jason.EncodeError, Protocol.UndefinedError] -> {:error, :io_error}
    end
  end

  # ----- validation -----

  defp validate_name(%{name: name, id: id})
       when is_binary(name) and is_binary(id) do
    cond do
      String.trim(name) == "" -> {:error, :invalid_name}
      id == "" -> {:error, :invalid_name}
      not String.match?(name, ~r/[a-zA-Z0-9]/) -> {:error, :invalid_name}
      true -> :ok
    end
  end

  defp validate_name(%{name: name}) when is_binary(name) do
    cond do
      String.trim(name) == "" -> {:error, :invalid_name}
      not String.match?(name, ~r/[a-zA-Z0-9]/) -> {:error, :invalid_name}
      true -> :ok
    end
  end

  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_color(%{color_hex: hex}) when is_binary(hex) do
    if Regex.match?(@hex_re, hex), do: :ok, else: {:error, :invalid_color}
  end

  defp validate_color(_), do: {:error, :invalid_color}

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
    case Application.get_env(:lenies, :__test_user_seeds_file__) do
      path when is_binary(path) -> path
      _ -> Path.join(:code.priv_dir(:lenies), "user_seeds.json")
    end
  end

  defp load_from_disk do
    # Force-load Codeome.Opcodes so the opcode atoms (:nop_0, :eat, …)
    # are registered in the BEAM atom table before decode_seed/1 calls
    # String.to_existing_atom/1. Without this, the supervisor may start
    # CustomStore before any reference to the Opcodes module loads it,
    # and decoding would raise ArgumentError and silently drop every
    # seed in user_seeds.json.
    Code.ensure_loaded!(Lenies.Codeome.Opcodes)

    path = file_path()

    case File.read(path) do
      {:ok, contents} -> parse_contents(contents, path)
      {:error, _} -> []
    end
  end

  defp parse_contents(contents, path) do
    require Logger

    case Jason.decode(contents) do
      # New versioned envelope: {"version": N, "items": [...]}
      {:ok, %{"version" => v, "items" => list}} when is_list(list) and v == @schema_version ->
        list
        |> Enum.map(&decode_seed/1)
        |> Enum.filter(& &1)

      # Unknown/future version: refuse to decode to avoid silent data mangling.
      {:ok, %{"version" => v, "items" => _}} ->
        Logger.warning(
          "Lenies.Seeds.CustomStore: unknown schema version #{inspect(v)} " <>
            "(this build supports v#{@schema_version}); starting fresh"
        )

        []

      # Old bare-array format: backward-compatible load with zero data loss.
      # The next write will upgrade the file to the envelope format.
      {:ok, list} when is_list(list) ->
        list
        |> Enum.map(&decode_seed/1)
        |> Enum.filter(& &1)

      _ ->
        # Corrupt JSON. Rename for forensics and start fresh.
        backup = path <> ".bak"
        File.rename(path, backup)
        []
    end
  end

  defp decode_seed(%{} = m) do
    require Logger

    # MH1: Early payload-size guard — reject non-list opcodes and lists that
    # exceed the codeome upper bound BEFORE calling String.to_existing_atom/1.
    # This prevents a hand-crafted multi-million-element array from blocking
    # the supervisor start during Agent init.
    raw_opcodes = m["opcodes"]

    cond do
      not is_list(raw_opcodes) ->
        Logger.warning(
          "Lenies.Seeds.CustomStore: dropping seed #{inspect(m["id"])} — opcodes is not a list"
        )

        nil

      length(raw_opcodes) > @max_opcodes_from_config ->
        Logger.warning(
          "Lenies.Seeds.CustomStore: dropping seed #{inspect(m["id"])} — " <>
            "opcodes length #{length(raw_opcodes)} exceeds cap #{@max_opcodes_from_config}"
        )

        nil

      true ->
        try do
          ops = Enum.map(raw_opcodes, &String.to_existing_atom/1)

          energy =
            case m do
              %{"energy_default" => v} when is_number(v) -> v
              %{"energy_default" => _bad} -> :invalid_energy
              _ -> 10_000.0
            end

          candidate = %{
            id: m["id"],
            name: m["name"],
            color_hex: m["color_hex"],
            energy_default: energy,
            opcodes: ops
          }

          with true <- is_binary(candidate.id) and candidate.id != "",
               :ok <- validate_name(candidate),
               :ok <- validate_color(candidate),
               :ok <- validate_opcodes(candidate),
               true <- energy != :invalid_energy do
            candidate
          else
            _ ->
              Logger.warning(
                "Lenies.Seeds.CustomStore: dropping seed #{inspect(m["id"])} — failed validation"
              )

              nil
          end
        rescue
          ArgumentError ->
            Logger.warning(
              "Lenies.Seeds.CustomStore: dropping seed #{inspect(m["id"])} — unknown opcode(s)"
            )

            nil
        end
    end
  end

  defp decode_seed(_), do: nil

  defp write_to_disk(seeds) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))

    # MH4: Write the versioned envelope. Old bare-array files are upgraded to
    # this format on the next write after being loaded by parse_contents/2.
    json =
      Jason.encode!(
        %{"version" => @schema_version, "items" => Enum.map(seeds, &encode_seed/1)},
        pretty: true
      )

    # Unique suffix avoids any cross-process or cross-store tmp collision
    # and prevents stale-tmp reuse even if two OS processes share the dir.
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(tmp, json)
    File.rename!(tmp, path)
  end

  defp encode_seed(s) do
    %{
      "id" => s.id,
      "name" => s.name,
      "color_hex" => s.color_hex,
      "energy_default" => s.energy_default,
      "opcodes" => Enum.map(s.opcodes, &Atom.to_string/1)
    }
  end
end
