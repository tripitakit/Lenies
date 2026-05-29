defmodule Lenies.SeedPlasmidTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie, Plasmid}
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

  test "MR-Twitch moves on both x and y axes (twitch signature)",
       %{world_id: world_id, handle: handle} do
    # Use 2000 resource so the Lenie (which random-walks due to Twitch) does not
    # deplete local food before it has a chance to move off-axis.
    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {x, y})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 2000}})
    end

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "TWITCH"}})

    plasmid = Plasmid.new(MinimalReplicator.plasmid())

    {:ok, pid} =
      Lenie.start_link({handle,
       [
         id: "TWITCH",
         codeome: MinimalReplicator.codeome(),
         # Large energy so the Twitch Lenie (random-walk) doesn't starve before
         # it leaves the starting row.
         energy: 100_000.0,
         pos: {128, 128},
         dir: :e,
         lineage: {nil, 0},
         plasmids: [plasmid]
       ]})

    Process.unlink(pid)

    deadline = System.monotonic_time(:millisecond) + 15_000

    moved_off_axis =
      poll_until(deadline, fn ->
        case :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), "TWITCH") do
          [{_, %{pos: {_, y}}}] when y != 128 -> {:done, true}
          _ -> :continue
        end
      end)

    assert moved_off_axis == true,
           "expected MR-Twitch to leave y=128 within 15s (twitch plasmid hijacks LOOP_HEAD jump and injects random L/R turn)"
  end

  test "MR-Twitch infects an adjacent vanilla MR",
       %{world_id: world_id, handle: handle} do
    # Use 2000 resource so the Twitch Lenie (random-walk) and vanilla MR both
    # survive long enough to meet and perform conjugation.
    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {x, y})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 2000}})
    end

    [{key1, c1}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key1, %{c1 | lenie_id: "TWITCH"}})
    [{key2, c2}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {129, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key2, %{c2 | lenie_id: "VANILLA"}})

    plasmid = Plasmid.new(MinimalReplicator.plasmid())

    {:ok, twitch_pid} =
      Lenie.start_link({handle,
       [
         id: "TWITCH",
         # Use plasmid-free base codeome so TWITCH marches east and conjugates
         # VANILLA on the first forage iteration. The plasmid buffer carries the
         # Twitch opcodes for transfer — that is what we are testing here.
         codeome: Codeome.from_list(MinimalReplicator.opcodes()),
         energy: 10_000.0,
         pos: {128, 128},
         dir: :e,
         lineage: {nil, 0},
         plasmids: [plasmid]
       ]})

    {:ok, vanilla_pid} =
      Lenie.start_link(
        {handle,
         [
           id: "VANILLA",
           codeome: Codeome.from_list(MinimalReplicator.opcodes()),
           energy: 10_000.0,
           pos: {129, 128},
           dir: :n,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(twitch_pid)
    Process.unlink(vanilla_pid)

    deadline = System.monotonic_time(:millisecond) + 15_000

    infected =
      poll_until(deadline, fn ->
        case :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), "VANILLA") do
          [{_, snap}] ->
            if Map.get(snap, :plasmids, []) != [] do
              {:done, true}
            else
              :continue
            end

          _ ->
            :continue
        end
      end)

    assert infected == true,
           "expected vanilla MR to receive the Twitch plasmid within 15s"
  end

  test "two MR-Twitch Lenies facing each other both survive (no deadlock crash)",
       %{world_id: world_id, handle: handle} do
    # Use 2000 resource: both Lenies random-walk (Twitch) and need enough food
    # to survive the 2.5s observation window without starving.
    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {x, y})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 2000}})
    end

    [{key1, c1}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key1, %{c1 | lenie_id: "A"}})
    [{key2, c2}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {129, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key2, %{c2 | lenie_id: "B"}})

    plasmid = Plasmid.new(MinimalReplicator.plasmid())

    {:ok, a_pid} =
      Lenie.start_link({handle,
       [
         id: "A",
         # Use plasmid-free base codeome: this test is about the deadlock fix,
         # not Twitch behavior. The plasmid buffer carries the Twitch opcodes
         # so `:conjugate` triggers the symmetric-donor scenario.
         codeome: Codeome.from_list(MinimalReplicator.opcodes()),
         energy: 10_000.0,
         pos: {128, 128},
         dir: :e,
         lineage: {nil, 0},
         plasmids: [plasmid]
       ]})

    {:ok, b_pid} =
      Lenie.start_link(
        {handle,
         [
           id: "B",
           codeome: Codeome.from_list(MinimalReplicator.opcodes()),
           energy: 10_000.0,
           pos: {129, 128},
           dir: :w,
           lineage: {nil, 0},
           plasmids: [plasmid]
         ]}
      )

    Process.unlink(a_pid)
    Process.unlink(b_pid)

    # Let them try to conjugate each other for a bit. Without the fix,
    # both die after one 5s GenServer.call timeout (or earlier if they
    # bump into other deadlocks). With the fix, the 50ms call returns
    # :exit cleanly, the donor pays base cost, both keep running.
    Process.sleep(2_500)

    assert Process.alive?(a_pid),
           "Lenie A died — likely from the symmetric-donor deadlock crash"

    assert Process.alive?(b_pid),
           "Lenie B died — likely from the symmetric-donor deadlock crash"
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
          Process.sleep(150)
          poll_until(deadline, fun)
      end
    end
  end
end
