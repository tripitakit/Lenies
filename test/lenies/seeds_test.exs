defmodule Lenies.SeedsTest do
  use ExUnit.Case, async: true

  alias Lenies.{Codeome, Seeds}

  test "all/0 returns a list of seed records" do
    seeds = Seeds.all()
    assert is_list(seeds)
    assert length(seeds) >= 2

    for s <- seeds do
      assert is_atom(s.id)
      assert is_binary(s.name)
      assert %Codeome{} = s.codeome
      assert is_map(s.default_options)
    end
  end

  test "all/0 is the four-rung capability ladder plus the applied MaxForager, in order" do
    ids = Seeds.all() |> Enum.map(& &1.id)
    assert ids == [:reflex, :ancestor, :architect, :symbiont, :max_forager]
  end

  test "get/1 returns a seed by id" do
    reflex = Seeds.get(:reflex)
    assert reflex.id == :reflex
    assert %Codeome{} = reflex.codeome
  end

  test "get/1 returns nil for unknown id" do
    assert Seeds.get(:nonexistent) == nil
  end
end
