defmodule Lenies.ConfigTest do
  use ExUnit.Case, async: false

  alias Lenies.Config

  test "grid_size/0 returns configured size" do
    assert Config.grid_size() == {128, 128}
  end

  test "tick_interval_ms/0 returns configured value" do
    assert Config.tick_interval_ms() == 200
  end

  test "radiation_per_tick/0 returns configured value" do
    assert Config.radiation_per_tick() == 500
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

  test "codeome_length_bounds/0 returns configured value" do
    assert Config.codeome_length_bounds() == {5, 1024}
  end

  test "min_viable_codeome_opcodes/0 returns configured value" do
    assert Config.min_viable_codeome_opcodes() == 10
  end

  describe "configuration override" do
    setup do
      on_exit(fn -> Application.put_env(:lenies, :grid_size, {128, 128}) end)
      :ok
    end

    test "getters delegate to Application.get_env (override is observable)" do
      Application.put_env(:lenies, :grid_size, {512, 512})
      assert Config.grid_size() == {512, 512}
    end
  end
end
