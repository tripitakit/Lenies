defmodule Lenies.LenieSupervisorTest do
  use ExUnit.Case, async: false

  alias Lenies.LenieSupervisor

  setup do
    on_exit(fn ->
      case Process.whereis(LenieSupervisor) do
        nil ->
          :ok

        pid ->
          if Process.alive?(pid) do
            try do
              Supervisor.stop(pid)
            catch
              :exit, _ -> :ok
            end
          end
      end
    end)

    :ok
  end

  test "starts as DynamicSupervisor with zero children" do
    pid = Process.whereis(LenieSupervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)

    counts = DynamicSupervisor.count_children(LenieSupervisor)
    assert counts.specs == 0
    assert counts.active == 0
  end
end
