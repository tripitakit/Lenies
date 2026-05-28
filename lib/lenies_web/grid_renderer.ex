defmodule LeniesWeb.GridRenderer do
  @moduledoc """
  Encodes the `:cells` ETS table into compact binary layers for the dashboard
  canvas.

  Four layers, each `width * height` bytes, row-major (`byte_index = y * width + x`):

    - `lenies`       — 0 if cell is empty; otherwise the species hue byte
                       (1..255) of the Lenie occupying the cell. The mapping is
                       `Lenies.SpeciesColor.hue_byte(handle, codeome_hash)`. If
                       the Lenie hasn't written its first snapshot yet so the
                       hash isn't in `:lenies`, the byte is 0 (rendered as
                       no-species briefly).
    - `resource`     — `cell.resource` clamped to 0..255.
    - `carcass`      — `cell.carcass` clamped to 0..255.
    - `carcass_hue`  — `cell.carcass_hue` (0 means no species color, render
                       as generic; 1..255 is the hue byte of the dead Lenie).

  `encode_payload/1` returns a base64-encoded map for transport over
  LiveView's `push_event/3` to the client JS hook.
  """

  alias Lenies.SpeciesColor

  @doc "Encode cells into 4 binary layers (lenies, resource, carcass, carcass_hue)."
  @spec encode_layers({pos_integer(), pos_integer()}) ::
          {binary(), binary(), binary(), binary()}
  def encode_layers({w, h}) do
    handle = fetch_handle()
    cells = if handle, do: :ets.tab2list(handle.tables.cells) |> Map.new(), else: %{}
    hash_by_id = build_hash_index(handle)

    bytes =
      for y <- 0..(h - 1), x <- 0..(w - 1) do
        case Map.get(cells, {x, y}) do
          nil ->
            {0, 0, 0, 0}

          cell ->
            l = lenies_byte(cell, hash_by_id, handle)
            r = cell.resource |> clamp_byte()
            c = cell.carcass |> clamp_byte()
            ch = cell.carcass_hue |> clamp_byte()
            {l, r, c, ch}
        end
      end

    lenies_bin = bytes |> Enum.map(fn {l, _, _, _} -> l end) |> :erlang.list_to_binary()
    resource_bin = bytes |> Enum.map(fn {_, r, _, _} -> r end) |> :erlang.list_to_binary()
    carcass_bin = bytes |> Enum.map(fn {_, _, c, _} -> c end) |> :erlang.list_to_binary()

    carcass_hue_bin =
      bytes |> Enum.map(fn {_, _, _, ch} -> ch end) |> :erlang.list_to_binary()

    {lenies_bin, resource_bin, carcass_bin, carcass_hue_bin}
  end

  @doc "Encode the grid for transport: base64-encoded layers + dimensions."
  @spec encode_payload({pos_integer(), pos_integer()}) :: map()
  def encode_payload({w, h} = grid) do
    {l, r, c, ch} = encode_layers(grid)

    %{
      lenies: Base.encode64(l),
      resource: Base.encode64(r),
      carcass: Base.encode64(c),
      carcass_hue: Base.encode64(ch),
      width: w,
      height: h
    }
  end

  # One ETS scan to build {lenie_id => codeome_hash}. Avoids a per-cell lookup
  # in the inner row-major loop.
  defp build_hash_index(nil), do: %{}

  defp build_hash_index(handle) do
    :ets.tab2list(handle.tables.lenies)
    |> Map.new(fn {id, record} -> {id, Map.get(record, :codeome_hash)} end)
  end

  # Returns the primary world's handle or nil if the World isn't running.
  # Empty render output is preferable to crashing when called before the
  # World has booted.
  defp fetch_handle do
    try do
      Lenies.Worlds.primary_handle()
    catch
      :exit, _ -> nil
    end
  end

  defp lenies_byte(%{lenie_id: nil}, _index, _handle), do: 0

  defp lenies_byte(%{lenie_id: id}, index, handle) when is_binary(id) do
    case Map.get(index, id) do
      hash when is_binary(hash) -> SpeciesColor.hue_byte(handle, hash)
      _ -> 0
    end
  end

  defp lenies_byte(_, _, _), do: 0

  defp clamp_byte(n) when is_integer(n) and n >= 0 and n <= 255, do: n
  defp clamp_byte(n) when is_integer(n) and n < 0, do: 0
  defp clamp_byte(n) when is_integer(n) and n > 255, do: 255
  defp clamp_byte(_), do: 0
end
