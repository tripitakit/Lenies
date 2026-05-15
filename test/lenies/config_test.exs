defmodule Lenies.ConfigTest do
  use ExUnit.Case, async: false

  alias Lenies.Config

  test "grid_size/0 returns configured size" do
    assert Config.grid_size() == {256, 256}
  end

  test "tick_interval_ms/0 returns configured value" do
    assert Config.tick_interval_ms() == 100
  end

  test "radiation_per_tick/0 returns configured value" do
    assert Config.radiation_per_tick() == 1000
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
    original = Application.get_env(:lenies, :carcass_decay)
    Application.put_env(:lenies, :carcass_decay, 0.05)

    try do
      assert Config.carcass_decay() == 0.05
    after
      Application.put_env(:lenies, :carcass_decay, original)
    end
  end

  test "population_warning_threshold/0 returns configured value" do
    assert Config.population_warning_threshold() == 0.8
  end

  test "codeome_length_bounds/0 returns configured value" do
    assert Config.codeome_length_bounds() == {5, 500}
  end

  test "min_viable_codeome_opcodes/0 returns configured value" do
    assert Config.min_viable_codeome_opcodes() == 10
  end

  describe "configuration override" do
    setup do
      on_exit(fn -> Application.put_env(:lenies, :grid_size, {256, 256}) end)
      :ok
    end

    test "getters delegate to Application.get_env (override is observable)" do
      Application.put_env(:lenies, :grid_size, {512, 512})
      assert Config.grid_size() == {512, 512}
    end
  end
end
