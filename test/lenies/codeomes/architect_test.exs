defmodule Lenies.Codeomes.ArchitectTest do
  use ExUnit.Case, async: false

  alias Lenies.{Interpreter, Lenie}
  alias Lenies.Interpreter.State
  alias Lenies.Codeomes.Architect

  @moduletag timeout: 60_000

  describe "control flow (pure)" do
    test "every jump/call resolves to its intended anchor" do
      index = Interpreter.index_jumps(Architect.codeome()).jump_index

      assert index[5] == {5, {:ok, 24}}, "call_t FORAGE → FORAGE @24"
      assert index[11] == {5, {:ok, 104}}, "call_t REPLICATE → REPLICATE @104"
      assert index[17] == {5, {:ok, 0}}, "jmp_t MAIN → MAIN @0"
      assert index[49] == {5, {:ok, 76}}, "jz_t FEND → FEND @76"
      assert index[55] == {5, {:ok, 82}}, "call_t STEER → STEER @82"
      assert index[69] == {5, {:ok, 42}}, "jmp_t FLOOP → FLOOP @42"
      assert index[90] == {5, {:ok, 97}}, "jz_t STURN → STURN @97"
      assert index[115] == {5, {:ok, 166}}, "jz_t RDONE → RDONE @166"
      assert index[140] == {5, {:ok, 159}}, "jz_t RDIV → RDIV @159"
      assert index[152] == {5, {:ok, 127}}, "jmp_t RCOPY → RCOPY @127"
    end

    test "has exactly ten template jumps/calls, none :not_found" do
      index = Interpreter.index_jumps(Architect.codeome()).jump_index
      assert map_size(index) == 10

      for {_ip, {_tlen, result}} <- index do
        assert match?({:ok, _}, result)
      end
    end

    test "chromosome length is 173" do
      assert length(Architect.opcodes()) == 173
    end

    test "uses the call stack (call_t/ret) — unique among the seeds" do
      ops = Architect.opcodes()
      assert :call_t in ops
      assert :ret in ops
    end
  end

  describe "the call stack actually engages" do
    test "executing the MAIN prologue pushes a call frame" do
      state = State.new(ip: 0, energy: 10_000.0)

      # 5 nops (@0..4) then call_t FORAGE (@5) — none of these yield to the
      # world, so six steps run to completion and the frame is pushed.
      {:cont, after6} = Interpreter.run_k_instructions(state, Architect.codeome(), 6)

      refute after6.call_stack == [], "call_t should have pushed a return frame"
      assert after6.ip == 29, "should have jumped into FORAGE body (anchor @24 + tlen 5)"
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
             codeome: Architect.codeome(),
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
