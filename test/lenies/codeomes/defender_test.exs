defmodule Lenies.Codeomes.DefenderTest do
  use ExUnit.Case, async: false

  alias Lenies.{Lenie, World}
  alias Lenies.Codeomes.Defender
  alias Lenies.World.Tables

  @moduletag timeout: 60_000

  setup do
    # Deterministic: kill all stochastic codeome edits so the test sees the
    # pure Defender behaviour, no copy errors and no background mutation.
    Application.put_env(:lenies, :copy_substitution_rate, 0.0)
    Application.put_env(:lenies, :copy_insert_rate, 0.0)
    Application.put_env(:lenies, :copy_delete_rate, 0.0)
    Application.put_env(:lenies, :background_mutation_rate_per_1000_ticks, 0)
    Application.put_env(:lenies, :min_viable_codeome_opcodes, 3)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 500})
    # Boost eat_amount so the cycle completes well within the 30s budget.
    Application.put_env(:lenies, :eat_amount, 50)
    Application.put_env(:lenies, :interpreter_steps_per_batch, 50)

    on_exit(fn ->
      Application.delete_env(:lenies, :copy_substitution_rate)
      Application.delete_env(:lenies, :copy_insert_rate)
      Application.delete_env(:lenies, :copy_delete_rate)
      Application.delete_env(:lenies, :background_mutation_rate_per_1000_ticks)
      Application.delete_env(:lenies, :min_viable_codeome_opcodes)
      Application.delete_env(:lenies, :codeome_length_bounds)
      Application.delete_env(:lenies, :eat_amount)
      Application.delete_env(:lenies, :interpreter_steps_per_batch)

      case Lenies.WorldTestHelpers.lenie_sup_pid() do
        sup when is_pid(sup) ->
          DynamicSupervisor.which_children(sup)
          |> Enum.each(fn {_, child, _, _} ->
            if is_pid(child), do: DynamicSupervisor.terminate_child(sup, child)
          end)

        _ ->
          :ok
      end

      Lenies.WorldTestHelpers.stop_primary()
    end)

    :ok
  end

  test "defender reaches generation >= 3 in 30 seconds" do
    {:ok, _world} = Lenies.WorldTestHelpers.start_primary()

    # Wide resource strip so the random-turn behaviour can find food
    # regardless of the direction the seed wandered into.
    for x <- 0..254, y <- 0..254 do
      [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {x, y})
      :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | resource: 200}})
    end

    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(), {128, 128})
    :ets.insert(Lenies.WorldTestHelpers.cells(), {key, %{cell | lenie_id: "DEF-ORIGIN"}})

    {:ok, pid} =
      Lenie.start_link(
        id: "DEF-ORIGIN",
        codeome: Defender.codeome(),
        energy: 10_000.0,
        pos: {128, 128},
        dir: :e,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    deadline = System.monotonic_time(:millisecond) + 30_000

    max_gen =
      poll_until(deadline, fn ->
        snaps = :ets.tab2list(Lenies.WorldTestHelpers.lenies())
        m = max_generation(snaps)
        if m >= 3, do: {:done, m}, else: :continue
      end)

    snaps = :ets.tab2list(Lenies.WorldTestHelpers.lenies())

    assert max_gen >= 3,
           "expected at least 3 generations; got max gen #{max_gen}, " <>
             "#{length(snaps)} Lenies alive"
  end

  defp max_generation(snaps) do
    snaps
    |> Enum.map(fn {_id, snap} -> snap.lineage |> elem(1) end)
    |> Enum.max(fn -> 0 end)
  end

  defp poll_until(deadline, fun) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      snaps = :ets.tab2list(Lenies.WorldTestHelpers.lenies())
      max_generation(snaps)
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
