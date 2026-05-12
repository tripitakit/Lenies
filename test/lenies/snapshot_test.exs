defmodule Lenies.SnapshotTest do
  use ExUnit.Case, async: false

  alias Lenies.{Snapshot, World}
  alias Lenies.World.Tables

  setup do
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
      File.rm_rf!("/tmp/lenies-snapshot-test")
    end)

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    File.mkdir_p!("/tmp/lenies-snapshot-test")
    :ok
  end

  test "save_to_disk/1 and restore_from_disk/1 round-trip cells" do
    base = "/tmp/lenies-snapshot-test"

    [{key, cell}] = :ets.lookup(:cells, {3, 3})
    :ets.insert(:cells, {key, %{cell | resource: 88, carcass: 17, lenie_id: "TEST"}})

    :ok = Snapshot.save_to_disk(base)

    :ets.insert(:cells, {key, %{cell | resource: 0, carcass: 0, lenie_id: nil}})

    :ok = Snapshot.restore_from_disk(base)

    [{_, restored}] = :ets.lookup(:cells, {3, 3})
    assert restored.resource == 88
    assert restored.carcass == 17
    assert restored.lenie_id == "TEST"
  end

  test "save_to_disk/1 creates expected files" do
    base = "/tmp/lenies-snapshot-test"
    :ok = Snapshot.save_to_disk(base)

    for table <- [:cells, :lenies, :child_slots, :history] do
      path = Path.join(base, "#{table}.tab")
      assert File.exists?(path), "expected #{path} to exist"
    end
  end

  test "restore_from_disk/1 returns {:error, :missing_file} if files don't exist" do
    base = "/tmp/lenies-snapshot-nonexistent"
    assert {:error, :missing_file} = Snapshot.restore_from_disk(base)
  end
end
