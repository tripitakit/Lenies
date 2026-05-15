defmodule Lenies.SpeciesColor do
  @moduledoc """
  Deterministic mapping from a Lenie `codeome_hash` to a display color.

  Single source of truth for color across the dashboard:
    - canvas pixels (server emits a hue byte, JS converts byte → HSL fill)
    - species table swatch (hex string in the HTML)
    - per-species polyline in the telemetry chart

  Stability: derived from `:erlang.phash2`, so the same hash always maps to
  the same color across restarts and across the Elixir/JS divide (as long
  as the byte → hue formula stays in sync).
  """

  @saturation 0.70
  @lightness 0.55

  @doc """
  Hue byte 1..255 for a species hash.

  The value 0 is reserved on the wire to mean "no species on this cell",
  so this function never returns 0.
  """
  @spec hue_byte(binary()) :: 1..255
  def hue_byte(hash) when is_binary(hash) do
    :erlang.phash2(hash, 255) + 1
  end

  @doc "CSS hex color (#RRGGBB) for a species hash."
  @spec hex(binary()) :: String.t()
  def hex(hash) when is_binary(hash) do
    hash |> hue_byte() |> byte_to_hex()
  end

  @doc """
  Convert a hue byte 1..255 to a #RRGGBB hex string.

  Uses the same saturation/lightness pair as the JS canvas, so the table
  swatch and the pixel for that species are visually identical.
  """
  @spec byte_to_hex(1..255) :: String.t()
  def byte_to_hex(byte) when byte in 1..255 do
    hue_deg = (byte - 1) / 255 * 360
    {r, g, b} = hsl_to_rgb(hue_deg, @saturation, @lightness)
    "#" <> byte_hex(r) <> byte_hex(g) <> byte_hex(b)
  end

  defp hsl_to_rgb(h, s, l) do
    c = (1 - abs(2 * l - 1)) * s
    h_prime = h / 60
    x = c * (1 - abs(:math.fmod(h_prime, 2) - 1))

    {r1, g1, b1} =
      cond do
        h_prime < 1 -> {c, x, 0}
        h_prime < 2 -> {x, c, 0}
        h_prime < 3 -> {0, c, x}
        h_prime < 4 -> {0, x, c}
        h_prime < 5 -> {x, 0, c}
        true -> {c, 0, x}
      end

    m = l - c / 2
    {round((r1 + m) * 255), round((g1 + m) * 255), round((b1 + m) * 255)}
  end

  defp byte_hex(b) do
    b
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
