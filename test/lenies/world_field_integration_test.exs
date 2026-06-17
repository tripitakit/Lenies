defmodule Lenies.WorldFieldIntegrationTest do
  use ExUnit.Case, async: true
  alias Lenies.World.Field

  @moduledoc """
  The fluctuating field must keep the world heterogeneous over time — unlike the
  old uniform drip that saturated every cell to the cap.
  """

  test "field spatial variance persists across time (no homogenisation)" do
    f = Field.new(:erlang.phash2(:integration_world))
    cap = 3 * Application.get_env(:lenies, :eat_amount, 50)

    # Sample a wide window so the metric is robust to zone WIDTH (wider
    # oasis/desert zones mean a small window can sit inside one zone).
    spreads =
      for tick <- [0, 25, 50, 100, 200] do
        targets = for x <- 0..110, y <- 0..110, do: round(Field.level(f, x, y, tick) * cap)
        Enum.max(targets) - Enum.min(targets)
      end

    # At every sampled tick there is a substantial gap between richest and
    # poorest cell (oases vs deserts) — the world never flattens.
    assert Enum.all?(spreads, &(&1 > cap * 0.3))
  end

  test "field mean sits near the calibrated midpoint (not saturated)" do
    f = Field.new(123)
    cap = 3 * Application.get_env(:lenies, :eat_amount, 50)
    targets = for x <- 0..60, y <- 0..60, do: Field.level(f, x, y, 30) * cap
    mean = Enum.sum(targets) / length(targets)
    # leaner than the old ~cap saturation; roughly the middle of the range
    assert mean > cap * 0.25 and mean < cap * 0.75
  end
end
