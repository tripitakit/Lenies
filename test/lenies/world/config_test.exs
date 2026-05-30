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

  test "defaults/0 includes spawn_cap and replication_cap from app env or struct fallback" do
    Application.delete_env(:lenies, :spawn_cap)
    Application.delete_env(:lenies, :replication_cap)

    cfg = Lenies.World.Config.defaults()
    assert cfg.spawn_cap == 10
    assert cfg.replication_cap == 50
  end

  test "defaults/0 reads spawn_cap and replication_cap from app env when set" do
    Application.put_env(:lenies, :spawn_cap, 7)
    Application.put_env(:lenies, :replication_cap, 25)

    on_exit(fn ->
      Application.delete_env(:lenies, :spawn_cap)
      Application.delete_env(:lenies, :replication_cap)
    end)

    cfg = Lenies.World.Config.defaults()
    assert cfg.spawn_cap == 7
    assert cfg.replication_cap == 25
  end

  test "merge/2 accepts spawn_cap and replication_cap overrides" do
    cfg =
      Lenies.World.Config.defaults()
      |> Lenies.World.Config.merge(%{spawn_cap: :infinity, replication_cap: :infinity})

    assert cfg.spawn_cap == :infinity
    assert cfg.replication_cap == :infinity
  end
end
