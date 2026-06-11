defmodule Lenies.Codeomes.SymbiontTest do
  use ExUnit.Case, async: false

  alias Lenies.{Interpreter, Lenie}
  alias Lenies.Interpreter.State
  alias Lenies.Codeomes.Symbiont

  @moduletag timeout: 60_000

  describe "control flow (pure)" do
    test "every jump resolves to its intended anchor" do
      index = Interpreter.index_jumps(Symbiont.codeome()).jump_index

      assert index[21] == {4, {:ok, 55}}, "jz_t REPRO → REPRO @55"
      assert index[29] == {4, {:ok, 42}}, "jz_t INFECT → INFECT @42"
      assert index[36] == {4, {:ok, 8}}, "jmp_t MAIN (spread) → MAIN @8"
      assert index[49] == {4, {:ok, 8}}, "jmp_t MAIN (infect) → MAIN @8"
      assert index[65] == {4, {:ok, 8}}, "jz_t MAIN (alloc fail) → MAIN @8"
      assert index[89] == {4, {:ok, 106}}, "jz_t RDIV → RDIV @106"
      assert index[100] == {4, {:ok, 77}}, "jmp_t RCOPY → RCOPY @77"
      assert index[112] == {4, {:ok, 8}}, "jmp_t MAIN (post-divide) → MAIN @8"
    end

    test "has exactly eight template jumps, none :not_found" do
      index = Interpreter.index_jumps(Symbiont.codeome()).jump_index
      assert map_size(index) == 8

      for {_ip, {_tlen, result}} <- index do
        assert match?({:ok, _}, result)
      end
    end

    test "uses the introspection + HGT opcode group, unique among the seeds" do
      ops = Symbiont.opcodes()
      assert :sense_age in ops
      assert :make_plasmid in ops
      assert :conjugate in ops
    end
  end

  describe "runtime plasmid minting" do
    test "the ENTRY prologue mints a 4-gene passenger cassette" do
      state = State.new(ip: 0, energy: 10_000.0)

      # push0; push1; dup; add; dup; add; make_plasmid; drop — eight :cont steps.
      {:cont, after8} = Interpreter.run_k_instructions(state, Symbiont.codeome(), 8)

      assert length(after8.plasmids) == 1, "make_plasmid should mint exactly one plasmid"
      assert hd(after8.plasmids).opcodes == [:push0, :push1, :dup, :add]
      assert after8.ip == 8, "should fall into the MAIN anchor region after minting"
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
             codeome: Symbiont.codeome(),
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
