defmodule Lenies.LenieSupervisorTest do
  use ExUnit.Case, async: false

  alias Lenies.WorldTestHelpers

  setup do
    {:ok, _sup} = Lenies.Worlds.start_world(:primary, %{tick_interval_ms: 0})

    on_exit(fn ->
      Lenies.Worlds.stop_world(:primary)
      Lenies.World.Tables.delete_all()
    end)

    :ok
  end

  test "starts as DynamicSupervisor with zero children" do
    pid = WorldTestHelpers.lenie_sup_pid()
    assert is_pid(pid)
    assert Process.alive?(pid)

    counts = DynamicSupervisor.count_children(Lenies.LenieSupervisor.via(:primary))
    assert counts.specs == 0
    assert counts.active == 0
  end
end
