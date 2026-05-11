defmodule Lenies.ConfigTest do
  use ExUnit.Case, async: true

  alias Lenies.Config

  test "grid_size/0 returns configured size" do
    assert Config.grid_size() == {256, 256}
  end

  test "tick_interval_ms/0 returns configured value" do
    assert Config.tick_interval_ms() == 100
  end

  test "radiation_per_tick/0 returns configured value" do
    assert Config.radiation_per_tick() == 100
  end

  test "population_cap/0 returns configured value" do
    assert Config.population_cap() == 50_000
  end

  test "cell_resource_cap/0 returns configured value" do
    assert Config.cell_resource_cap() == 100
  end

  test "hotspot_count/0 returns configured value" do
    assert Config.hotspot_count() == 8
  end

  test "radiation_uniform_ratio/0 returns float 0..1" do
    r = Config.radiation_uniform_ratio()
    assert is_float(r) and r >= 0.0 and r <= 1.0
  end

  test "carcass_decay/0 returns configured value" do
    assert Config.carcass_decay() == 0.05
  end
end
