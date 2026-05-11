defmodule Lenies.Codeomes.MinimalReplicatorTest do
  use ExUnit.Case, async: false

  alias Lenies.{Lenie, World}
  alias Lenies.Codeomes.MinimalReplicator
  alias Lenies.World.Tables

  @moduletag timeout: 60_000

  setup do
    # Disable copy errors and background mutation for deterministic test
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_interval_ticks, 0)
    # Allow small codeomes to be considered viable (our codeome has many non-nop opcodes)
    Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 500})
    # Eat a lot per cycle to keep Lenies alive
    Application.put_env(:lenies, :eat_amount, 50)
    # Many interpreter steps per batch for faster execution
    Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

    on_exit(fn ->
      # Reset env
      Application.delete_env(:lenies, :copy_substitution_rate)
      Application.delete_env(:lenies, :copy_insert_rate)
      Application.delete_env(:lenies, :copy_delete_rate)
      Application.delete_env(:lenies, :background_mutation_interval_ticks)
      Application.delete_env(:lenies, :min_viable_codeome_opcodes)
      Application.delete_env(:lenies, :codeome_length_bounds)
      Application.delete_env(:lenies, :eat_amount)
      Application.delete_env(:lenies, :interpreter_steps_per_batch)

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

    :ok
  end

  test "minimal_replicator reaches at least generation 3 in 30 seconds" do
    {:ok, _world} = World.start_link(tick_interval_ms: 0)

    # Seed a large biomass area (wide strip so Lenies can eat as they move)
    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(:cells, {x, y})
      :ets.insert(:cells, {key, %{cell | resource: 200}})
    end

    # Spawn original replicator at center
    [{key, cell}] = :ets.lookup(:cells, {50, 50})
    :ets.insert(:cells, {key, %{cell | lenie_id: "ORIGIN"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "ORIGIN",
        codeome: MinimalReplicator.codeome(),
        energy: 5000.0,
        pos: {50, 50},
        dir: :e,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    # Run for up to 30 seconds
    deadline = System.monotonic_time(:millisecond) + 30_000

    max_gen =
      poll_until(deadline, fn ->
        snapshots = :ets.tab2list(:lenies)
        max = max_generation(snapshots)

        if max >= 3 do
          {:done, max}
        else
          :continue
        end
      end)

    snapshots = :ets.tab2list(:lenies)
    population = length(snapshots)

    IO.inspect(population, label: "Final population")
    IO.inspect(max_gen, label: "Max generation reached")

    # Print generation distribution
    gen_dist =
      snapshots
      |> Enum.group_by(fn {_id, snap} -> Map.get(snap, :lineage, {nil, 0}) |> elem(1) end)
      |> Map.new(fn {gen, snaps} -> {gen, length(snaps)} end)

    IO.inspect(gen_dist, label: "Generation distribution")

    assert max_gen >= 3,
           "expected at least 3 generations; got max gen #{max_gen}, #{population} Lenies alive"
  end

  defp max_generation(snapshots) do
    snapshots
    |> Enum.map(fn {_id, snap} -> Map.get(snap, :lineage, {nil, 0}) |> elem(1) end)
    |> Enum.max(fn -> 0 end)
  end

  defp poll_until(deadline, fun) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      snapshots = :ets.tab2list(:lenies)
      max_generation(snapshots)
    else
      case fun.() do
        {:done, value} ->
          value

        :continue ->
          Process.sleep(200)
          poll_until(deadline, fun)
      end
    end
  end
end
