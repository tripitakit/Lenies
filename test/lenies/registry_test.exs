defmodule Lenies.RegistryTest do
  use ExUnit.Case, async: false

  alias Lenies.Registry, as: LenieRegistry

  setup do
    on_exit(fn ->
      # Unregister anything left behind
      Elixir.Registry.dispatch(LenieRegistry, "", fn _ -> :ok end)
      :ok
    end)

    :ok
  end

  test "register/1 binds the current process to an id" do
    {:ok, _} = LenieRegistry.register("lenie-1")
    assert LenieRegistry.whereis("lenie-1") == self()
  end

  test "whereis/1 returns nil when id is unknown" do
    assert LenieRegistry.whereis("never-registered") == nil
  end

  test "count/0 reflects registered processes" do
    {:ok, _} = LenieRegistry.register("lenie-A")
    assert LenieRegistry.count() >= 1
  end
end
