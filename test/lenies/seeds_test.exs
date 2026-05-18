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

  test "all/0 includes all five specialised seeds" do
    ids = Seeds.all() |> Enum.map(& &1.id)
    assert :minimal_replicator in ids
    assert :carnivore in ids
    assert :defender in ids
    assert :hunter in ids
    assert :forager in ids
    assert length(ids) == 5
  end

  test "get/1 returns a seed by id" do
    minimal = Seeds.get(:minimal_replicator)
    assert minimal.id == :minimal_replicator
    assert %Codeome{} = minimal.codeome
  end

  test "get/1 returns nil for unknown id" do
    assert Seeds.get(:nonexistent) == nil
  end
end
