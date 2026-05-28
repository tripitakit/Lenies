defmodule Lenies.LenieTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie}

  setup do
    on_exit(fn -> Lenies.WorldTestHelpers.stop_primary() end)
    :ok
  end

  test "start_link/1 registers the Lenie under its id" do
    {:ok, _world} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})

    # mark cell {5,5} as occupied (the Lenie expects to find itself there)
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "L1"}})

    codeome = Codeome.from_list([:nop_0, :nop_1])

    {:ok, pid} =
      Lenie.start_link(
        id: "L1",
        codeome: codeome,
        energy: 50.0,
        pos: {5, 5},
        dir: :e,
        lineage: {nil, 0}
      )

    assert Process.alive?(pid)
    assert [{^pid, _}] = Registry.lookup(Lenies.Registry, {:lenie, :primary, "L1"})

    GenServer.stop(pid)
  end

  test "inspect_state/1 returns current snapshot" do
    {:ok, _world} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "L2"}})

    codeome = Codeome.from_list([:nop_0])

    {:ok, pid} =
      Lenie.start_link(
        id: "L2",
        codeome: codeome,
        energy: 10.0,
        pos: {5, 5},
        dir: :n,
        lineage: {nil, 0}
      )

    snapshot = Lenie.inspect_state(pid)
    assert snapshot.id == "L2"
    assert snapshot.energy <= 10.0
    assert snapshot.pos == {5, 5}
    assert snapshot.dir == :n

    GenServer.stop(pid)
  end

  test "dies of starvation when energy depletes" do
    {:ok, _world} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "L3"}})

    # only 0.3 energy — will be consumed by a few nops + age increments
    codeome = Codeome.from_list([:nop_0, :nop_1, :add, :sub])

    {:ok, pid} =
      Lenie.start_link(
        id: "L3",
        codeome: codeome,
        energy: 0.3,
        pos: {5, 5},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :starvation}, 1_000

    # cell freed
    [{_, after_cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {5, 5})
    assert after_cell.lenie_id == nil
  end
end
