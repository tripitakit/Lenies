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

  test "plasmid_loss_probability/0 defaults to 0.10" do
    Application.delete_env(:lenies, :plasmid_loss_probability)
    assert Config.plasmid_loss_probability() == 0.10
  end

  test "plasmid_loss_probability/0 reads an override" do
    Application.put_env(:lenies, :plasmid_loss_probability, 0.25)
    on_exit(fn -> Application.delete_env(:lenies, :plasmid_loss_probability) end)
    assert Config.plasmid_loss_probability() == 0.25
  end

  describe "energy_ref/0" do
    test "defaults to 1000 and reads from app env" do
      assert Lenies.Config.energy_ref() == 1000
      Application.put_env(:lenies, :energy_ref, 1234)
      on_exit(fn -> Application.delete_env(:lenies, :energy_ref) end)
      assert Lenies.Config.energy_ref() == 1234
    end
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
