defmodule Lenies.SnapshotRespawnTest do
  @moduledoc """
  End-to-end test for the snapshot save → stop world → restart world →
  restore snapshot → respawn Lenies flow.

  Mirrors what the user does in production:
  1. Spawn N Lenies (each calls maybe_write_snapshot in init, embedding
     :codeome in the ETS record AND populating :species_codeomes cache).
  2. Save a snapshot. The codeome sidecar is also written.
  3. Stop the world (simulates BEAM restart partially — at the very
     least it kills the LenieSupervisor + all Lenie pids, leaving stale
     :pid fields in the snapshot when reloaded). We also wipe
     :species_codeomes to simulate a full BEAM restart (the global ETS
     cache vanishes).
  4. Start a fresh world with the same id.
  5. Restore the snapshot. The fix should:
     - Load the codeome sidecar back into :species_codeomes.
     - Iterate ETS.lenies and respawn a Lenie GenServer for each entry.
  6. After restore, every Lenie ETS record's :pid must point to a live
     process, and Species.aggregate must return the species.
  """

  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Snapshot, Species, Worlds}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "lenies-snapshot-respawn-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:lenies, :snapshot_root, root)

    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    :ok = Lenies.Worlds.pause(world_id)

    on_exit(fn ->
      Lenies.WorldTestHelpers.stop_test_world(world_id)
      File.rm_rf!(root)
      Application.delete_env(:lenies, :snapshot_root)
    end)

    {:ok, root: root, world_id: world_id}
  end

  defp h(world_id) do
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    handle
  end

  defp spawn_n(world_id, n, codeome) do
    for _ <- 1..n do
      {:ok, _} = Worlds.spawn_lenie(world_id, codeome, energy: 500.0)
    end
  end

  test "restore respawns Lenie GenServers and populates Species", %{world_id: world_id} do
    # 1. Spawn 5 Lenies with the same codeome (single-species world).
    opcodes = [:nop_0, :nop_1, :push0, :move, :turn_left]
    codeome = Codeome.from_list(opcodes)
    spawn_n(world_id, 5, codeome)

    # Confirm pre-save state: 5 records, all with live pid + :codeome embedded
    # as a PLAIN LIST (post-fix). Earlier versions stored the %Codeome{} struct
    # which broke pattern matching in codeome_from_snap/1.
    pre_save = :ets.tab2list(h(world_id).tables.lenies)
    assert length(pre_save) == 5
    Enum.each(pre_save, fn {_id, snap} ->
      assert is_pid(snap.pid) and Process.alive?(snap.pid),
             "pre-save pid is not alive: #{inspect(snap.pid)}"
      assert is_list(snap.codeome) and snap.codeome == opcodes,
             "pre-save :codeome must be a plain list, got: #{inspect(snap[:codeome])}"
    end)

    # 2. Save snapshot.
    :ok = Worlds.save_snapshot(world_id, "alpha")

    # 2b. Sidecar should be on disk.
    snap_dir = Path.join([Snapshot.snapshot_root(), Worlds.id_to_path(world_id), "alpha"])
    sidecar = Path.join(snap_dir, "species_codeomes.bin")
    assert File.exists?(sidecar), "sidecar missing: #{sidecar}"

    # 3. Stop the world AND wipe the global :species_codeomes cache —
    #    this simulates a full BEAM restart, the harshest test of the
    #    sidecar-based recovery path.
    Lenies.WorldTestHelpers.stop_test_world(world_id)
    :ets.delete_all_objects(:species_codeomes)
    assert :ets.tab2list(:species_codeomes) == []

    # 4. Start a fresh world with the same id (mimics what
    #    `iex -S mix phx.server` does on the user's machine).
    {:ok, ^world_id} = Lenies.WorldTestHelpers.start_test_world(as: world_id, tick_interval_ms: 0)
    :ok = Worlds.pause(world_id)

    # Sanity: fresh world has zero Lenies and zero pre-existing children
    # under the LenieSupervisor.
    assert :ets.tab2list(h(world_id).tables.lenies) == []
    sup_pid = Lenies.WorldTestHelpers.lenie_sup_pid(world_id)
    assert DynamicSupervisor.which_children(sup_pid) == []

    # 5. Restore the snapshot.
    :ok = Worlds.restore_snapshot(world_id, "alpha")

    # 6. Post-restore assertions.
    post = :ets.tab2list(h(world_id).tables.lenies)

    assert length(post) == 5,
           "expected 5 Lenies after restore, got #{length(post)}: #{inspect(post)}"

    Enum.each(post, fn {id, snap} ->
      pid = snap.pid

      assert is_pid(pid),
             "post-restore Lenie #{inspect(id)} has non-pid :pid field: #{inspect(pid)}"

      assert Process.alive?(pid),
             "post-restore Lenie #{inspect(id)} pid #{inspect(pid)} is NOT alive — " <>
               "respawn skipped or the GenServer crashed in init"
    end)

    # And the LenieSupervisor should have 5 live children.
    sup_pid = Lenies.WorldTestHelpers.lenie_sup_pid(world_id)
    children = DynamicSupervisor.which_children(sup_pid)

    assert length(children) == 5,
           "expected 5 supervisor children after restore, got #{length(children)}"

    # Species.aggregate must return the species — Population field on the UI
    # comes from this; an empty list is exactly what the user reported.
    species = Species.aggregate(h(world_id))

    assert length(species) == 1,
           "expected 1 species after restore, got #{length(species)}: #{inspect(species)}"

    [s] = species
    assert s.population == 5

    # Telemetry must hold a fresh history entry seeded from the
    # :restored payload, so a paused world post-restore still shows the
    # correct Population/Resource/Carcass on the dashboard. Without
    # this, :latest stays nil and the header renders fallback zeros.
    #
    # PubSub delivery to Telemetry is async — give it a moment to
    # process the broadcast. Telemetry runs as a per-world singleton;
    # we wait via a brief retry loop (cap 200ms).
    history =
      Enum.reduce_while(1..20, [], fn _, _ ->
        case Lenies.Telemetry.history(world_id, :last_n, 1) do
          [_ | _] = h -> {:halt, h}
          _ -> Process.sleep(10) ; {:cont, []}
        end
      end)

    assert [latest] = history,
           "Telemetry.history empty after restore — :restored payload didn't seed an entry"

    assert latest.population == 5,
           "Telemetry latest.population != 5 after restore: #{inspect(latest)}"

    assert latest.tick == 0,
           "Telemetry latest.tick should be the world's current tick_count (0 for a paused fresh-world test), got: #{inspect(latest.tick)}"
  end
end
