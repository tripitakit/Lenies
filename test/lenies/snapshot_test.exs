defmodule Lenies.SnapshotTest do
  use ExUnit.Case, async: false

  alias Lenies.{Snapshot, World, Worlds}
  alias Lenies.World.Tables

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "lenies-snapshot-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:lenies, :snapshot_root, root)

    on_exit(fn ->
      case Lenies.WorldTestHelpers.world_pid() do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      Tables.delete_all()
      File.rm_rf!(root)
      Application.delete_env(:lenies, :snapshot_root)
    end)

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    {:ok, root: root}
  end

  # Fetch the current primary handle. The world process is stable across a
  # single test, but the tids it owns can change across tasks; the helper
  # re-fetches on each call rather than caching.
  defp h do
    {:ok, handle} = Lenies.Worlds.handle(:primary)
    handle
  end

  # On-disk directory for snapshot `name` under the :primary world's path.
  defp primary_dir(root, name), do: Path.join([root, "primary", name])

  test "save_snapshot/restore_snapshot round-trip cells by name" do
    [{key, cell}] = :ets.lookup(h().tables.cells, {3, 3})
    :ets.insert(h().tables.cells, {key, %{cell | resource: 88, carcass: 17, lenie_id: "TEST"}})

    :ok = Worlds.save_snapshot(:primary, "default")

    :ets.insert(h().tables.cells, {key, %{cell | resource: 0, carcass: 0, lenie_id: nil}})

    :ok = Worlds.restore_snapshot(:primary, "default")

    [{_, restored}] = :ets.lookup(h().tables.cells, {3, 3})
    assert restored.resource == 88
    assert restored.carcass == 17
    assert restored.lenie_id == "TEST"
  end

  test "save_snapshot/2 writes all 5 tables under <root>/<id_to_path>/<name>", %{root: root} do
    :ok = Worlds.save_snapshot(:primary, "mysnap")

    for table <- Snapshot.tables() do
      path = Path.join(primary_dir(root, "mysnap"), "#{table}.tab")
      assert File.exists?(path), "expected #{path} to exist"
    end
  end

  test "save_snapshot/2 includes color_overrides.tab (T12: 5th table)", %{root: root} do
    :ok = Worlds.save_snapshot(:primary, "withcolors")
    assert File.exists?(Path.join(primary_dir(root, "withcolors"), "color_overrides.tab"))
  end

  test "atomic save leaves no .tab.tmp files behind", %{root: root} do
    :ok = Worlds.save_snapshot(:primary, "atomic")

    dir = primary_dir(root, "atomic")
    tmp_files = Path.wildcard(Path.join(dir, "*.tab.tmp"))
    assert tmp_files == [], "expected no leftover .tmp files, found: #{inspect(tmp_files)}"
  end

  test "restore_snapshot/2 returns {:error, :missing_file} if files don't exist" do
    assert {:error, :missing_file} = Worlds.restore_snapshot(:primary, "does-not-exist")
  end

  describe "invalid names (C1: path traversal)" do
    # "foo\n" is included to guard against PCRE's $ matching before a trailing
    # newline — \A/\z anchors are required to reject it strictly.
    for name <- ["../etc", "foo/bar", "", "a.b", "a b", "foo\n"] do
      @name name

      test "save rejects #{inspect(name)}" do
        assert {:error, :invalid_name} = Worlds.save_snapshot(:primary, @name)
      end

      test "restore rejects #{inspect(name)}" do
        assert {:error, :invalid_name} = Worlds.restore_snapshot(:primary, @name)
      end
    end

    test "traversal name writes nothing outside root", %{root: root} do
      # Resolve where "../etc" would land relative to root/primary if it
      # weren't blocked.
      escaped = Path.expand(Path.join([root, "primary", "../etc"]))
      refute File.exists?(escaped)

      assert {:error, :invalid_name} = Worlds.save_snapshot(:primary, "../etc")

      refute File.exists?(escaped),
             "save with traversal name must not create #{escaped}"
    end
  end

  describe "validate-before-destroy (C2)" do
    test "corrupt file aborts restore and leaves the live world untouched", %{root: root} do
      # Pre-populate a recognizable world state.
      [{key, cell}] = :ets.lookup(h().tables.cells, {5, 5})
      :ets.insert(h().tables.cells, {key, %{cell | resource: 777}})

      # A valid save so all 5 .tab files exist.
      :ok = Worlds.save_snapshot(:primary, "corruptme")

      # Corrupt one .tab file with garbage bytes.
      corrupt_path = Path.join(primary_dir(root, "corruptme"), "history.tab")
      File.write!(corrupt_path, "this is not an ets dump")

      # Mutate the live world AFTER the save so we can detect a sterilize.
      [{_, cell2}] = :ets.lookup(h().tables.cells, {5, 5})
      :ets.insert(h().tables.cells, {key, %{cell2 | resource: 999}})

      result = Worlds.restore_snapshot(:primary, "corruptme")
      assert match?({:error, {:corrupt, :history}}, result)

      # The world was NOT touched: still 999, not sterilized back to default,
      # and not restored to 777.
      [{_, after_cell}] = :ets.lookup(h().tables.cells, {5, 5})
      assert after_cell.resource == 999
    end
  end

  describe "ETS ownership (C2)" do
    test "after restore, World owns the restored tables" do
      :ok = Worlds.save_snapshot(:primary, "owned")
      :ok = Worlds.restore_snapshot(:primary, "owned")

      world = Lenies.WorldTestHelpers.world_pid()

      for table <- Snapshot.tables() do
        tid = Map.fetch!(h().tables, table)

        assert :ets.info(tid, :owner) == world,
               "expected World to own #{table} after restore"
      end
    end
  end

  describe "partial-load guard" do
    test "file2tab failure mid-load returns an error and leaves all 5 tables present",
         %{root: root} do
      # Save a valid snapshot, then corrupt the lenies.tab payload AFTER the
      # 32-byte header so :ets.tabfile_info passes (read-only header check)
      # but :ets.file2tab fails on payload decode.
      :ok = Worlds.save_snapshot(:primary, "partial-swap")
      lenies_tab = Path.join(primary_dir(root, "partial-swap"), "lenies.tab")
      {:ok, bin} = File.read(lenies_tab)
      header = binary_part(bin, 0, min(32, byte_size(bin)))
      corrupt = header <> :binary.copy(<<0xFF>>, 512)
      File.write!(lenies_tab, corrupt)

      result = Worlds.restore_snapshot(:primary, "partial-swap")

      # Whether tabfile_info catches it (returns {:error, {:corrupt, :lenies}})
      # or file2tab catches it mid-load (returns {:error, {:restore_failed,
      # :lenies}}), the important invariant is that all 5 snapshot tables
      # still exist and the World is still functional.
      assert match?({:error, _}, result),
             "expected restore to fail, got: #{inspect(result)}"

      for table <- Snapshot.tables() do
        tid = Map.fetch!(h().tables, table)

        assert :ets.info(tid, :size) != :undefined,
               "expected #{table} to still exist after failed restore"
      end

      # World must still be alive and able to serve requests.
      assert %{cells: cells_count} = World.snapshot_stats()
      assert cells_count > 0, "World should have cells after recovery"
    end
  end
end
