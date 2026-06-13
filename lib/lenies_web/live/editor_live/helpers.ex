defmodule LeniesWeb.EditorLive.Helpers do
  @moduledoc """
  Pure, socket-free helpers extracted from `LeniesWeb.EditorLive`.

  These are the parsing / decoding / economics utilities the editor leans on
  but which carry no LiveView state — keeping them here shrinks the editor
  LiveView and, more importantly, makes them unit-testable in isolation
  (they used to be private functions buried in a 1400-line module).

  `EditorLive` `import`s this module, so existing call sites keep working
  unchanged.
  """

  alias LeniesWeb.GenomeBuffer

  @doc """
  Energy economics for a genome at the app's current `eat_amount` /
  `attack_damage` tuning. Pure given the runtime config.
  """
  def current_economics(genome) do
    eat_amount = Application.get_env(:lenies, :eat_amount, 20)
    attack_damage = Application.get_env(:lenies, :attack_damage, 10)
    GenomeBuffer.economics(genome, eat_amount, attack_damage)
  end

  @doc """
  Non-empty plasmid buffers as `%Lenies.Plasmid{}` structs — what a stepper
  session carries (empty buffers contribute no exec rows, so they're rejected
  to keep the flat exec list aligned with `GenomeBuffer`).
  """
  def plasmid_structs(%GenomeBuffer{} = g) do
    g.plasmids |> Enum.reject(&(&1 == [])) |> Enum.map(&Lenies.Plasmid.new/1)
  end

  @doc "Decode a section token from the client into a section address."
  def decode_section("chromosome"), do: :chromosome
  def decode_section("p" <> i), do: {:plasmid, to_int(i)}
  def decode_section(_), do: :chromosome

  @doc """
  Parse an integer, returning -1 on failure.

  `select_block` indices come from the editor's own JS hook (always numeric),
  but we parse defensively: unparseable input becomes -1, which the handler's
  `index < 0` guard treats as a no-op instead of crashing.
  """
  def to_int(n) when is_integer(n), do: n

  def to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> -1
    end
  end

  @doc "Parse an integer and clamp it to `[min, max]`, falling back to `default`."
  def parse_clamped(str, min, max, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n |> max(min) |> min(max)
      :error -> default
    end
  end

  def parse_clamped(_, _, _, default), do: default

  @doc """
  Decode persisted comments from a string-keyed JSON map (`%{"3" => "txt"}`)
  into an integer-keyed map, dropping anything unparseable.
  """
  def decode_saved_comments(map) when is_map(map) do
    for {k, v} <- map, flat = parse_flat_key(k), is_integer(flat), is_binary(v), into: %{} do
      {flat, v}
    end
  end

  def decode_saved_comments(_), do: %{}

  @doc "Parse a flat exec-index key (integer or string), or nil if unparseable."
  def parse_flat_key(k) when is_integer(k), do: k

  def parse_flat_key(k) when is_binary(k) do
    case Integer.parse(k) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def parse_flat_key(_), do: nil

  @doc """
  Tokenise a free-text opcode list (split on whitespace and commas,
  lowercased) and validate each token against the known opcode set.

  Returns `{:ok, [atom]}` if every token is a known opcode, or
  `{:error, [string]}` listing the unknown tokens. Empty input → `{:ok, []}`.
  """
  def parse_opcode_text(text) when is_binary(text) do
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

  @doc "Resolve a single token to a known opcode atom, or `:error`."
  def to_known_opcode(token) do
    atom = String.to_existing_atom(token)
    if Lenies.Codeome.Opcodes.known?(atom), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end
end
