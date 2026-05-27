defmodule Lenies.WorldReconcileTest do
  @moduledoc """
  Tests for the periodic grid/registry reconciliation sweep (I7).

  The sweep is triggered explicitly via `World.reconcile/0` (synchronous call)
  so tests are deterministic — no real timers needed.
  """
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, World}
  alias Lenies.World.Tables

  # ---- shared setup helpers ----

  defp setup_world(_ctx) do
    on_exit(fn ->
      # Kill any live Lenies via the supervisor first
      case Process.whereis(Lenies.LenieSupervisor) do
        sup_pid when is_pid(sup_pid) ->
          DynamicSupervisor.which_children(sup_pid)
          |> Enum.each(fn {_, child_pid, _, _} ->
            if is_pid(child_pid), do: DynamicSupervisor.terminate_child(sup_pid, child_pid)
          end)

        _ ->
          :ok
      end

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
    end)

    # tick_interval_ms: 0 so no background ticks interfere
    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    :ok
  end

  # Poll until `fun.()` is truthy, or `retries` × 10 ms have elapsed.
  defp wait_until(fun, retries \\ 100) do
    if fun.() do
      :ok
    else
      if retries > 0 do
        Process.sleep(10)
        wait_until(fun, retries - 1)
      else
        :timeout
      end
    end
  end

  # ---- tests ----

  describe "World.reconcile/0" do
    setup :setup_world

    test "brutally-killed Lenie's cell and :lenies record are cleaned up" do
      codeome = Codeome.from_list([:nop_0, :nop_0, :nop_0])
      {:ok, {lenie_id, pos}} = World.spawn_lenie(codeome, energy: 500.0)

      pid = Lenies.Registry.whereis(lenie_id)
      assert is_pid(pid), "Lenie should be alive after spawn"

      # Verify the cell is occupied
      [{_, cell_before}] = :ets.lookup(:cells, pos)
      assert cell_before.lenie_id == lenie_id

      # Brutal kill — skips terminate/2, so no lenie_died cast is sent
      Process.unlink(pid)
      Process.exit(pid, :kill)

      # Wait until the process is truly dead
      :ok = wait_until(fn -> not Process.alive?(pid) end)

      # Wait until Registry auto-purges the entry (Registry ETS is updated
      # asynchronously by the Registry GenServer after the process DOWN)
      :ok = wait_until(fn -> Lenies.Registry.whereis(lenie_id) == nil end)

      # Before reconcile: cell is still marked occupied, :lenies record still exists
      [{_, cell_stale}] = :ets.lookup(:cells, pos)

      assert cell_stale.lenie_id == lenie_id,
             "cell should still be stale before reconcile (this is the bug being fixed)"

      assert :ets.lookup(:lenies, lenie_id) != [],
             ":lenies record should still exist before reconcile"

      # Run the reconcile sweep
      {freed, deleted} = World.reconcile()
      assert freed >= 1, "at least one cell should have been freed"
      assert deleted >= 1, "at least one :lenies record should have been deleted"

      # After reconcile: cell is free, :lenies record is gone
      [{_, cell_after}] = :ets.lookup(:cells, pos)

      assert cell_after.lenie_id == nil,
             "cell should be free after reconcile"

      assert :ets.lookup(:lenies, lenie_id) == [],
             ":lenies record should be gone after reconcile"
    end

    test "live Lenie's cell and :lenies record are left untouched by reconcile" do
      codeome = Codeome.from_list([:nop_0, :nop_0, :nop_0])
      {:ok, {lenie_id, pos}} = World.spawn_lenie(codeome, energy: 500.0)

      pid = Lenies.Registry.whereis(lenie_id)
      assert is_pid(pid)

      # Wait for the Lenie's initial snapshot to appear in :lenies
      :ok = wait_until(fn -> :ets.lookup(:lenies, lenie_id) != [] end)

      # Reconcile should leave the live Lenie completely alone
      World.reconcile()

      [{_, cell_after}] = :ets.lookup(:cells, pos)

      assert cell_after.lenie_id == lenie_id,
             "live Lenie's cell must not be cleared"

      assert :ets.lookup(:lenies, lenie_id) != [],
             "live Lenie's :lenies record must not be deleted"

      # Clean up
      Process.unlink(pid)
      GenServer.stop(pid)
    end

    test "orphaned :lenies record (no cell occupancy, dead id) is deleted" do
      dead_id = "deaddeaddeaddead"

      # Manually plant an orphaned :lenies record — no live pid, no cell
      :ets.insert(:lenies, {dead_id, %{id: dead_id, pos: {5, 5}, energy: 1.0}})

      assert :ets.lookup(:lenies, dead_id) != []

      {_freed, deleted} = World.reconcile()
      assert deleted >= 1

      assert :ets.lookup(:lenies, dead_id) == [],
             "orphaned :lenies record should be deleted"
    end

    test "reconcile/0 returns {0, 0} on a clean world with no Lenies" do
      assert {0, 0} = World.reconcile()
    end
  end
end
