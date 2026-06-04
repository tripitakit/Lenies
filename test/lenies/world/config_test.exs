defmodule Lenies.World.ConfigTest do
  # async: false — tests below mutate Application env (:spawn_cap, :replication_cap)
  # which is process-global. Matches the convention used by world_replication_test.exs,
  # plasmid_inheritance_test.exs and arena_test.exs.
  use ExUnit.Case, async: false

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
    assert cfg.radiation_per_tick == Config.defaults().radiation_per_tick
  end

  test "merge/2 ignores unknown keys" do
    cfg = Config.merge(Config.defaults(), %{bogus_key: 9999})
    refute Map.has_key?(cfg, :bogus_key)
  end

  test "defaults/0 includes spawn_cap and replication_cap from app env or struct fallback" do
    saved_spawn = Application.get_env(:lenies, :spawn_cap)
    saved_repl = Application.get_env(:lenies, :replication_cap)
    Application.delete_env(:lenies, :spawn_cap)
    Application.delete_env(:lenies, :replication_cap)

    on_exit(fn ->
      restore_env(:spawn_cap, saved_spawn)
      restore_env(:replication_cap, saved_repl)
    end)

    cfg = Lenies.World.Config.defaults()
    assert cfg.spawn_cap == 10
    assert cfg.replication_cap == 50
  end

  test "defaults/0 reads spawn_cap and replication_cap from app env when set" do
    saved_spawn = Application.get_env(:lenies, :spawn_cap)
    saved_repl = Application.get_env(:lenies, :replication_cap)
    Application.put_env(:lenies, :spawn_cap, 7)
    Application.put_env(:lenies, :replication_cap, 25)

    on_exit(fn ->
      restore_env(:spawn_cap, saved_spawn)
      restore_env(:replication_cap, saved_repl)
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

  defp restore_env(_key, nil), do: :ok
  defp restore_env(key, value), do: Application.put_env(:lenies, key, value)
end
