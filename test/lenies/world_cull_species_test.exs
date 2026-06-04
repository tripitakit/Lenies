defmodule Lenies.WorldCullSpeciesTest do
  use ExUnit.Case, async: false

  alias Lenies.Codeome

  setup do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world()

    on_exit(fn ->
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

    {:ok, world_id: world_id}
  end

  test "cull_species/2 removes only Lenies of the given hash and frees their cells",
       %{world_id: world_id} do
    target = Codeome.from_list([:nop_0, :nop_0, :nop_0])
    other = Codeome.from_list([:nop_1, :nop_1, :nop_1])
    target_hash = Codeome.hash(target)

    {:ok, {id_a, cell_a}} = Lenies.Worlds.spawn_lenie(world_id, target, energy: 500.0)
    {:ok, {id_b, cell_b}} = Lenies.Worlds.spawn_lenie(world_id, target, energy: 500.0)
    {:ok, {id_c, _cell_c}} = Lenies.Worlds.spawn_lenie(world_id, other, energy: 500.0)

    assert {:ok, 2} = Lenies.Worlds.cull_species(world_id, target_hash)

    # Flush the async :lenie_died casts with a synchronous call.
    _ = Lenies.Worlds.snapshot_stats(world_id)

    lenies = Lenies.WorldTestHelpers.lenies(world_id)
    assert :ets.lookup(lenies, id_a) == []
    assert :ets.lookup(lenies, id_b) == []
    assert [{^id_c, _}] = :ets.lookup(lenies, id_c)

    cells = Lenies.WorldTestHelpers.cells(world_id)
    assert [{_, %{lenie_id: nil}}] = :ets.lookup(cells, cell_a)
    assert [{_, %{lenie_id: nil}}] = :ets.lookup(cells, cell_b)
  end

  test "cull_species/2 with an unknown hash is a no-op returning {:ok, 0}",
       %{world_id: world_id} do
    assert {:ok, 0} = Lenies.Worlds.cull_species(world_id, "deadbeef-not-a-real-hash")
  end
end
