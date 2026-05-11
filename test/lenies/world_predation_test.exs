defmodule Lenies.WorldPredationTest do
  use ExUnit.Case, async: false

  alias Lenies.World
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
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

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    # Mark cell, insert minimal lenies snapshot for "P1"
    [{key, cell}] = :ets.lookup(:cells, {10, 10})
    :ets.insert(:cells, {key, %{cell | lenie_id: "P1"}})
    :ets.insert(:lenies, {"P1", %{id: "P1", pid: self(), pos: {10, 10}, dir: :e}})
    :ok
  end

  describe "defend" do
    test "sets defending_until on the parent record" do
      result = World.action({:defend, "P1"})
      assert result == {:ok, :defending}

      [{"P1", record}] = :ets.lookup(:lenies, "P1")
      assert is_integer(record.defending_until)
      # defense_window_ticks default 5; current tick = 0 → defending_until = 5
      assert record.defending_until == 5
    end

    test "defend after multiple ticks updates relative to current tick" do
      for _ <- 1..3, do: World.tick_now()

      result = World.action({:defend, "P1"})
      assert result == {:ok, :defending}

      [{"P1", record}] = :ets.lookup(:lenies, "P1")
      # current tick = 3 → defending_until = 8
      assert record.defending_until == 8
    end

    test "defend on a Lenie without :lenies record returns :no_lenie" do
      :ets.delete(:lenies, "P1")
      result = World.action({:defend, "P1"})
      assert result == {:ok, :no_lenie}
    end
  end
end
