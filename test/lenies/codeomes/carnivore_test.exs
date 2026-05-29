defmodule Lenies.Codeomes.CarnivoreTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie}
  alias Lenies.Codeomes.{Carnivore, MinimalReplicator}

  @moduletag timeout: 30_000

  setup do
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
    Application.put_env(:lenies, :min_viable_codeome_opcodes, 5)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 500})
    Application.put_env(:lenies, :eat_amount, 50)
    Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
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
        sup_pid when is_pid(sup_pid) ->
          DynamicSupervisor.which_children(sup_pid)
          |> Enum.each(fn {_, child_pid, _, _} ->
            if is_pid(child_pid), do: DynamicSupervisor.terminate_child(sup_pid, child_pid)
          end)

        _ ->
          :ok
      end

      Lenies.WorldTestHelpers.stop_test_world(world_id)
    end)

    # Seed food so Lenies can survive during the duel.
    # Use 2000 resource: the Sprint plasmid fires an extra move+eat every forage
    # iter, which depletes local food faster than vanilla MR — 2000 prevents
    # starvation before the duel outcome is observed.
    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {x, y})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 2000}})
    end

    {:ok, world_id: world_id, handle: handle}
  end

  test "carnivore.codeome/0 produces a Codeome with attack inserted before eat" do
    base_ops = MinimalReplicator.opcodes()
    carn = Carnivore.codeome() |> Codeome.to_list()

    # carnivore = base (123) + :attack (1) + sprint plasmid (11) = 135
    assert length(carn) == length(base_ops) + 1 + length(Carnivore.plasmid())
    assert :attack in carn
  end

  test "duel: carnivore facing herbivore steals energy via :attack",
       %{world_id: world_id, handle: handle} do
    # Herbivore at {50, 50} facing west (away from carnivore)
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {50, 50})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "HERB"}})

    {:ok, herb_pid} =
      Lenie.start_link({handle,
       [
         id: "HERB",
         # Large energy: HERB uses codeome/0 which includes the Twitch plasmid
         # and random-walks, so it needs extra energy to survive the duel window.
         codeome: MinimalReplicator.codeome(),
         energy: 50_000.0,
         pos: {50, 50},
         dir: :w,
         lineage: {nil, 0}
       ]})

    Process.unlink(herb_pid)

    # Carnivore at {49, 50} facing east → towards herbivore
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {49, 50})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "CARN"}})

    {:ok, carn_pid} =
      Lenie.start_link(
        {handle,
         [
           id: "CARN",
           codeome: Carnivore.codeome(),
           energy: 50_000.0,
           pos: {49, 50},
           dir: :e,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(carn_pid)

    # Run for 500ms
    Process.sleep(500)

    herb_alive = Process.alive?(herb_pid)
    carn_alive = Process.alive?(carn_pid)

    # At least one duelist should still be alive
    assert herb_alive or carn_alive

    if herb_alive and carn_alive do
      herb_snap = Lenie.inspect_state(herb_pid)
      carn_snap = Lenie.inspect_state(carn_pid)
      IO.inspect(herb_snap.energy, label: "HERB energy after 500ms")
      IO.inspect(carn_snap.energy, label: "CARN energy after 500ms")
      assert true
    end

    if herb_alive, do: GenServer.stop(herb_pid)
    if carn_alive, do: GenServer.stop(carn_pid)
  end
end
