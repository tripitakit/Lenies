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
    # Lenie positions come from the World's CONSISTENT occupancy snapshot, NOT
    # from `cell.lenie_id` in the `cells` map above. `cells` was read via a
    # non-isolated `:ets.tab2list`, which during a concurrent move can show a
    # lenie at a stale/duplicate/missing cell (the "drawn one cell off" bug).
    # The snapshot is read with one atomic `:ets.lookup`, so it's coherent.
    # `resource`/`carcass` stay on `cells` — they're smooth fields where a
    # one-tick-stale value is invisible.
    occupancy = read_occupancy(handle, cells)

    # Single pass, row-major. Each layer is accumulated as a reversed list of
    # bytes and turned into a binary once at the end — one `list_to_binary`
    # per layer instead of building an intermediate list of 4-tuples and then
    # mapping over it four times.
    {ls, rs, cs, chs} =
      Enum.reduce((h - 1)..0//-1, {[], [], [], []}, fn y, outer ->
        Enum.reduce((w - 1)..0//-1, outer, fn x, {la, ra, ca, cha} ->
          l = lenie_byte_at({x, y}, occupancy, hash_by_id, handle)

          {r, c, ch} =
            case Map.get(cells, {x, y}) do
              nil ->
                {0, 0, 0}

              cell ->
                {clamp_byte(cell.resource), clamp_byte(cell.carcass),
                 clamp_byte(cell.carcass_hue)}
            end

          {[l | la], [r | ra], [c | ca], [ch | cha]}
        end)
      end)

    {:erlang.list_to_binary(ls), :erlang.list_to_binary(rs), :erlang.list_to_binary(cs),
     :erlang.list_to_binary(chs)}
  end

  # Consistent lenie-occupancy map `%{ {x,y} => lenie_id }`. Prefers the
  # World's atomically-written `:occupancy` snapshot. Falls back to deriving it
  # from the already-loaded `cells` only when no populated snapshot exists
  # (legacy handles, tests that poke `:cells` directly, or the brief window
  # before the first snapshot) — callers in those cases are single-threaded, so
  # there is no move race to worry about.
  defp read_occupancy(nil, _cells), do: %{}

  defp read_occupancy(handle, cells) do
    snapshot =
      case handle do
        %{tables: %{occupancy: tid}} ->
          case :ets.lookup(tid, :snapshot) do
            [{:snapshot, m}] when is_map(m) -> m
            _ -> nil
          end

        _ ->
          nil
      end

    if is_map(snapshot) and map_size(snapshot) > 0 do
      snapshot
    else
      derive_occupancy_from_cells(cells)
    end
  end

  defp derive_occupancy_from_cells(cells) do
    Enum.reduce(cells, %{}, fn {key, cell}, acc ->
      case Map.get(cell, :lenie_id) do
        id when is_binary(id) -> Map.put(acc, key, id)
        _ -> acc
      end
    end)
  end

  defp lenie_byte_at(key, occupancy, hash_by_id, handle) do
    case Map.get(occupancy, key) do
      id when is_binary(id) ->
        case Map.get(hash_by_id, id) do
          hash when is_binary(hash) -> SpeciesColor.hue_byte(handle, hash)
          _ -> 0
        end

      _ ->
        0
    end
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

  defp clamp_byte(n) when is_integer(n) and n >= 0 and n <= 255, do: n
  defp clamp_byte(n) when is_integer(n) and n < 0, do: 0
  defp clamp_byte(n) when is_integer(n) and n > 255, do: 255
  defp clamp_byte(_), do: 0
end
