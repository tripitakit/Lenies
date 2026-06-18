defmodule Lenies.StdLib.CatalogTest do
  use ExUnit.Case, async: true
  alias Lenies.StdLib.{Catalog, Snippet}

  test "all/0 returns Snippet structs with unique ids" do
    all = Catalog.all()
    assert length(all) >= 6
    assert Enum.all?(all, &match?(%Snippet{}, &1))
    ids = Enum.map(all, & &1.id)
    assert ids == Enum.uniq(ids)
  end

  test "get/1 finds by id, nil otherwise" do
    assert %Snippet{id: "random-bit"} = Catalog.get("random-bit")
    assert Catalog.get("nope") == nil
  end

  test "by_category/0 groups, chromosome-safe order" do
    grouped = Catalog.by_category()
    assert is_list(grouped)
    assert {_cat, [%Snippet{} | _]} = hd(grouped)
  end

  test "every inline snippet body is whitelisted opcodes only" do
    ok = Lenies.Codeome.Opcodes.all() |> MapSet.new()
    for %Snippet{kind: :inline, body: body, id: id} <- Catalog.all() do
      assert Enum.all?(body, &MapSet.member?(ok, &1)), "#{id} has non-opcode body item"
    end
  end
end
