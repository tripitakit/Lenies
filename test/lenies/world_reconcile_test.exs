defmodule Lenies.WorldReconcileTest do
  @moduledoc """
  Tests for the periodic grid/registry reconciliation sweep (I7).

  The sweep is triggered explicitly via `Lenies.Worlds.reconcile/1` (synchronous call)
  so tests are deterministic — no real timers needed.
  """
  use ExUnit.Case, async: false

  alias Lenies.Codeome

  # ---- shared setup helpers ----

  defp setup_world(_ctx) do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world()

    on_exit(fn ->
      # Kill any live Lenies via the supervisor first
      case Lenies.WorldTestHelpers.lenie_sup_pid(world_id) do
        sup_pid when is_pid(sup_pid) ->
          DynamicSupervisor.which_children(sup_pid)
          |> Enum.each(fn {_, child_pid, _, _} ->
            if is_pid(child_pid), do: DynamicSupervisor.terminate_child(sup_pid, child_pid)
          end)

        _ ->
          :ok
      end

      Lenies.WorldTestHelpers.stop_test_world(world_id)
    end)

    {:ok, world_id: world_id}
  end

  # Look up a Lenie by id via the OTP Registry. Returns the pid or nil.
  defp whereis(world_id, id) do
    case Registry.lookup(Lenies.Registry, {:lenie, world_id, id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
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

  describe "Worlds.reconcile/1" do
    setup :setup_world

    test "brutally-killed Lenie's cell and :lenies record are cleaned up",
         %{world_id: world_id} do
      codeome = Codeome.from_list([:nop_0, :nop_0, :nop_0])
      {:ok, {lenie_id, pos}} = Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0)

      pid = whereis(world_id, lenie_id)
      assert is_pid(pid), "Lenie should be alive after spawn"

      # Verify the cell is occupied
      [{_, cell_before}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), pos)
      assert cell_before.lenie_id == lenie_id

      # Brutal kill — skips terminate/2, so no lenie_died cast is sent
      Process.unlink(pid)
      Process.exit(pid, :kill)

      # Wait until the process is truly dead
      :ok = wait_until(fn -> not Process.alive?(pid) end)

      # Wait until Registry auto-purges the entry (Registry ETS is updated
      # asynchronously by the Registry GenServer after the process DOWN)
      :ok = wait_until(fn -> whereis(world_id, lenie_id) == nil end)

      # Before reconcile: cell is still marked occupied, :lenies record still exists
      [{_, cell_stale}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), pos)

      assert cell_stale.lenie_id == lenie_id,
             "cell should still be stale before reconcile (this is the bug being fixed)"

      assert :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), lenie_id) != [],
             ":lenies record should still exist before reconcile"

      # Run the reconcile sweep
      {freed, deleted} = Lenies.Worlds.reconcile(world_id)
      assert freed >= 1, "at least one cell should have been freed"
      assert deleted >= 1, "at least one :lenies record should have been deleted"

      # After reconcile: cell is free, :lenies record is gone
      [{_, cell_after}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), pos)

      assert cell_after.lenie_id == nil,
             "cell should be free after reconcile"

      assert :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), lenie_id) == [],
             ":lenies record should be gone after reconcile"
    end

    test "live Lenie's cell and :lenies record are left untouched by reconcile",
         %{world_id: world_id} do
      codeome = Codeome.from_list([:nop_0, :nop_0, :nop_0])
      {:ok, {lenie_id, pos}} = Lenies.Worlds.spawn_lenie(world_id, codeome, energy: 500.0)

      pid = whereis(world_id, lenie_id)
      assert is_pid(pid)

      # Wait for the Lenie's initial snapshot to appear in :lenies
      :ok =
        wait_until(fn ->
          :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), lenie_id) != []
        end)

      # Reconcile should leave the live Lenie completely alone
      Lenies.Worlds.reconcile(world_id)

      [{_, cell_after}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), pos)

      assert cell_after.lenie_id == lenie_id,
             "live Lenie's cell must not be cleared"

      assert :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), lenie_id) != [],
             "live Lenie's :lenies record must not be deleted"

      # Clean up
      Process.unlink(pid)
      GenServer.stop(pid)
    end

    test "orphaned :lenies record (no cell occupancy, dead id) is deleted",
         %{world_id: world_id} do
      dead_id = "deaddeaddeaddead"

      # Manually plant an orphaned :lenies record — no live pid, no cell
      :ets.insert(
        Lenies.WorldTestHelpers.lenies(world_id),
        {dead_id, %{id: dead_id, pos: {5, 5}, energy: 1.0}}
      )

      assert :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), dead_id) != []

      {_freed, deleted} = Lenies.Worlds.reconcile(world_id)
      assert deleted >= 1

      assert :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), dead_id) == [],
             "orphaned :lenies record should be deleted"
    end

    test "reconcile/0 returns {0, 0} on a clean world with no Lenies",
         %{world_id: world_id} do
      assert {0, 0} = Lenies.Worlds.reconcile(world_id)
    end
  end
end
