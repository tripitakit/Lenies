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

  test "all/0 includes minimal_replicator, carnivore, random" do
    ids = Seeds.all() |> Enum.map(& &1.id)
    assert :minimal_replicator in ids
    assert :carnivore in ids
    assert :random in ids
  end

  test "get/1 returns a seed by id" do
    minimal = Seeds.get(:minimal_replicator)
    assert minimal.id == :minimal_replicator
    assert %Codeome{} = minimal.codeome
  end

  test "get/1 returns nil for unknown id" do
    assert Seeds.get(:nonexistent) == nil
  end

  test "build_random_codeome/0 returns a Codeome of reasonable length" do
    c = Seeds.build_random_codeome()
    n = Codeome.size(c)
    assert n >= 20 and n <= 200
  end

  test "build_random_codeome/0 returns different Codeomes on successive calls" do
    c1 = Seeds.build_random_codeome()
    c2 = Seeds.build_random_codeome()
    refute Codeome.to_list(c1) == Codeome.to_list(c2)
  end
end
