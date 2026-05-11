defmodule Lenies.World.TablesTest do
  use ExUnit.Case, async: false

  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      for t <- [:cells, :lenies, :child_slots, :history] do
        try do
          :ets.delete(t)
        rescue
          ArgumentError -> :ok
        end
      end
    end)

    :ok
  end

  test "create_all/0 creates the four named tables as public sets" do
    Tables.create_all()

    for t <- [:cells, :lenies, :child_slots, :history] do
      info = :ets.info(t)
      assert info != :undefined, "table #{t} not created"
      assert Keyword.get(info, :type) == :set
      assert Keyword.get(info, :protection) == :public
    end
  end

  test "delete_all/0 removes all named tables idempotently" do
    Tables.create_all()
    Tables.delete_all()

    for t <- [:cells, :lenies, :child_slots, :history] do
      assert :ets.whereis(t) == :undefined
    end

    # idempotente: non esplode su delete di tabelle inesistenti
    assert :ok = Tables.delete_all()
  end

  test "clear_all/0 empties tables without deleting them" do
    Tables.create_all()
    :ets.insert(:cells, {{0, 0}, :anything})
    assert :ets.info(:cells, :size) == 1
    Tables.clear_all()
    assert :ets.info(:cells, :size) == 0
    assert :ets.whereis(:cells) != :undefined
  end
end
