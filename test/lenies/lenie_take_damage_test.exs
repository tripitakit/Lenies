defmodule Lenies.LenieTakeDamageTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie}

  setup do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)

    on_exit(fn ->
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

    {:ok, world_id: world_id, handle: handle}
  end

  test "Lenie loses energy when receiving :take_damage", %{world_id: world_id, handle: handle} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L1"}})

    codeome = Codeome.from_list([:nop_0, :nop_0])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L1",
           codeome: codeome,
           energy: 100.0,
           pos: {5, 5},
           dir: :n,
           lineage: {nil, 0}
         ]}
      )

    send(pid, {:take_damage, 30, "no_attacker"})
    Process.sleep(50)

    snap = Lenie.inspect_state(pid)
    # Started at 100, lost 30 from damage, plus tiny amount from nop execution
    assert snap.energy <= 100.0 - 30.0 + 0.1

    GenServer.stop(pid)
  end

  test "Lenie dies when :take_damage brings energy <= 0",
       %{world_id: world_id, handle: handle} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L2"}})

    codeome = Codeome.from_list([:nop_0])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L2",
           codeome: codeome,
           energy: 5.0,
           pos: {5, 5},
           dir: :n,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(pid)
    ref = Process.monitor(pid)

    send(pid, {:take_damage, 100, "no_attacker"})

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    Process.sleep(100)
    [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert cell.lenie_id == nil
  end

  test "Lenie that dies from damage with positive energy leaves carcass",
       %{world_id: world_id, handle: handle} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "L3"}})

    codeome = Codeome.from_list([:nop_0])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "L3",
           codeome: codeome,
           energy: 50.0,
           pos: {5, 5},
           dir: :n,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(pid)
    ref = Process.monitor(pid)

    send(pid, {:take_damage, 50, "no_attacker"})

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    Process.sleep(100)
    [{_, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {5, 5})
    assert cell.lenie_id == nil
  end
end
