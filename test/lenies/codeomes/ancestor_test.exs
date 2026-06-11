defmodule Lenies.Codeomes.AncestorTest do
  use ExUnit.Case, async: false

  alias Lenies.{Interpreter, Lenie}
  alias Lenies.Codeomes.Ancestor

  @moduletag timeout: 60_000

  describe "control flow (pure)" do
    test "every jump opcode resolves to its intended anchor" do
      index = Interpreter.index_jumps(Ancestor.codeome()).jump_index

      assert index[10] == {4, {:ok, 56}}, "jz_t ABORT → ABORT anchor @56"
      assert index[33] == {4, {:ok, 50}}, "jz_t REPRODUCE → REPRODUCE anchor @50"
      assert index[44] == {4, {:ok, 21}}, "jmp_t COPY → COPY anchor @21"
      assert index[81] == {4, {:ok, 0}}, "jz_t HEAD → HEAD anchor @0"
      assert index[94] == {4, {:ok, 75}}, "jmp_t FORAGE → FORAGE anchor @75"
    end

    test "has exactly five template jumps and none is :not_found" do
      index = Interpreter.index_jumps(Ancestor.codeome()).jump_index
      assert map_size(index) == 5

      for {_ip, {_tlen, result}} <- index do
        assert match?({:ok, _}, result)
      end
    end

    test "chromosome length is 100" do
      assert length(Ancestor.opcodes()) == 100
    end

    test "uses the full replication machinery" do
      ops = Ancestor.opcodes()

      for required <- [:get_size, :allocate, :read_self, :write_child, :divide] do
        assert required in ops, "Ancestor must use #{required}"
      end
    end
  end

  describe "replication in a world" do
    setup do
      Application.put_env(:lenies, :copy_substitution_rate, 0.0)
      Application.put_env(:lenies, :copy_insert_rate, 0.0)
      Application.put_env(:lenies, :copy_delete_rate, 0.0)
      Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
      Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)
      Application.put_env(:lenies, :codeome_length_bounds, {3, 500})
      Application.put_env(:lenies, :eat_amount, 200)
      Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world()
      {:ok, handle} = Lenies.Worlds.handle(world_id)

      on_exit(fn ->
        for k <- [
              :copy_substitution_rate,
              :copy_insert_rate,
              :copy_delete_rate,
              :background_mutation_rate_per_1000_ticks,
              :min_viable_codeome_opcodes,
              :codeome_length_bounds,
              :eat_amount,
              :interpreter_steps_per_batch
            ],
            do: Application.delete_env(:lenies, k)

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

      {:ok, world_id: world_id, handle: handle}
    end

    test "reaches at least generation 2 within the deadline", %{
      world_id: world_id,
      handle: handle
    } do
      for x <- 0..127, y <- 0..127 do
        [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {x, y})
        :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 100_000}})
      end

      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {64, 64})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "ORIGIN"}})

      {:ok, pid} =
        Lenie.start_link(
          {handle,
           [
             id: "ORIGIN",
             codeome: Ancestor.codeome(),
             energy: 100_000.0,
             pos: {64, 64},
             dir: :e,
             lineage: {nil, 0}
           ]}
        )

      Process.unlink(pid)
      deadline = System.monotonic_time(:millisecond) + 30_000

      max_gen =
        poll_until(deadline, fn ->
          snapshots = :ets.tab2list(Lenies.WorldTestHelpers.lenies(world_id))

          case max_generation(snapshots) do
            g when g >= 2 -> {:done, g}
            _ -> :continue
          end
        end)

      population = :ets.info(Lenies.WorldTestHelpers.lenies(world_id), :size)

      assert max_gen >= 2,
             "expected at least 2 generations; got #{max_gen} with #{population} alive"
    end
  end

  defp max_generation(snapshots) do
    snapshots
    |> Enum.map(fn {_id, snap} -> snap |> Map.get(:lineage, {nil, 0}) |> elem(1) end)
    |> Enum.max(fn -> 0 end)
  end

  defp poll_until(deadline, fun) do
    case fun.() do
      {:done, value} ->
        value

      :continue ->
        if System.monotonic_time(:millisecond) >= deadline do
          0
        else
          Process.sleep(100)
          poll_until(deadline, fun)
        end
    end
  end
end
