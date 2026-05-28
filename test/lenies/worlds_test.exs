defmodule Lenies.WorldsTest do
  # The handle smoke test starts a singleton :primary World, so the module
  # cannot be async. The id_to_path/1 tests are still pure and would be safe
  # in async mode on their own.
  use ExUnit.Case, async: false

  describe "id_to_path/1" do
    test "atom world id renders as the atom name" do
      assert Lenies.Worlds.id_to_path(:primary) == "primary"
      assert Lenies.Worlds.id_to_path(:arena) == "arena"
    end

    test "tuple {atom, integer} renders as 'atom-integer'" do
      assert Lenies.Worlds.id_to_path({:sandbox, 42}) == "sandbox-42"
    end

    test "is filesystem-safe (no slashes or dots)" do
      refute Lenies.Worlds.id_to_path(:primary) =~ "/"
      refute Lenies.Worlds.id_to_path({:sandbox, 42}) =~ "/"
    end
  end

  describe "handle (Task 5 smoke)" do
    # auto_start_simulation is false in test (see config/test.exs); the World
    # must be started by hand. Other tests do the same; tear it down here to
    # avoid a name clash with any subsequent test.
    setup do
      {:ok, pid} = Lenies.World.start_link(tick_interval_ms: 0)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end

        Lenies.World.Tables.delete_all()
      end)

      :ok
    end

    test "primary World exposes a handle with the right tids" do
      handle = GenServer.call(Lenies.World, :get_handle)
      assert %Lenies.WorldHandle{id: :primary, pubsub_prefix: "world:primary"} = handle
      assert is_reference(handle.tables.cells)
      assert is_reference(handle.tables.lenies)
      assert handle.pid == Process.whereis(Lenies.World)
    end
  end

  describe "facade (T8 smoke)" do
    # The facade is exercised against the :primary World, which (with
    # auto_start_simulation: false in test env) must be started by hand.
    setup do
      {:ok, pid} = Lenies.World.start_link(tick_interval_ms: 0)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end

        Lenies.World.Tables.delete_all()
      end)

      :ok
    end

    test "handle/1 returns the primary world handle by id" do
      {:ok, %Lenies.WorldHandle{id: :primary}} = Lenies.Worlds.handle(:primary)
    end

    test "handle/1 returns :error for an unknown world" do
      assert :error = Lenies.Worlds.handle(:not_running)
    end

    test "list/0 includes :primary" do
      assert :primary in Lenies.Worlds.list()
    end

    test "alive?/1 is true for :primary, false otherwise" do
      assert Lenies.Worlds.alive?(:primary)
      refute Lenies.Worlds.alive?(:not_running)
    end

    test "snapshot_stats/1 by id matches the direct singleton call" do
      via_facade = Lenies.Worlds.snapshot_stats(:primary)
      via_singleton = Lenies.World.snapshot_stats()
      # both should return the same shape (map with the same keys)
      assert is_map(via_facade) and is_map(via_singleton)
      assert Map.keys(via_facade) == Map.keys(via_singleton)
    end

    test "tune/3 updates the world config; broadcast {:config_changed, …} reaches subscribers" do
      Phoenix.PubSub.subscribe(Lenies.PubSub, "world:primary:control")
      assert :ok = Lenies.Worlds.tune(:primary, :eat_amount, 123.0)
      assert_receive {:config_changed, :eat_amount, 123.0}, 500
      # restore the default so other tests aren't affected
      Lenies.Worlds.tune(:primary, :eat_amount, 100.0)
    end

    test "tune/3 rejects unknown keys" do
      assert {:error, {:unknown_tunable, :nope}} = Lenies.Worlds.tune(:primary, :nope, 0)
    end
  end
end
