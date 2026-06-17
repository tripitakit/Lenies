defmodule Lenies.World.Field do
  @moduledoc """
  Pure analytic resource field for a world: a deterministic hybrid of moving
  wave modes (temporal boom/bust cycles) and scrolling value noise (organic
  spatial structure). `level(field, x, y, tick)` returns a value in 0.0..1.0
  that the world uses as a per-cell resource TARGET (× cap).

  Deterministic given a per-world integer seed (`new/1`), so it needs no stored
  grid state. Conservative constants below are compile-time only (no runtime
  knobs); they can be raised later.
  """

  # --- tunable constants (conservative; no runtime knob) ---
  @alpha 0.5
  @speed 0.02
  # Lower spatial frequency = WIDER oasis/desert zones. Halved the noise scale
  # and the wave wavevectors (kx,ky) vs the first cut, doubling feature size.
  @scale 0.05
  @driftx 0.004
  @drifty 0.0017
  @modes [
    {0.14, 0.05, 0.9, 1.0},
    {-0.06, 0.12, -1.3, 0.85},
    {0.09, -0.10, 1.7, 0.7},
    {0.035, 0.165, 0.6, 0.6},
    {-0.15, -0.03, -0.8, 0.5}
  ]
  @amp Enum.reduce(@modes, 0.0, fn {_kx, _ky, _w, a}, s -> s + a end)

  @enforce_keys [:seed, :phases]
  defstruct [:seed, :phases]

  @type t :: %__MODULE__{seed: integer(), phases: [float()]}

  @doc "Build a field from a per-world integer seed (precomputes mode phases)."
  @spec new(integer()) :: t()
  def new(seed) when is_integer(seed) do
    phases =
      Enum.map(@modes, fn {kx, ky, _w, _a} ->
        :erlang.phash2({seed, kx, ky}, 1000) / 1000 * 2 * :math.pi()
      end)

    %__MODULE__{seed: seed, phases: phases}
  end

  @doc "Field level in 0.0..1.0 at cell (x,y) and world `tick`."
  @spec level(t(), integer(), integer(), integer()) :: float()
  def level(%__MODULE__{seed: seed, phases: phases}, x, y, tick)
      when is_integer(x) and is_integer(y) and is_integer(tick) do
    t = tick * @speed
    waves = wave_sum(x, y, t, phases)
    waves_norm = (waves / @amp + 1.0) / 2.0
    n = noise(x * @scale + tick * @driftx, y * @scale + tick * @drifty, seed)
    clamp01((1.0 - @alpha) * waves_norm + @alpha * n)
  end

  defp wave_sum(x, y, t, phases) do
    @modes
    |> Enum.zip(phases)
    |> Enum.reduce(0.0, fn {{kx, ky, w, a}, ph}, acc ->
      acc + a * :math.sin(kx * x + ky * y + w * t + ph)
    end)
  end

  defp noise(x, y, seed) do
    vnoise(x, y, seed) * 0.65 + vnoise(x * 2.3, y * 2.3, seed + 1) * 0.35
  end

  defp vnoise(x, y, seed) do
    xi = floor(x)
    yi = floor(y)
    xf = x - xi
    yf = y - yi
    u = smooth(xf)
    v = smooth(yf)
    a = lattice(xi, yi, seed)
    b = lattice(xi + 1, yi, seed)
    c = lattice(xi, yi + 1, seed)
    d = lattice(xi + 1, yi + 1, seed)
    a * (1 - u) * (1 - v) + b * u * (1 - v) + c * (1 - u) * v + d * u * v
  end

  defp smooth(t), do: t * t * (3.0 - 2.0 * t)

  defp lattice(i, j, seed), do: :erlang.phash2({i, j, seed}, 1_000_000) / 1_000_000

  defp clamp01(v) when v < 0.0, do: 0.0
  defp clamp01(v) when v > 1.0, do: 1.0
  defp clamp01(v), do: v
end
