defmodule LeniesWeb.GridRenderer do
  @moduledoc """
  Encodes the `:cells` ETS table into compact binary layers for the dashboard
  canvas.

  Layer format: each layer is a binary of `width * height` bytes, row-major
  (`byte_index = y * width + x`). Values:
  - lenies layer: `1` if cell has `lenie_id`, else `0`
  - resource layer: `cell.resource` (0..255, clamped from cell.resource 0..100)
  - carcass layer: `cell.carcass` (0..255, clamped from cell.carcass 0..50)

  `encode_payload/1` returns a base64-encoded map for transport over LiveView's
  `push_event/3` to the client JS hook.
  """

  @doc "Encode cells into 3 binary layers (lenies, resource, carcass)."
  @spec encode_layers({pos_integer(), pos_integer()}) :: {binary(), binary(), binary()}
  def encode_layers({w, h}) do
    cells = :ets.tab2list(:cells) |> Map.new()

    bytes =
      for y <- 0..(h - 1), x <- 0..(w - 1) do
        case Map.get(cells, {x, y}) do
          nil ->
            {0, 0, 0}

          cell ->
            l = if cell.lenie_id != nil, do: 1, else: 0
            r = cell.resource |> clamp_byte()
            c = cell.carcass |> clamp_byte()
            {l, r, c}
        end
      end

    lenies_bin = bytes |> Enum.map(fn {l, _, _} -> l end) |> :erlang.list_to_binary()
    resource_bin = bytes |> Enum.map(fn {_, r, _} -> r end) |> :erlang.list_to_binary()
    carcass_bin = bytes |> Enum.map(fn {_, _, c} -> c end) |> :erlang.list_to_binary()

    {lenies_bin, resource_bin, carcass_bin}
  end

  @doc "Encode the grid for transport: base64-encoded layers + dimensions."
  @spec encode_payload({pos_integer(), pos_integer()}) :: map()
  def encode_payload({w, h} = grid) do
    {l, r, c} = encode_layers(grid)

    %{
      lenies: Base.encode64(l),
      resource: Base.encode64(r),
      carcass: Base.encode64(c),
      width: w,
      height: h
    }
  end

  defp clamp_byte(n) when is_integer(n) and n >= 0 and n <= 255, do: n
  defp clamp_byte(n) when n < 0, do: 0
  defp clamp_byte(n) when n > 255, do: 255
  defp clamp_byte(_), do: 0
end
