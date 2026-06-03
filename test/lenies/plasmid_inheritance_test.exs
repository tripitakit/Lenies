defmodule Lenies.PlasmidInheritanceTest do
  use ExUnit.Case, async: false

  alias Lenies.{Lenie, Plasmid}
  alias Lenies.Codeomes.MinimalReplicator

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
    Application.put_env(:lenies, :eat_amount, 50)
    Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world()
    {:ok, handle} = Lenies.Worlds.handle(world_id)

    on_exit(fn ->
      Application.delete_env(:lenies, :copy_substitution_rate)
      Application.delete_env(:lenies, :copy_insert_rate)
      Application.delete_env(:lenies, :copy_delete_rate)
      Application.delete_env(:lenies, :background_mutation_rate_per_1000_ticks)
      Application.delete_env(:lenies, :eat_amount)
      Application.delete_env(:lenies, :interpreter_steps_per_batch)

      case Lenies.WorldTestHelpers.lenie_sup_pid(world_id) do
        sup when is_pid(sup) ->
          DynamicSupervisor.which_children(sup)
          |> Enum.each(fn {_, child, _, _} ->
            if is_pid(child), do: DynamicSupervisor.terminate_child(sup, child)
          end)

        _ ->
          :ok
      end

      Lenies.WorldTestHelpers.stop_test_world(world_id)
    end)

    {:ok, world_id: world_id, handle: handle}
  end

  test "child inherits parent's plasmid through divide",
       %{world_id: world_id, handle: handle} do
    for x <- 0..127, y <- 0..127 do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {x, y})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 200}})
    end

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {64, 64})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "PARENT"}})

    parent_plasmid = Plasmid.new([:eat, :move, :turn_left])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "PARENT",
           codeome: MinimalReplicator.codeome(),
           energy: 10_000.0,
           pos: {64, 64},
           dir: :e,
           lineage: {nil, 0},
           plasmids: [parent_plasmid]
         ]}
      )

    Process.unlink(pid)

    deadline = System.monotonic_time(:millisecond) + 30_000

    child_with_plasmid =
      poll_until(deadline, fn ->
        :ets.tab2list(Lenies.WorldTestHelpers.lenies(world_id))
        |> Enum.find_value(fn {id, snap} ->
          if id != "PARENT" and Map.get(snap, :plasmids, []) != [] do
            {:done, snap}
          else
            nil
          end
        end) || :continue
      end)

    assert is_map(child_with_plasmid),
           "expected at least one child Lenie to have inherited the plasmid within 30s"

    assert [%Plasmid{opcodes: [:eat, :move, :turn_left]}] = child_with_plasmid.plasmids
  end

  defp poll_until(deadline, fun) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      nil
    else
      case fun.() do
        {:done, v} ->
          v

        :continue ->
          Process.sleep(200)
          poll_until(deadline, fun)
      end
    end
  end
end
