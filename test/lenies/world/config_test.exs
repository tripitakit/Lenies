defmodule Lenies.World.ConfigTest do
  use ExUnit.Case, async: true

  alias Lenies.World.Config

  test "defaults/0 returns a Config struct with non-nil values for every field" do
    cfg = Config.defaults()
    assert %Config{} = cfg

    for {field, _default} <- Map.to_list(struct(Config)) do
      refute is_nil(Map.fetch!(cfg, field)),
             "field #{inspect(field)} is nil in Config.defaults/0"
    end
  end

  test "merge/2 overrides defaults with caller-provided values" do
    cfg = Config.merge(Config.defaults(), %{eat_amount: 200.0, attack_damage: 25})
    assert cfg.eat_amount == 200.0
    assert cfg.attack_damage == 25
    # untouched fields keep their defaults
    assert cfg.grid_width == Config.defaults().grid_width
  end

  test "merge/2 ignores unknown keys" do
    cfg = Config.merge(Config.defaults(), %{bogus_key: 9999})
    refute Map.has_key?(cfg, :bogus_key)
  end
end
