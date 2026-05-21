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

  test "save_to_disk/1 and restore_from_disk/1 round-trip cells by name" do
    [{key, cell}] = :ets.lookup(:cells, {3, 3})
    :ets.insert(:cells, {key, %{cell | resource: 88, carcass: 17, lenie_id: "TEST"}})

    :ok = Snapshot.save_to_disk("default")

    :ets.insert(:cells, {key, %{cell | resource: 0, carcass: 0, lenie_id: nil}})

    :ok = Snapshot.restore_from_disk("default")

    [{_, restored}] = :ets.lookup(:cells, {3, 3})
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
    for name <- ["../etc", "foo/bar", "", "a.b", "a b"] do
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
      [{key, cell}] = :ets.lookup(:cells, {5, 5})
      :ets.insert(:cells, {key, %{cell | resource: 777}})

      # A valid save so all 4 .tab files exist.
      :ok = Snapshot.save_to_disk("corruptme")

      # Corrupt one .tab file with garbage bytes.
      corrupt_path = Path.join([root, "corruptme", "history.tab"])
      File.write!(corrupt_path, "this is not an ets dump")

      # Mutate the live world AFTER the save so we can detect a sterilize.
      [{_, cell2}] = :ets.lookup(:cells, {5, 5})
      :ets.insert(:cells, {key, %{cell2 | resource: 999}})

      result = Snapshot.restore_from_disk("corruptme")
      assert match?({:error, {:corrupt, :history}}, result)

      # The world was NOT touched: still 999, not sterilized back to default,
      # and not restored to 777.
      [{_, after_cell}] = :ets.lookup(:cells, {5, 5})
      assert after_cell.resource == 999
    end
  end

  describe "ETS ownership (C2)" do
    test "after restore, World owns the restored tables" do
      :ok = Snapshot.save_to_disk("owned")
      :ok = Snapshot.restore_from_disk("owned")

      world = Process.whereis(Lenies.World)

      for table <- Snapshot.tables() do
        assert :ets.info(table, :owner) == world,
               "expected World to own #{table} after restore"
      end
    end
  end
end
