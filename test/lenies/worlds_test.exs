defmodule Lenies.WorldsTest do
  # Tests in this module bring up their own isolated test worlds; the module
  # cannot be async because it manipulates global ETS / Registry state.
  use ExUnit.Case, async: false

  describe "id_to_path/1" do
    test "atom world id renders as the atom name" do
      assert Lenies.Worlds.id_to_path(:arena) == "arena"
      assert Lenies.Worlds.id_to_path(:other) == "other"
    end

    test "tuple {atom, integer} renders as 'atom-integer'" do
      assert Lenies.Worlds.id_to_path({:sandbox, 42}) == "sandbox-42"
    end

    test "is filesystem-safe (no slashes or dots)" do
      refute Lenies.Worlds.id_to_path(:arena) =~ "/"
      refute Lenies.Worlds.id_to_path({:sandbox, 42}) =~ "/"
    end
  end

  describe "handle (Task 5 smoke)" do
    setup do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
      {:ok, world_id: world_id}
    end

    test "test World exposes a handle with the right tids", %{world_id: world_id} do
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      assert %Lenies.WorldHandle{id: ^world_id} = handle
      assert handle.pubsub_prefix == "world:" <> Lenies.Worlds.id_to_path(world_id)
      assert is_reference(handle.tables.cells)
      assert is_reference(handle.tables.lenies)
      assert handle.pid == Lenies.WorldTestHelpers.world_pid(world_id)
    end
  end

  describe "facade (T8 smoke)" do
    setup do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
      {:ok, world_id: world_id}
    end

    test "handle/1 returns the test world handle by id", %{world_id: world_id} do
      {:ok, %Lenies.WorldHandle{id: ^world_id}} = Lenies.Worlds.handle(world_id)
    end

    test "handle/1 returns :error for an unknown world" do
      assert :error = Lenies.Worlds.handle(:not_running)
    end

    test "list/0 includes the test world", %{world_id: world_id} do
      assert world_id in Lenies.Worlds.list()
    end

    test "alive?/1 is true for the test world, false otherwise", %{world_id: world_id} do
      assert Lenies.Worlds.alive?(world_id)
      refute Lenies.Worlds.alive?(:not_running)
    end

    test "snapshot_stats/1 returns a map with the expected keys", %{world_id: world_id} do
      stats = Lenies.Worlds.snapshot_stats(world_id)
      assert is_map(stats)
      assert Map.has_key?(stats, :cells)
      assert Map.has_key?(stats, :population)
      assert Map.has_key?(stats, :total_resource)
      assert Map.has_key?(stats, :total_carcass)
      assert Map.has_key?(stats, :tick_count)
    end

    test "tune/3 updates the world config; broadcast {:config_changed, …} reaches subscribers",
         %{world_id: world_id} do
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      Phoenix.PubSub.subscribe(Lenies.PubSub, handle.pubsub_prefix <> ":control")
      assert :ok = Lenies.Worlds.tune(world_id, :eat_amount, 123.0)
      assert_receive {:config_changed, :eat_amount, 123.0}, 500
      # restore the default so other tests aren't affected
      Lenies.Worlds.tune(world_id, :eat_amount, 100.0)
    end

    test "tune/3 rejects unknown keys", %{world_id: world_id} do
      assert {:error, {:unknown_tunable, :nope}} = Lenies.Worlds.tune(world_id, :nope, 0)
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
      assert {:via, Registry, {Lenies.Registry, {:lenie_sup, :some_world}}} =
               Lenies.LenieSupervisor.via(:some_world)
    end

    test "Lenies.Telemetry.via/1 returns a Registry via-tuple" do
      assert {:via, Registry, {Lenies.Registry, {:telemetry, :some_world}}} =
               Lenies.Telemetry.via(:some_world)
    end

    test "test world's LenieSupervisor is registered under {:lenie_sup, world_id}" do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

      assert [{_pid, _}] = Registry.lookup(Lenies.Registry, {:lenie_sup, world_id})
    end

    test "test world's Telemetry is registered under {:telemetry, world_id}" do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

      assert [{_pid, _}] = Registry.lookup(Lenies.Registry, {:telemetry, world_id})
    end
  end

  describe "snapshot per-world (T12 smoke)" do
    setup do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
      {:ok, world_id: world_id}
    end

    @tag :tmp_dir
    test "save/restore round-trip on test world preserves color_overrides",
         %{tmp_dir: tmp, world_id: world_id} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      {:ok, handle} = Lenies.Worlds.handle(world_id)
      Lenies.SpeciesColor.set_override(handle, "snap-marker", "#abcdef")
      assert "#abcdef" = Lenies.SpeciesColor.override(handle, "snap-marker")

      world_path = Lenies.Worlds.id_to_path(world_id)

      assert :ok = Lenies.Worlds.save_snapshot(world_id, "t12_smoke")
      assert File.dir?(Path.join([tmp, world_path, "t12_smoke"]))
      assert File.exists?(Path.join([tmp, world_path, "t12_smoke", "color_overrides.tab"]))

      Lenies.SpeciesColor.clear_override(handle, "snap-marker")
      refute Lenies.SpeciesColor.override(handle, "snap-marker")

      assert :ok = Lenies.Worlds.restore_snapshot(world_id, "t12_smoke")
      # The handle's tids are stable across restore — re-fetch defensively
      # so the assertion uses whatever the world reports as current.
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      assert "#abcdef" = Lenies.SpeciesColor.override(handle, "snap-marker")

      # cleanup
      Lenies.SpeciesColor.clear_override(handle, "snap-marker")
    end

    @tag :tmp_dir
    test "restore tolerates a legacy 4-table snapshot (missing color_overrides.tab)",
         %{tmp_dir: tmp, world_id: world_id} do
      Application.put_env(:lenies, :snapshot_root, tmp)
      on_exit(fn -> Application.delete_env(:lenies, :snapshot_root) end)

      {:ok, handle} = Lenies.Worlds.handle(world_id)
      world_path = Lenies.Worlds.id_to_path(world_id)

      # Create a snapshot, then delete color_overrides.tab to simulate legacy.
      assert :ok = Lenies.Worlds.save_snapshot(world_id, "t12_legacy")
      legacy_dir = Path.join([tmp, world_path, "t12_legacy"])
      File.rm!(Path.join(legacy_dir, "color_overrides.tab"))

      # Add an override that should be wiped on legacy restore.
      Lenies.SpeciesColor.set_override(handle, "before-restore", "#123456")

      # Restore the legacy snapshot — should succeed, color_overrides becomes empty.
      assert :ok = Lenies.Worlds.restore_snapshot(world_id, "t12_legacy")
      {:ok, handle} = Lenies.Worlds.handle(world_id)
      refute Lenies.SpeciesColor.override(handle, "before-restore")
    end
  end

  describe "boot migration (T10 smoke)" do
    setup do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(%{})
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
      {:ok, world_id: world_id}
    end

    test "test world is registered via Lenies.Registry, not the global atom",
         %{world_id: world_id} do
      # The global atom name is gone.
      assert is_nil(Process.whereis(Lenies.World))
      # Registry has it.
      assert [{_pid, _}] = Registry.lookup(Lenies.Registry, {:world, world_id})
    end

    test "test world's LenieSupervisor/Telemetry no longer have global names",
         %{world_id: world_id} do
      assert is_nil(Process.whereis(Lenies.LenieSupervisor))
      assert is_nil(Process.whereis(Lenies.Telemetry))
      assert [{_, _}] = Registry.lookup(Lenies.Registry, {:lenie_sup, world_id})
      assert [{_, _}] = Registry.lookup(Lenies.Registry, {:telemetry, world_id})
    end

    test "test world's supervisor is under Lenies.Worlds.Supervisor",
         %{world_id: world_id} do
      assert [{sup_pid, _}] = Registry.lookup(Lenies.Registry, {:world_sup, world_id})

      assert Enum.any?(DynamicSupervisor.which_children(Lenies.Worlds.Supervisor), fn
               {_, ^sup_pid, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "multi-world isolation (T13 deliverable)" do
    @moduletag :integration

    setup do
      on_exit(fn ->
        Lenies.Worlds.stop_world(:a)
        Lenies.Worlds.stop_world(:b)
        Process.sleep(50)
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
      assert_receive {:tick, _, _}, 1_000

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

    test "per-world tuning takes effect on the engine: :eat_amount sets the per-cell resource cap" do
      {:ok, _} = Lenies.Worlds.start_world(:a, %{eat_amount: 200})
      {:ok, _} = Lenies.Worlds.start_world(:b, %{eat_amount: 50})
      {:ok, ha} = Lenies.Worlds.handle(:a)
      {:ok, hb} = Lenies.Worlds.handle(:b)

      # eat now empties the whole cell, so eat_amount no longer drives the bite.
      # What it drives per-world is the per-cell resource CAP = 3 × eat_amount.
      # Seed a cell ABOVE both caps in each world; the field-relaxation sweep must
      # clamp each world's cell toward its OWN cap. If :b wrongly used :a's
      # eat_amount, its cell could exceed 150 — so cb ≤ 150 proves per-world tuning
      # reaches the engine.
      pos = {10, 10}
      :ets.insert(ha.tables.cells, {pos, %Lenies.World.Cell{resource: 2_000}})
      :ets.insert(hb.tables.cells, {pos, %Lenies.World.Cell{resource: 2_000}})

      # Relaxation is geometric (~RELAX_RATE/sweep, every 5 ticks), so allow
      # enough ticks for each cell to converge from 2000 down to its target
      # (≤ cap) — even a desert target (~0) clears its cap within ~16 sweeps.
      for _ <- 1..250 do
        Lenies.Worlds.tick_now(:a)
        Lenies.Worlds.tick_now(:b)
      end

      [{_, ca}] = :ets.lookup(ha.tables.cells, pos)
      [{_, cb}] = :ets.lookup(hb.tables.cells, pos)

      assert ca.resource <= 3 * 200, "world :a must clamp to its cap 600, got #{ca.resource}"
      assert cb.resource <= 3 * 50, "world :b must clamp to its cap 150, got #{cb.resource}"
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
