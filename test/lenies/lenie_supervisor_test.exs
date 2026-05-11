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
    {:ok, pid} = LenieSupervisor.start_link([])
    assert Process.alive?(pid)
    assert Process.whereis(LenieSupervisor) == pid

    assert DynamicSupervisor.count_children(LenieSupervisor) == %{
             active: 0,
             specs: 0,
             supervisors: 0,
             workers: 0
           }
  end
end
