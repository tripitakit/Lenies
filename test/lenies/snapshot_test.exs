defmodule Lenies.SnapshotTest do
  use ExUnit.Case, async: false

  alias Lenies.{Snapshot, Worlds}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "lenies-snapshot-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:lenies, :snapshot_root, root)

    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    world_path = Lenies.Worlds.id_to_path(world_id)

    on_exit(fn ->
      Lenies.WorldTestHelpers.stop_test_world(world_id)
      File.rm_rf!(root)
      Application.delete_env(:lenies, :snapshot_root)
    end)

    {:ok, root: root, world_id: world_id, handle: handle, world_path: world_path}
  end

  # Fetch the current world handle. The world process is stable across a
  # single test, but the tids it owns can change across tasks; the helper
  # re-fetches on each call rather than caching.
  defp h(world_id) do
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    handle
  end

  # On-disk directory for snapshot `name` under the test world's path.
  defp world_dir(root, world_path, name), do: Path.join([root, world_path, name])

  test "save_snapshot/restore_snapshot round-trip cells by name", %{world_id: world_id} do
    [{key, cell}] = :ets.lookup(h(world_id).tables.cells, {3, 3})

    :ets.insert(
      h(world_id).tables.cells,
      {key, %{cell | resource: 88, carcass: 17, lenie_id: "TEST"}}
    )

    :ok = Worlds.save_snapshot(world_id, "default")

    :ets.insert(h(world_id).tables.cells, {key, %{cell | resource: 0, carcass: 0, lenie_id: nil}})

    :ok = Worlds.restore_snapshot(world_id, "default")

    [{_, restored}] = :ets.lookup(h(world_id).tables.cells, {3, 3})
    assert restored.resource == 88
    assert restored.carcass == 17
    assert restored.lenie_id == "TEST"
  end

  test "save_snapshot/2 writes all 5 tables under <root>/<id_to_path>/<name>",
       %{root: root, world_id: world_id, world_path: world_path} do
    :ok = Worlds.save_snapshot(world_id, "mysnap")

    for table <- Snapshot.tables() do
      path = Path.join(world_dir(root, world_path, "mysnap"), "#{table}.tab")
      assert File.exists?(path), "expected #{path} to exist"
    end
  end

  test "save_snapshot/2 includes color_overrides.tab (T12: 5th table)",
       %{root: root, world_id: world_id, world_path: world_path} do
    :ok = Worlds.save_snapshot(world_id, "withcolors")
    assert File.exists?(Path.join(world_dir(root, world_path, "withcolors"), "color_overrides.tab"))
  end

  test "atomic save leaves no .tab.tmp files behind",
       %{root: root, world_id: world_id, world_path: world_path} do
    :ok = Worlds.save_snapshot(world_id, "atomic")

    dir = world_dir(root, world_path, "atomic")
    tmp_files = Path.wildcard(Path.join(dir, "*.tab.tmp"))
    assert tmp_files == [], "expected no leftover .tmp files, found: #{inspect(tmp_files)}"
  end

  test "restore_snapshot/2 returns {:error, :missing_file} if files don't exist",
       %{world_id: world_id} do
    assert {:error, :missing_file} = Worlds.restore_snapshot(world_id, "does-not-exist")
  end

  describe "invalid names (C1: path traversal)" do
    # "foo\n" is included to guard against PCRE's $ matching before a trailing
    # newline — \A/\z anchors are required to reject it strictly.
    for name <- ["../etc", "foo/bar", "", "a.b", "a b", "foo\n"] do
      @name name

      test "save rejects #{inspect(name)}", %{world_id: world_id} do
        assert {:error, :invalid_name} = Worlds.save_snapshot(world_id, @name)
      end

      test "restore rejects #{inspect(name)}", %{world_id: world_id} do
        assert {:error, :invalid_name} = Worlds.restore_snapshot(world_id, @name)
      end
    end

    test "traversal name writes nothing outside root",
         %{root: root, world_id: world_id, world_path: world_path} do
      # Resolve where "../etc" would land relative to root/<world_path> if it
      # weren't blocked.
      escaped = Path.expand(Path.join([root, world_path, "../etc"]))
      refute File.exists?(escaped)

      assert {:error, :invalid_name} = Worlds.save_snapshot(world_id, "../etc")

      refute File.exists?(escaped),
             "save with traversal name must not create #{escaped}"
    end
  end

  describe "validate-before-destroy (C2)" do
    test "corrupt file aborts restore and leaves the live world untouched",
         %{root: root, world_id: world_id, world_path: world_path} do
      # Pre-populate a recognizable world state.
      [{key, cell}] = :ets.lookup(h(world_id).tables.cells, {5, 5})
      :ets.insert(h(world_id).tables.cells, {key, %{cell | resource: 777}})

      # A valid save so all 5 .tab files exist.
      :ok = Worlds.save_snapshot(world_id, "corruptme")

      # Corrupt one .tab file with garbage bytes.
      corrupt_path = Path.join(world_dir(root, world_path, "corruptme"), "history.tab")
      File.write!(corrupt_path, "this is not an ets dump")

      # Mutate the live world AFTER the save so we can detect a sterilize.
      [{_, cell2}] = :ets.lookup(h(world_id).tables.cells, {5, 5})
      :ets.insert(h(world_id).tables.cells, {key, %{cell2 | resource: 999}})

      result = Worlds.restore_snapshot(world_id, "corruptme")
      assert match?({:error, {:corrupt, :history}}, result)

      # The world was NOT touched: still 999, not sterilized back to default,
      # and not restored to 777.
      [{_, after_cell}] = :ets.lookup(h(world_id).tables.cells, {5, 5})
      assert after_cell.resource == 999
    end
  end

  describe "ETS ownership (C2)" do
    test "after restore, World owns the restored tables", %{world_id: world_id} do
      :ok = Worlds.save_snapshot(world_id, "owned")
      :ok = Worlds.restore_snapshot(world_id, "owned")

      world = Lenies.WorldTestHelpers.world_pid(world_id)

      for table <- Snapshot.tables() do
        tid = Map.fetch!(h(world_id).tables, table)

        assert :ets.info(tid, :owner) == world,
               "expected World to own #{table} after restore"
      end
    end
  end

  describe "partial-load guard" do
    test "file2tab failure mid-load returns an error and leaves all 5 tables present",
         %{root: root, world_id: world_id, world_path: world_path} do
      # Save a valid snapshot, then corrupt the lenies.tab payload AFTER the
      # 32-byte header so :ets.tabfile_info passes (read-only header check)
      # but :ets.file2tab fails on payload decode.
      :ok = Worlds.save_snapshot(world_id, "partial-swap")
      lenies_tab = Path.join(world_dir(root, world_path, "partial-swap"), "lenies.tab")
      {:ok, bin} = File.read(lenies_tab)
      header = binary_part(bin, 0, min(32, byte_size(bin)))
      corrupt = header <> :binary.copy(<<0xFF>>, 512)
      File.write!(lenies_tab, corrupt)

      result = Worlds.restore_snapshot(world_id, "partial-swap")

      # Whether tabfile_info catches it (returns {:error, {:corrupt, :lenies}})
      # or file2tab catches it mid-load (returns {:error, {:restore_failed,
      # :lenies}}), the important invariant is that all 5 snapshot tables
      # still exist and the World is still functional.
      assert match?({:error, _}, result),
             "expected restore to fail, got: #{inspect(result)}"

      for table <- Snapshot.tables() do
        tid = Map.fetch!(h(world_id).tables, table)

        assert :ets.info(tid, :size) != :undefined,
               "expected #{table} to still exist after failed restore"
      end

      # World must still be alive and able to serve requests.
      assert %{cells: cells_count} = Lenies.Worlds.snapshot_stats(world_id)
      assert cells_count > 0, "World should have cells after recovery"
    end
  end
end
