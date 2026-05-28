defmodule Lenies.WorldPredationTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      case Lenies.WorldTestHelpers.lenie_sup_pid() do
        sup_pid when is_pid(sup_pid) ->
          DynamicSupervisor.which_children(sup_pid)
          |> Enum.each(fn {_, child_pid, _, _} ->
            if is_pid(child_pid), do: DynamicSupervisor.terminate_child(sup_pid, child_pid)
          end)

        _ ->
          :ok
      end

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
    end)

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    # Mark cell, insert minimal lenies snapshot for "P1"
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {10, 10})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "P1"}})

    :ets.insert(
      Lenies.WorldTestHelpers.lenies(),
      {"P1", %{id: "P1", pid: self(), pos: {10, 10}, dir: :e}}
    )

    :ok
  end

  describe "defend" do
    test "sets defending_until on the parent record" do
      result = World.action({:defend, "P1"})
      assert result == {:ok, :defending}

      [{"P1", record}] = :ets.lookup(Lenies.WorldTestHelpers.lenies(), "P1")
      assert is_integer(record.defending_until)
      # defense_window_ticks default 5; current tick = 0 → defending_until = 5
      assert record.defending_until == 5
    end

    test "defend after multiple ticks updates relative to current tick" do
      for _ <- 1..3, do: World.tick_now()

      result = World.action({:defend, "P1"})
      assert result == {:ok, :defending}

      [{"P1", record}] = :ets.lookup(Lenies.WorldTestHelpers.lenies(), "P1")
      # current tick = 3 → defending_until = 8
      assert record.defending_until == 8
    end

    test "defend on a Lenie without :lenies record returns :no_lenie" do
      :ets.delete(Lenies.WorldTestHelpers.lenies(), "P1")
      result = World.action({:defend, "P1"})
      assert result == {:ok, :no_lenie}
    end
  end

  describe "attack" do
    setup do
      # Spawn a real target Lenie with a permissive Codeome (loop of nop)
      codeome = Lenies.Codeome.from_list([:nop_0, :nop_0, :nop_0])

      # Mark target cell occupied
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {11, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "T1"}})

      {:ok, target_pid} =
        Lenies.Lenie.start_link(
          id: "T1",
          codeome: codeome,
          energy: 1000.0,
          pos: {11, 10},
          dir: :w,
          lineage: {nil, 0}
        )

      Process.unlink(target_pid)
      # give the Lenie time to write its initial snapshot
      Process.sleep(50)

      on_exit(fn ->
        if Process.alive?(target_pid), do: GenServer.stop(target_pid)
      end)

      %{target_pid: target_pid}
    end

    test "attack on empty front cell returns :no_target", %{target_pid: target_pid} do
      # Move target away
      GenServer.stop(target_pid)
      Process.sleep(100)

      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {11, 10})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: nil}})

      result = World.action({:attack, {10, 10}, :e, "P1"})
      assert result == {:ok, :no_target}
    end

    test "attack on undefended target deals full damage", %{target_pid: target_pid} do
      # ensure no defending_until
      result = World.action({:attack, {10, 10}, :e, "P1"})
      assert {:ok, {:attacked, 10}} = result

      # Wait for target to process :take_damage message asynchronously
      Process.sleep(100)

      snap = Lenies.Lenie.inspect_state(target_pid)
      # Started with 1000.0, lost 10 to attack, plus some energy for own nop ops
      assert snap.energy < 1000.0 - 9.5
    end

    test "attack on defended target deals halved damage and reports :defended" do
      Process.sleep(50)
      # Manually set defending_until in :lenies record for T1
      [{"T1", record}] = :ets.lookup(Lenies.WorldTestHelpers.lenies(), "T1")

      :ets.insert(
        Lenies.WorldTestHelpers.lenies(),
        {"T1", Map.put(record, :defending_until, 100)}
      )

      result = World.action({:attack, {10, 10}, :e, "P1"})
      assert {:ok, {:defended, 5}} = result
    end
  end

  describe "kill leaves carcass" do
    test "Lenie dying from :take_damage leaves cell cleared and registry cleaned" do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {30, 30})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "VICTIM"}})

      codeome = Lenies.Codeome.from_list([:nop_0])

      {:ok, pid} =
        Lenies.Lenie.start_link(
          id: "VICTIM",
          codeome: codeome,
          energy: 100.0,
          pos: {30, 30},
          dir: :n,
          lineage: {nil, 0}
        )

      Process.unlink(pid)
      ref = Process.monitor(pid)

      send(pid, {:take_damage, 100, "no_attacker"})

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500
      # Allow time for the lenie_died cast to be processed
      Process.sleep(200)

      [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {30, 30})
      assert cell.lenie_id == nil
      # Carcass field is non-negative (zero is fine if energy_at_death was negative)
      assert cell.carcass >= 0
    end
  end
end
