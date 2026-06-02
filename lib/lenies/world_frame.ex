defmodule Lenies.WorldFrame do
  @moduledoc """
  Encodes a world's `:cells` ETS table into compact binary layers for the
  dashboard / arena canvas.

  Four layers, each `width * height` bytes, row-major (`byte_index = y * width + x`):

    - `lenies`       — 0 if cell is empty; otherwise the species hue byte
                       (1..255) of the Lenie occupying the cell.
    - `resource`     — `cell.resource` clamped to 0..255.
    - `carcass`      — `cell.carcass` clamped to 0..255.
    - `carcass_hue`  — `cell.carcass_hue` (0 means generic; 1..255 hue byte).

  `encode_payload/2` returns a base64-encoded map for transport over
  LiveView's `push_event/3` to the client JS hook.

  ## Performance

  This is the single most expensive read in the UI path (one byte produced
  per cell — 65 536 cells on a 256×256 grid). It lives in the domain layer
  (not `lib/lenies_web`) so `Lenies.WorldRenderer` — a per-world process —
  can encode **once** per frame and broadcast the result to every viewer,
  instead of each LiveView socket recomputing it independently. The encoder
  itself builds the four layer binaries in a single pass over the cells (no
  intermediate list of per-cell tuples) to keep allocation/GC pressure low.
  """

  alias Lenies.SpeciesColor

  @doc """
  Encode cells into 4 binary layers (lenies, resource, carcass, carcass_hue).

  `handle` is the `%Lenies.WorldHandle{}` for the world being rendered. `nil`
  is tolerated and produces an all-zero frame — preferable to crashing on a
  transient nil handle.
  """
  @spec encode_layers(Lenies.WorldHandle.t() | nil, {pos_integer(), pos_integer()}) ::
          {binary(), binary(), binary(), binary()}
  def encode_layers(handle, {w, h}) do
    cells = if handle, do: :ets.tab2list(handle.tables.cells) |> Map.new(), else: %{}
    hash_by_id = build_hash_index(handle)

    # Single pass, row-major. Each layer is accumulated as a reversed list of
    # bytes and turned into a binary once at the end — one `list_to_binary`
    # per layer instead of building an intermediate list of 4-tuples and then
    # mapping over it four times.
    {ls, rs, cs, chs} =
      Enum.reduce((h - 1)..0//-1, {[], [], [], []}, fn y, outer ->
        Enum.reduce((w - 1)..0//-1, outer, fn x, {la, ra, ca, cha} ->
          case Map.get(cells, {x, y}) do
            nil ->
              {[0 | la], [0 | ra], [0 | ca], [0 | cha]}

            cell ->
              l = lenies_byte(cell, hash_by_id, handle)
              r = clamp_byte(cell.resource)
              c = clamp_byte(cell.carcass)
              ch = clamp_byte(cell.carcass_hue)
              {[l | la], [r | ra], [c | ca], [ch | cha]}
          end
        end)
      end)

    {:erlang.list_to_binary(ls), :erlang.list_to_binary(rs), :erlang.list_to_binary(cs),
     :erlang.list_to_binary(chs)}
  end

  @doc "Encode the grid for transport: base64-encoded layers + dimensions."
  @spec encode_payload(Lenies.WorldHandle.t() | nil, {pos_integer(), pos_integer()}) :: map()
  def encode_payload(handle, {w, h} = grid) do
    {l, r, c, ch} = encode_layers(handle, grid)

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
