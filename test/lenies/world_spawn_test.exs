defmodule Lenies.WorldSpawnTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, World}
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
    :ok
  end

  test "spawn_lenie/2 places a new Lenie on a random free cell" do
    codeome = Codeome.from_list([:nop_0, :nop_0, :nop_0])
    result = World.spawn_lenie(codeome, energy: 500.0)

    assert {:ok, {lenie_id, {x, y}}} = result
    assert is_binary(lenie_id)
    assert x in 0..255
    assert y in 0..255

    [{_, cell}] = :ets.lookup(:cells, {x, y})
    assert cell.lenie_id == lenie_id

    [{pid, _}] = Registry.lookup(Lenies.Registry, lenie_id)
    assert is_pid(pid)
    Process.unlink(pid)
    GenServer.stop(pid)
  end

  test "spawn_lenie/2 returns :no_free_cell when grid is full" do
    for x <- 0..255, y <- 0..255 do
      [{key, cell}] = :ets.lookup(:cells, {x, y})
      :ets.insert(:cells, {key, %{cell | lenie_id: "FAKE"}})
    end

    codeome = Codeome.from_list([:nop_0])
    assert {:error, :no_free_cell} = World.spawn_lenie(codeome, energy: 100.0)
  end
end
