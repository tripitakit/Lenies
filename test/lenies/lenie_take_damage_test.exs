defmodule Lenies.LenieTakeDamageTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie, World}
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
    :ok
  end

  test "Lenie loses energy when receiving :take_damage" do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "L1"}})

    codeome = Codeome.from_list([:nop_0, :nop_0])

    {:ok, pid} =
      Lenie.start_link(
        id: "L1",
        codeome: codeome,
        energy: 100.0,
        pos: {5, 5},
        dir: :n,
        lineage: {nil, 0}
      )

    send(pid, {:take_damage, 30, "no_attacker"})
    Process.sleep(50)

    snap = Lenie.inspect_state(pid)
    # Started at 100, lost 30 from damage, plus tiny amount from nop execution
    assert snap.energy <= 100.0 - 30.0 + 0.1

    GenServer.stop(pid)
  end

  test "Lenie dies when :take_damage brings energy <= 0" do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "L2"}})

    codeome = Codeome.from_list([:nop_0])

    {:ok, pid} =
      Lenie.start_link(
        id: "L2",
        codeome: codeome,
        energy: 5.0,
        pos: {5, 5},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)
    ref = Process.monitor(pid)

    send(pid, {:take_damage, 100, "no_attacker"})

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    Process.sleep(100)
    [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    assert cell.lenie_id == nil
  end

  test "Lenie that dies from damage with positive energy leaves carcass" do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "L3"}})

    codeome = Codeome.from_list([:nop_0])

    {:ok, pid} =
      Lenie.start_link(
        id: "L3",
        codeome: codeome,
        energy: 50.0,
        pos: {5, 5},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)
    ref = Process.monitor(pid)

    send(pid, {:take_damage, 50, "no_attacker"})

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    Process.sleep(100)
    [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    assert cell.lenie_id == nil
  end
end
