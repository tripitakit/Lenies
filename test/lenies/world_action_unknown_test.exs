defmodule Lenies.WorldActionUnknownTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
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

    :ok
  end

  test "unknown action descriptor returns {:error, :unknown_action} without crashing World" do
    {:ok, pid} = World.start_link(tick_interval_ms: 0)
    result = World.action({:made_up_action, "foo", 42})
    assert result == {:ok, {:error, :unknown_action}}
    assert Process.alive?(pid)
  end
end
