defmodule Lenies.Codeomes.ReflexTest do
  use ExUnit.Case, async: false

  alias Lenies.{Interpreter, Lenie}
  alias Lenies.Codeomes.Reflex

  @moduletag timeout: 30_000

  describe "control flow (pure)" do
    test "every jump opcode resolves to its intended anchor" do
      index = Interpreter.index_jumps(Reflex.codeome()).jump_index

      # jz_t EMPTY @6  → EMPTY anchor @26, land at 26 + tlen(4) = 30 (drop)
      assert index[6] == {4, {:ok, 26}}
      # jz_t AVOID @13 → AVOID anchor @38, land at 38 + 4 = 42 (turn_right)
      assert index[13] == {4, {:ok, 38}}
      # jmp_t LOOP @20/@32/@43 → LOOP anchor @0, land at 0 + 4 = 4 (sense_front)
      assert index[20] == {4, {:ok, 0}}
      assert index[32] == {4, {:ok, 0}}
      assert index[43] == {4, {:ok, 0}}
    end

    test "has exactly five template jumps and no :not_found" do
      index = Interpreter.index_jumps(Reflex.codeome()).jump_index
      assert map_size(index) == 5

      for {_ip, {_tlen, result}} <- index do
        assert match?({:ok, _}, result)
      end
    end
  end

  describe "composition" do
    test "is a non-replicator: no replication or predation opcodes" do
      ops = Reflex.opcodes()

      for forbidden <- [:allocate, :write_child, :divide, :attack, :defend, :read_self] do
        refute forbidden in ops, "Reflex must not use #{forbidden}"
      end
    end

    test "uses only the reflex opcode subset" do
      allowed =
        MapSet.new([
          :nop_0,
          :nop_1,
          :sense_front,
          :dup,
          :drop,
          :push0,
          :push1,
          :add,
          :jz_t,
          :jmp_t,
          :eat,
          :move,
          :turn_right
        ])

      for op <- Reflex.opcodes() do
        assert MapSet.member?(allowed, op), "unexpected opcode #{op} in Reflex"
      end
    end
  end

  describe "behaviour in a world" do
    setup do
      Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
      Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)
      Application.put_env(:lenies, :codeome_length_bounds, {3, 500})
      Application.put_env(:lenies, :eat_amount, 50)
      Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world()
      {:ok, handle} = Lenies.Worlds.handle(world_id)

      on_exit(fn ->
        for k <- [
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

    test "moves and survives on food, and never replicates", %{
      world_id: world_id,
      handle: handle
    } do
      for x <- 0..63, y <- 0..63 do
        [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {x, y})
        :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | resource: 5000}})
      end

      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {32, 32})
      :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "REFLEX"}})

      {:ok, pid} =
        Lenie.start_link(
          {handle,
           [
             id: "REFLEX",
             codeome: Reflex.codeome(),
             energy: 5_000.0,
             pos: {32, 32},
             dir: :e,
             lineage: {nil, 0}
           ]}
        )

      Process.unlink(pid)
      start_pos = lenie_pos(world_id, "REFLEX")

      # Let it run for ~2 seconds.
      deadline = System.monotonic_time(:millisecond) + 2_000

      moved? =
        poll_until(deadline, fn ->
          case lenie_pos(world_id, "REFLEX") do
            ^start_pos -> :continue
            nil -> :continue
            _other -> {:done, true}
          end
        end)

      population = :ets.info(Lenies.WorldTestHelpers.lenies(world_id), :size)

      assert moved?, "Reflex should move from its start position"
      assert population == 1, "Reflex must never replicate (population stayed #{population})"
    end
  end

  defp lenie_pos(world_id, id) do
    case :ets.lookup(Lenies.WorldTestHelpers.lenies(world_id), id) do
      [{^id, snap}] -> Map.get(snap, :pos)
      _ -> nil
    end
  end

  defp poll_until(deadline, fun) do
    case fun.() do
      {:done, value} ->
        value

      :continue ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(50)
          poll_until(deadline, fun)
        end
    end
  end
end
