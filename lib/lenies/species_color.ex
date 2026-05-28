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

  ## Multi-world API

  Color overrides are per-world: each world owns a `:color_overrides`
  ETS table inside its `%Lenies.WorldHandle{}`. Functions that read or
  write overrides take a handle as their first argument:

      Lenies.SpeciesColor.set_override(handle, hash, "#ff00aa")
      Lenies.SpeciesColor.hex(handle, hash)

  `byte_to_hex/1` derives a color from a hue byte without touching the
  overrides table and so is handle-free.
  """

  @saturation 0.70
  @lightness 0.55

  @doc """
  Hue byte 1..255 for a species hash. The value 0 is reserved on the
  wire to mean "no species on this cell", so this function never
  returns 0.

  Honors color overrides: if the user has registered a hex override for
  this species via `set_override/3`, the returned byte is derived from
  the override's hue (so the canvas paints that species in roughly the
  picked colour). The canvas's HSL formula uses fixed S=0.70 / L=0.55,
  so the override's saturation and lightness are normalised — only the
  hue survives the 1-byte wire format. Without an override, the byte is
  a stable hash → byte mapping via `:erlang.phash2/2`.
  """
  @spec hue_byte(Lenies.WorldHandle.t(), binary()) :: 1..255
  def hue_byte(%Lenies.WorldHandle{} = handle, hash) when is_binary(hash) do
    case override(handle, hash) do
      nil -> :erlang.phash2(hash, 255) + 1
      hex -> hex_to_hue_byte(hex) || :erlang.phash2(hash, 255) + 1
    end
  end

  @doc """
  Register a hex color override for a species hash on the world referenced by
  `handle`. Overrides survive sterilize but not world restart.
  """
  @spec set_override(Lenies.WorldHandle.t(), binary(), String.t()) :: true
  def set_override(%Lenies.WorldHandle{} = handle, hash, hex)
      when is_binary(hash) and is_binary(hex) do
    :ets.insert(handle.tables.color_overrides, {hash, hex})
  end

  @doc "Remove a hex color override for a species hash on the world referenced by `handle`."
  @spec clear_override(Lenies.WorldHandle.t(), binary()) :: true
  def clear_override(%Lenies.WorldHandle{} = handle, hash) when is_binary(hash) do
    :ets.delete(handle.tables.color_overrides, hash)
  end

  @doc "Read the hex color override for a hash on the world referenced by `handle`, or `nil` if none is set."
  @spec override(Lenies.WorldHandle.t(), binary()) :: nil | String.t()
  def override(%Lenies.WorldHandle{} = handle, hash) when is_binary(hash) do
    case :ets.lookup(handle.tables.color_overrides, hash) do
      [{^hash, hex}] -> hex
      [] -> nil
    end
  end

  @doc "CSS hex color (#RRGGBB) for a species hash on the world referenced by `handle`. Honors per-hash overrides."
  @spec hex(Lenies.WorldHandle.t(), binary()) :: String.t()
  def hex(%Lenies.WorldHandle{} = handle, hash) when is_binary(hash) do
    case override(handle, hash) do
      nil -> handle |> hue_byte(hash) |> byte_to_hex()
      explicit when is_binary(explicit) -> explicit
    end
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

  # Map a user-picked "#RRGGBB" to the closest hue byte 1..255 that the
  # canvas's byte → HSL formula can produce. Returns nil for malformed
  # input or pure greyscale (where hue is undefined). Saturation and
  # lightness of the picked colour are lost; only the hue survives.
  defp hex_to_hue_byte("#" <> rgb) when byte_size(rgb) == 6 do
    case Integer.parse(rgb, 16) do
      {n, ""} ->
        r = Bitwise.bsr(n, 16) |> Bitwise.band(0xFF)
        g = Bitwise.bsr(n, 8) |> Bitwise.band(0xFF)
        b = Bitwise.band(n, 0xFF)

        case rgb_to_hue_deg(r, g, b) do
          nil ->
            nil

          hue_deg ->
            byte = round(hue_deg / 360 * 255) + 1
            byte |> min(255) |> max(1)
        end

      _ ->
        nil
    end
  end

  defp hex_to_hue_byte(_), do: nil

  defp rgb_to_hue_deg(r, g, b) do
    rf = r / 255
    gf = g / 255
    bf = b / 255
    cmax = max(rf, max(gf, bf))
    cmin = min(rf, min(gf, bf))
    delta = cmax - cmin

    cond do
      delta == 0 ->
        nil

      cmax == rf ->
        (:math.fmod((gf - bf) / delta, 6) * 60) |> wrap360()

      cmax == gf ->
        ((bf - rf) / delta + 2) * 60

      true ->
        ((rf - gf) / delta + 4) * 60
    end
  end

  defp wrap360(deg) when deg < 0, do: deg + 360
  defp wrap360(deg), do: deg

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
