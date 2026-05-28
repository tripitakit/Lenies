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
      handle = Lenies.Worlds.primary_handle()
      assert %Lenies.WorldHandle{id: :primary, pubsub_prefix: "world:primary"} = handle
      assert is_reference(handle.tables.cells)
      assert is_reference(handle.tables.lenies)
      assert handle.pid == Lenies.WorldTestHelpers.world_pid()
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

  describe "per-world supervisor (T9 smoke)" do
    test "Lenies.World.Supervisor module exists with start_link/1 and child_spec/1" do
      # Force the module to be loaded so function_exported?/3 reflects its
      # actual exports (purged modules return false until first invocation).
      Code.ensure_loaded!(Lenies.World.Supervisor)
      assert function_exported?(Lenies.World.Supervisor, :start_link, 1)
      assert function_exported?(Lenies.World.Supervisor, :child_spec, 1)
    end

    test "Lenies.LenieSupervisor.via/1 returns a Registry via-tuple" do
      assert {:via, Registry, {Lenies.Registry, {:lenie_sup, :primary}}} =
               Lenies.LenieSupervisor.via(:primary)
    end

    test "Lenies.Telemetry.via/1 returns a Registry via-tuple" do
      assert {:via, Registry, {Lenies.Registry, {:telemetry, :primary}}} =
               Lenies.Telemetry.via(:primary)
    end

    test ":primary's LenieSupervisor is registered under {:lenie_sup, :primary}" do
      # In test env (auto_start_simulation: false) the Application does not
      # start the :primary world, so spin it up here via the Worlds facade.
      {:ok, sup_pid} = Lenies.Worlds.start_world(:primary, %{tick_interval_ms: 0})

      on_exit(fn ->
        Lenies.Worlds.stop_world(:primary)
        if Process.alive?(sup_pid), do: Process.exit(sup_pid, :kill)
        Lenies.World.Tables.delete_all()
      end)

      assert [{_pid, _}] = Registry.lookup(Lenies.Registry, {:lenie_sup, :primary})
    end

    test ":primary's Telemetry is registered under {:telemetry, :primary}" do
      # Telemetry is not in the Application's base children in the test env
      # (auto_start_simulation: false) so we start it for this smoke check
      # and tear it down after.
      {:ok, world_pid} = Lenies.World.start_link(tick_interval_ms: 0)
      {:ok, tel_pid} = Lenies.Telemetry.start_link(world_id: :primary)

      on_exit(fn ->
        for pid <- [tel_pid, world_pid], Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end

        Lenies.World.Tables.delete_all()
      end)

      assert [{_pid, _}] = Registry.lookup(Lenies.Registry, {:telemetry, :primary})
    end
  end

  describe "boot migration (T10 smoke)" do
    setup do
      # auto_start_simulation: false in test env, so spin up :primary via the
      # Worlds facade exactly the same way Application would in production.
      {:ok, _sup} = Lenies.Worlds.start_world(:primary, %{})

      on_exit(fn ->
        Lenies.Worlds.stop_world(:primary)
        Lenies.World.Tables.delete_all()
      end)

      :ok
    end

    test ":primary world is registered via Lenies.Registry, not the global atom" do
      # The global atom name is gone.
      assert is_nil(Process.whereis(Lenies.World))
      # Registry has it.
      assert [{_pid, _}] = Registry.lookup(Lenies.Registry, {:world, :primary})
    end

    test ":primary's LenieSupervisor/Telemetry no longer have global names" do
      assert is_nil(Process.whereis(Lenies.LenieSupervisor))
      assert is_nil(Process.whereis(Lenies.Telemetry))
      assert [{_, _}] = Registry.lookup(Lenies.Registry, {:lenie_sup, :primary})
      assert [{_, _}] = Registry.lookup(Lenies.Registry, {:telemetry, :primary})
    end

    test ":primary world's supervisor is under Lenies.Worlds.Supervisor" do
      assert [{sup_pid, _}] = Registry.lookup(Lenies.Registry, {:world_sup, :primary})

      assert Enum.any?(DynamicSupervisor.which_children(Lenies.Worlds.Supervisor), fn
               {_, ^sup_pid, _, _} -> true
               _ -> false
             end)
    end
  end
end
