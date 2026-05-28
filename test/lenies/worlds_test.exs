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
      {:ok, _world} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})
      on_exit(fn -> Lenies.WorldTestHelpers.stop_primary() end)
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
      {:ok, _world} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})
      on_exit(fn -> Lenies.WorldTestHelpers.stop_primary() end)
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
      {:ok, _world_pid} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})
      on_exit(fn -> Lenies.WorldTestHelpers.stop_primary() end)

      assert [{_pid, _}] = Registry.lookup(Lenies.Registry, {:lenie_sup, :primary})
    end

    test ":primary's Telemetry is registered under {:telemetry, :primary}" do
      # In test env (auto_start_simulation: false) the Application does not
      # start the :primary world, so spin up the whole sub-tree (which
      # includes Telemetry) via the Worlds facade.
      {:ok, _world} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})
      on_exit(fn -> Lenies.WorldTestHelpers.stop_primary() end)

      assert [{_pid, _}] = Registry.lookup(Lenies.Registry, {:telemetry, :primary})
    end
  end

  describe "snapshot per-world (T12 smoke)" do
    setup do
      {:ok, _world} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})
      on_exit(fn -> Lenies.WorldTestHelpers.stop_primary() end)
      :ok
    end

    @tag :tmp_dir
    test "save/restore round-trip on :primary preserves color_overrides", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      handle = Lenies.Worlds.primary_handle()
      Lenies.SpeciesColor.set_override(handle, "snap-marker", "#abcdef")
      assert "#abcdef" = Lenies.SpeciesColor.override(handle, "snap-marker")

      assert :ok = Lenies.Worlds.save_snapshot(:primary, "t12_smoke")
      assert File.dir?(Path.join([tmp, "primary", "t12_smoke"]))
      assert File.exists?(Path.join([tmp, "primary", "t12_smoke", "color_overrides.tab"]))

      Lenies.SpeciesColor.clear_override(handle, "snap-marker")
      refute Lenies.SpeciesColor.override(handle, "snap-marker")

      assert :ok = Lenies.Worlds.restore_snapshot(:primary, "t12_smoke")
      # The handle's tids are stable across restore — re-fetch defensively
      # so the assertion uses whatever the world reports as current.
      handle = Lenies.Worlds.primary_handle()
      assert "#abcdef" = Lenies.SpeciesColor.override(handle, "snap-marker")

      # cleanup
      Lenies.SpeciesColor.clear_override(handle, "snap-marker")
    end

    @tag :tmp_dir
    test "restore tolerates a legacy 4-table snapshot (missing color_overrides.tab)",
         %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      handle = Lenies.Worlds.primary_handle()

      # Create a snapshot, then delete color_overrides.tab to simulate legacy.
      assert :ok = Lenies.Worlds.save_snapshot(:primary, "t12_legacy")
      legacy_dir = Path.join([tmp, "primary", "t12_legacy"])
      File.rm!(Path.join(legacy_dir, "color_overrides.tab"))

      # Add an override that should be wiped on legacy restore.
      Lenies.SpeciesColor.set_override(handle, "before-restore", "#123456")

      # Restore the legacy snapshot — should succeed, color_overrides becomes empty.
      assert :ok = Lenies.Worlds.restore_snapshot(:primary, "t12_legacy")
      handle = Lenies.Worlds.primary_handle()
      refute Lenies.SpeciesColor.override(handle, "before-restore")
    end
  end

  describe "boot migration (T10 smoke)" do
    setup do
      # auto_start_simulation: false in test env, so spin up :primary via the
      # Worlds facade exactly the same way Application would in production.
      {:ok, _world_pid} = Lenies.WorldTestHelpers.start_primary(%{})
      on_exit(fn -> Lenies.WorldTestHelpers.stop_primary() end)
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

  describe "multi-world isolation (T13 deliverable)" do
    @moduletag :integration

    setup do
      # Stop :primary so these tests get a clean slate (we'll start :a and :b explicitly).
      # The :primary world is restarted in on_exit so the rest of the suite (and the dev
      # server, if running) sees it back.
      :ok = Lenies.Worlds.stop_world(:primary)
      Process.sleep(50)

      on_exit(fn ->
        Lenies.Worlds.stop_world(:a)
        Lenies.Worlds.stop_world(:b)
        Process.sleep(50)

        unless Lenies.Worlds.alive?(:primary) do
          {:ok, _} = Lenies.Worlds.start_world(:primary, %{})
        end
      end)

      :ok
    end

    test "1. lifecycle: start, handle, stop — no residue" do
      assert {:ok, _sup} = Lenies.Worlds.start_world(:a, %{})
      assert Lenies.Worlds.alive?(:a)
      assert {:ok, %Lenies.WorldHandle{id: :a}} = Lenies.Worlds.handle(:a)

      :ok = Lenies.Worlds.stop_world(:a)
      Process.sleep(50)
      refute Lenies.Worlds.alive?(:a)
      assert :error = Lenies.Worlds.handle(:a)
    end

    test "2. two worlds in parallel, disjoint ETS tables and scoped PubSub" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})

      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      # Distinct ETS tids — sets are not shared across worlds.
      refute ha.tables.cells == hb.tables.cells
      refute ha.tables.lenies == hb.tables.lenies
      refute ha.tables.child_slots == hb.tables.child_slots
      refute ha.tables.history == hb.tables.history
      refute ha.tables.color_overrides == hb.tables.color_overrides

      # Subscribe to :b's tick topic; tickers tick at the configured interval.
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{hb.pubsub_prefix}:tick")
      assert_receive {:tick, _}, 1_000

      # Subscribe to BOTH worlds' control topics BEFORE triggering :a's
      # sterilize. If the broadcast leaked into :b's topic (regression), TWO
      # {:sterilized, _} messages would land in the test pid's mailbox and
      # the refute_receive below would fire. Subscribing to only one topic
      # and refuting AFTER assert_receive (the previous version) is
      # trivially true: assert_receive drains the matching message before
      # refute_receive ever runs.
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{ha.pubsub_prefix}:control")
      Phoenix.PubSub.subscribe(Lenies.PubSub, "#{hb.pubsub_prefix}:control")
      :ok = Lenies.Worlds.sterilize(:a)
      assert_receive {:sterilized, _ts}, 1_000
      # A second :sterilized would mean the broadcast also reached :b's topic.
      refute_receive {:sterilized, _}, 300
    end

    test "Species aggregation is per-world: :a's aggregate sees only :a's lenies" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})
      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      # Clear whatever the World seeded so the assertions below reason about
      # exactly the records we insert in this test.
      :ets.delete_all_objects(ha.tables.lenies)
      :ets.delete_all_objects(hb.tables.lenies)

      # Inject one fake snapshot into :a's :lenies table. Same shape used by
      # the SpeciesTest module — direct ETS insert is the standard way to
      # drive Species without spawning a real Lenie process.
      :ets.insert(
        ha.tables.lenies,
        {"lenie-a-1", %{id: "lenie-a-1", codeome_hash: "hash-a", lineage: {nil, 0}}}
      )

      # :b's table stays empty.
      assert :ets.tab2list(hb.tables.lenies) == []

      a_species = Lenies.Species.aggregate(ha)
      b_species = Lenies.Species.aggregate(hb)

      assert Enum.any?(a_species, fn s -> s.hash == "hash-a" end),
             "expected :a's aggregate to contain hash-a; got: #{inspect(a_species)}"

      refute Enum.any?(b_species, fn s -> s.hash == "hash-a" end),
             "expected :b's aggregate NOT to contain hash-a; got: #{inspect(b_species)}"

      # The for_hash/2 sister function is also per-world.
      assert [{"lenie-a-1", _}] = Lenies.Species.for_hash(ha, "hash-a")
      assert [] = Lenies.Species.for_hash(hb, "hash-a")
    end

    test "3. per-world tuning isolated" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{eat_amount: 200.0})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{eat_amount: 50.0})

      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      assert :sys.get_state(ha.pid).config.eat_amount == 200.0
      assert :sys.get_state(hb.pid).config.eat_amount == 50.0

      # tune/3 mutates ONE world only
      assert :ok = Lenies.Worlds.tune(:a, :eat_amount, 999.0)
      assert :sys.get_state(ha.pid).config.eat_amount == 999.0
      assert :sys.get_state(hb.pid).config.eat_amount == 50.0
    end

    test "4. per-world color_overrides — same hash, different colors" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})
      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      Lenies.SpeciesColor.set_override(ha, "deadbeef", "#ff0000")
      Lenies.SpeciesColor.set_override(hb, "deadbeef", "#00ff00")

      assert Lenies.SpeciesColor.override(ha, "deadbeef") == "#ff0000"
      assert Lenies.SpeciesColor.override(hb, "deadbeef") == "#00ff00"
    end

    test "5. crash isolation: killing :a's World does not affect :b" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})
      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      original_b_pid = hb.pid

      # Kill :a's World — the per-world rest_for_one Supervisor restarts it (and
      # LenieSupervisor + Telemetry behind it). New world starts fresh-and-empty.
      Process.exit(ha.pid, :kill)
      Process.sleep(300)

      # :a restarts with a NEW pid and fresh tables.
      {:ok, ha2} = Lenies.Worlds.handle(:a)
      refute ha2.pid == ha.pid
      refute ha2.tables.cells == ha.tables.cells

      # :b is untouched: same pid, same handle.
      {:ok, hb2} = Lenies.Worlds.handle(:b)
      assert hb2.pid == original_b_pid
      assert hb2.tables.cells == hb.tables.cells
    end

    @tag :tmp_dir
    test "6. snapshot per-world — :a save/restore round-trip; :b never touched", %{tmp_dir: tmp} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})
      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      # mark :a with a distinct color override that we can verify after restore
      Lenies.SpeciesColor.set_override(ha, "marker", "#abcdef")
      # mark :b with a different override that should remain untouched throughout
      Lenies.SpeciesColor.set_override(hb, "marker_b", "#fedcba")

      :ok = Lenies.Worlds.save_snapshot(:a, "test_snap")
      assert File.dir?(Path.join([tmp, "a", "test_snap"]))

      Lenies.SpeciesColor.clear_override(ha, "marker")
      refute Lenies.SpeciesColor.override(ha, "marker")

      :ok = Lenies.Worlds.restore_snapshot(:a, "test_snap")
      assert Lenies.SpeciesColor.override(ha, "marker") == "#abcdef"

      # :b's override is untouched
      assert Lenies.SpeciesColor.override(hb, "marker_b") == "#fedcba"
    end

    test "7. Registry tuple keys: same lenie id in two worlds resolves to two distinct entries" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{})

      # Register two distinct values under {:lenie, :a, "X"} and {:lenie, :b, "X"}.
      # Registry.register/3 uses the calling process — so use two Tasks to register
      # under different worlds simultaneously.
      task_a =
        Task.async(fn ->
          Registry.register(Lenies.Registry, {:lenie, :a, "X"}, :a_marker)

          receive do
            :exit -> :ok
          after
            5_000 -> :ok
          end
        end)

      task_b =
        Task.async(fn ->
          Registry.register(Lenies.Registry, {:lenie, :b, "X"}, :b_marker)

          receive do
            :exit -> :ok
          after
            5_000 -> :ok
          end
        end)

      Process.sleep(50)

      [{pid_a, :a_marker}] = Registry.lookup(Lenies.Registry, {:lenie, :a, "X"})
      [{pid_b, :b_marker}] = Registry.lookup(Lenies.Registry, {:lenie, :b, "X"})
      refute pid_a == pid_b

      send(task_a.pid, :exit)
      send(task_b.pid, :exit)
      Task.await(task_a)
      Task.await(task_b)
    end

    test "per-world tuning takes effect on the engine: :eat_amount drives actual eat result" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{eat_amount: 200})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{eat_amount: 50})
      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      # Seed identical cells with abundant resource at the same position in each world.
      # :eat is a direct ETS action that does not require a Lenie process to drive it —
      # it consumes carcass first then resource, returns {:ok, {:ate, energy_gained}}.
      pos = {10, 10}
      :ets.insert(ha.tables.cells, {pos, %Lenies.World.Cell{resource: 1_000}})
      :ets.insert(hb.tables.cells, {pos, %Lenies.World.Cell{resource: 1_000}})

      # Behavioural assertion: the eat result must reflect each world's own
      # :eat_amount tunable. Pre-fix (cfg/2 reads Application.get_env) BOTH calls
      # see the SAME global value — proving the per-world tuning gap.
      assert {:ok, {:ate, eaten_a}} = Lenies.Worlds.action(:a, {:eat, pos})
      assert {:ok, {:ate, eaten_b}} = Lenies.Worlds.action(:b, {:eat, pos})

      assert eaten_a == 200, "expected :a to eat 200 (its eat_amount), got #{eaten_a}"
      assert eaten_b == 50, "expected :b to eat 50 (its eat_amount), got #{eaten_b}"
    end

    test "8. supervision: per-world tree contains World + LenieSupervisor + Telemetry" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{})

      assert [{world_pid, _}] = Registry.lookup(Lenies.Registry, {:world, :a})
      assert [{lenie_sup_pid, _}] = Registry.lookup(Lenies.Registry, {:lenie_sup, :a})
      assert [{telemetry_pid, _}] = Registry.lookup(Lenies.Registry, {:telemetry, :a})

      # All three are distinct processes
      refute world_pid == lenie_sup_pid
      refute world_pid == telemetry_pid
      refute lenie_sup_pid == telemetry_pid

      # World owns the ETS tables; LenieSupervisor and Telemetry don't.
      {:ok, h} = Lenies.Worlds.handle(:a)
      info_cells = :ets.info(h.tables.cells)
      assert info_cells[:owner] == world_pid
    end
  end
end
