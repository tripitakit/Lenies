defmodule Lenies.Interpreter.MakePlasmidCapTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Interpreter, Plasmid}
  alias Lenies.Interpreter.State

  setup do
    prev = Application.get_env(:lenies, :codeome_length_bounds)
    Application.put_env(:lenies, :codeome_length_bounds, {3, 10})
    on_exit(fn ->
      if prev, do: Application.put_env(:lenies, :codeome_length_bounds, prev),
      else: Application.delete_env(:lenies, :codeome_length_bounds)
    end)
    :ok
  end

  defp run_make_plasmid(codeome_list, start_addr, length) do
    codeome = Codeome.from_list(codeome_list)
    interp = %State{State.new(energy: 1000.0) | stack: [length, start_addr], ip: 0}
    {:cont, new} = Interpreter.step(interp, codeome)
    new
  end

  test "make_plasmid mints when size + length is within the cap (==max allowed)" do
    # exec size 8, length 2 → 8+2 = 10 == max → allowed.
    codeome = [:make_plasmid | List.duplicate(:nop_0, 7)]
    new = run_make_plasmid(codeome, 1, 2)

    assert [%Plasmid{}] = new.plasmids
    assert hd(new.stack) == 1
  end

  test "make_plasmid refuses (no append) when size + length exceeds the cap" do
    # exec size 9, length 2 → 9+2 = 11 > 10 → refused.
    codeome = [:make_plasmid | List.duplicate(:nop_0, 8)]
    new = run_make_plasmid(codeome, 1, 2)

    assert new.plasmids == []
    assert hd(new.stack) == 0
  end
end
