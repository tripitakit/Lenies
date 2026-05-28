defmodule Lenies.Codeomes.ForagerTest do
  use ExUnit.Case, async: false

  alias Lenies.Lenie
  alias Lenies.Codeomes.Forager

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
    Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 500})
    Application.put_env(:lenies, :eat_amount, 50)
    Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world()
    {:ok, handle} = Lenies.Worlds.handle(world_id)

    on_exit(fn ->
      Application.delete_env(:lenies, :copy_substitution_rate)
      Application.delete_env(:lenies, :copy_insert_rate)
      Application.delete_env(:lenies, :copy_delete_rate)
      Application.delete_env(:lenies, :background_mutation_rate_per_1000_ticks)
      Application.delete_env(:lenies, :min_viable_codeome_opcodes)
      Application.delete_env(:lenies, :codeome_length_bounds)
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

  test "forager reaches generation >= 3 in 30 seconds",
       %{world_id: world_id, handle: handle} do
    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {x, y})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 200}})
    end

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "FOR-ORIGIN"}})

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "FOR-ORIGIN",
           codeome: Forager.codeome(),
           energy: 10_000.0,
           pos: {128, 128},
           dir: :e,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(pid)

    deadline = System.monotonic_time(:millisecond) + 30_000

    max_gen =
      poll_until(world_id, deadline, fn ->
        snaps = :ets.tab2list(Lenies.WorldTestHelpers.lenies(world_id))
        m = max_generation(snaps)
        if m >= 3, do: {:done, m}, else: :continue
      end)

    snaps = :ets.tab2list(Lenies.WorldTestHelpers.lenies(world_id))

    assert max_gen >= 3,
           "expected at least 3 generations; got max gen #{max_gen}, " <>
             "#{length(snaps)} Lenies alive"
  end

  defp max_generation(snaps) do
    snaps
    |> Enum.map(fn {_id, snap} -> snap.lineage |> elem(1) end)
    |> Enum.max(fn -> 0 end)
  end

  defp poll_until(world_id, deadline, fun) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      snaps = :ets.tab2list(Lenies.WorldTestHelpers.lenies(world_id))
      max_generation(snaps)
    else
      case fun.() do
        {:done, v} ->
          v

        :continue ->
          Process.sleep(200)
          poll_until(world_id, deadline, fun)
      end
    end
  end
end
