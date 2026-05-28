defmodule Lenies.SnapshotTest do
  use ExUnit.Case, async: false

  alias Lenies.{Snapshot, World}
  alias Lenies.World.Tables

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "lenies-snapshot-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:lenies, :snapshot_root, root)

    on_exit(fn ->
      case Process.whereis(Lenies.World) do
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
  # single test, but its tids change after `:restore_tables` succeeds, so
  # the helper re-fetches on each call rather than caching.
  defp h, do: Lenies.Worlds.primary_handle()

  test "save_to_disk/1 and restore_from_disk/1 round-trip cells by name" do
    [{key, cell}] = :ets.lookup(h().tables.cells, {3, 3})
    :ets.insert(h().tables.cells, {key, %{cell | resource: 88, carcass: 17, lenie_id: "TEST"}})

    :ok = Snapshot.save_to_disk("default")

    :ets.insert(h().tables.cells, {key, %{cell | resource: 0, carcass: 0, lenie_id: nil}})

    :ok = Snapshot.restore_from_disk("default")

    [{_, restored}] = :ets.lookup(h().tables.cells, {3, 3})
    assert restored.resource == 88
    assert restored.carcass == 17
    assert restored.lenie_id == "TEST"
  end

  test "save_to_disk/1 creates expected files under root/name", %{root: root} do
    :ok = Snapshot.save_to_disk("mysnap")

    for table <- Snapshot.tables() do
      path = Path.join([root, "mysnap", "#{table}.tab"])
      assert File.exists?(path), "expected #{path} to exist"
    end
  end

  test "atomic save leaves no .tab.tmp files behind", %{root: root} do
    :ok = Snapshot.save_to_disk("atomic")

    dir = Path.join(root, "atomic")
    tmp_files = Path.wildcard(Path.join(dir, "*.tab.tmp"))
    assert tmp_files == [], "expected no leftover .tmp files, found: #{inspect(tmp_files)}"
  end

  test "restore_from_disk/1 returns {:error, :missing_file} if files don't exist" do
    assert {:error, :missing_file} = Snapshot.restore_from_disk("does-not-exist")
  end

  describe "invalid names (C1: path traversal)" do
    # "foo\n" is included to guard against PCRE's $ matching before a trailing
    # newline — \A/\z anchors are required to reject it strictly.
    for name <- ["../etc", "foo/bar", "", "a.b", "a b", "foo\n"] do
      @name name

      test "save rejects #{inspect(name)}" do
        assert {:error, :invalid_name} = Snapshot.save_to_disk(@name)
      end

      test "restore rejects #{inspect(name)}" do
        assert {:error, :invalid_name} = Snapshot.restore_from_disk(@name)
      end
    end

    test "traversal name writes nothing outside root", %{root: root} do
      # Resolve where "../etc" would land relative to root if it weren't blocked.
      escaped = Path.expand(Path.join(root, "../etc"))
      refute File.exists?(escaped)

      assert {:error, :invalid_name} = Snapshot.save_to_disk("../etc")

      refute File.exists?(escaped),
             "save with traversal name must not create #{escaped}"
    end
  end

  describe "validate-before-destroy (C2)" do
    test "corrupt file aborts restore and leaves the live world untouched", %{root: root} do
      # Pre-populate a recognizable world state.
      [{key, cell}] = :ets.lookup(h().tables.cells, {5, 5})
      :ets.insert(h().tables.cells, {key, %{cell | resource: 777}})

      # A valid save so all 4 .tab files exist.
      :ok = Snapshot.save_to_disk("corruptme")

      # Corrupt one .tab file with garbage bytes.
      corrupt_path = Path.join([root, "corruptme", "history.tab"])
      File.write!(corrupt_path, "this is not an ets dump")

      # Mutate the live world AFTER the save so we can detect a sterilize.
      [{_, cell2}] = :ets.lookup(h().tables.cells, {5, 5})
      :ets.insert(h().tables.cells, {key, %{cell2 | resource: 999}})

      result = Snapshot.restore_from_disk("corruptme")
      assert match?({:error, {:corrupt, :history}}, result)

      # The world was NOT touched: still 999, not sterilized back to default,
      # and not restored to 777.
      [{_, after_cell}] = :ets.lookup(h().tables.cells, {5, 5})
      assert after_cell.resource == 999
    end
  end

  describe "ETS ownership (C2)" do
    test "after restore, World owns the restored tables" do
      :ok = Snapshot.save_to_disk("owned")
      :ok = Snapshot.restore_from_disk("owned")

      world = Process.whereis(Lenies.World)

      for table <- [:cells, :lenies, :child_slots, :history] do
        tid = Map.fetch!(h().tables, table)

        assert :ets.info(tid, :owner) == world,
               "expected World to own #{table} after restore"
      end
    end
  end

  describe "partial-swap guard (FIX 1)" do
    test "file2tab failure mid-loop leaves all 4 tables present and World usable", %{root: root} do
      # Save a valid snapshot so 3 of the 4 .tab files are well-formed.
      :ok = Snapshot.save_to_disk("partial-swap")
      dir = Path.join(root, "partial-swap")

      # Corrupt the lenies.tab file AFTER the header so that
      # :ets.tabfile_info/1 (read-only header check) succeeds but
      # :ets.file2tab/1 fails when it tries to decode the payload.
      # We do this by: reading the file, keeping the first 32 bytes
      # (Erlang DETS/ETS file header), then replacing the rest with garbage.
      lenies_tab = Path.join(dir, "lenies.tab")
      {:ok, bin} = File.read(lenies_tab)
      # Overwrite everything after the 32-byte header with garbage bytes.
      # This passes tabfile_info (which only inspects the header) but
      # causes file2tab to fail on payload decoding.
      header = binary_part(bin, 0, min(32, byte_size(bin)))
      corrupt = header <> :binary.copy(<<0xFF>>, 512)
      File.write!(lenies_tab, corrupt)

      # The validation pass (tabfile_info) should still pass for this file
      # because we kept the header intact (or file2tab might reject it — either
      # outcome exercises the recovery path, which is what we're testing).
      result = Snapshot.restore_from_disk("partial-swap")

      # Whether tabfile_info catches it (returns {:error, {:corrupt, :lenies}})
      # or file2tab catches it mid-loop (returns {:error, {:restore_failed, _}}),
      # the important invariant is that ALL 4 snapshot tables still exist and
      # World is still functional.
      assert match?({:error, _}, result),
             "expected restore to fail, got: #{inspect(result)}"

      # All 4 tables must still be present and accessible — no raised ArgumentError.
      for table <- [:cells, :lenies, :child_slots, :history] do
        tid = Map.fetch!(h().tables, table)

        assert :ets.info(tid, :size) != :undefined,
               "expected #{table} to still exist after failed restore"
      end

      # World must still be alive and able to serve requests.
      assert %{cells: cells_count} = World.snapshot_stats()
      assert cells_count > 0, "World should have cells after recovery"
    end

    test "after a mid-loop failure, World.restore_tables/1 with a missing file returns error and keeps world consistent",
         %{root: root} do
      # Save a valid snapshot, then remove one .tab file AFTER the save so
      # restore_tables is called with a dir containing a missing file.
      # This exercises a different failure mode: file2tab gets called and
      # immediately returns an error (file not found).
      :ok = Snapshot.save_to_disk("missing-one")
      dir = Path.join(root, "missing-one")

      # Remove cells.tab to force file2tab to fail on the very first table.
      File.rm!(Path.join(dir, "cells.tab"))

      # Call restore_tables directly (bypassing the tabfile_info pre-check in
      # restore_from_disk) to exercise the recovery path inside the handler.
      World.sterilize()
      result = World.restore_tables(dir)

      assert match?({:error, {:restore_failed, :cells}}, result),
             "expected {:error, {:restore_failed, :cells}}, got: #{inspect(result)}"

      # All 4 tables must exist (recovery recreated the missing ones empty).
      for table <- [:cells, :lenies, :child_slots, :history] do
        tid = Map.fetch!(h().tables, table)

        assert :ets.info(tid, :size) != :undefined,
               "expected #{table} to still exist after recovery"
      end

      # World remains functional.
      assert %{cells: _} = World.snapshot_stats()
    end
  end
end
