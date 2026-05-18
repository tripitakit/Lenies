defmodule Lenies.SpeciesTest do
  use ExUnit.Case, async: false

  alias Lenies.Species
  alias Lenies.World.Tables

  setup do
    Tables.create_all()
    on_exit(fn -> Tables.delete_all() end)
    :ok
  end

  test "aggregate/0 returns empty when :lenies is empty" do
    assert Species.aggregate() == []
  end

  test "aggregate/0 groups by codeome_hash and counts population" do
    :ets.insert(:lenies, {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}}})
    :ets.insert(:lenies, {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}}})
    :ets.insert(:lenies, {"c", %{id: "c", codeome_hash: "h2", lineage: {nil, 0}}})

    species = Species.aggregate()

    assert length(species) == 2

    h1 = Enum.find(species, &(&1.hash == "h1"))
    assert h1.population == 2
    assert h1.avg_generation == 0.5

    h2 = Enum.find(species, &(&1.hash == "h2"))
    assert h2.population == 1
    assert h2.avg_generation == 0.0
  end

  test "aggregate/0 sorts by population descending" do
    :ets.insert(:lenies, {"a", %{id: "a", codeome_hash: "small", lineage: {nil, 0}}})

    for i <- 1..5 do
      :ets.insert(:lenies, {"b#{i}", %{id: "b#{i}", codeome_hash: "big", lineage: {nil, 0}}})
    end

    species = Species.aggregate()

    assert hd(species).hash == "big"
    assert hd(species).population == 5
  end

  test "aggregate/0 includes a sample_lenie_id for each species" do
    :ets.insert(:lenies, {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}}})
    :ets.insert(:lenies, {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}}})

    species = Species.aggregate()
    h1 = Enum.find(species, &(&1.hash == "h1"))

    assert h1.sample_lenie_id in ["a", "b"]
  end

  test "for_hash/1 returns all snapshots for that hash" do
    :ets.insert(:lenies, {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}}})
    :ets.insert(:lenies, {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}}})
    :ets.insert(:lenies, {"c", %{id: "c", codeome_hash: "h2", lineage: {nil, 0}}})

    h1_records = Species.for_hash("h1")
    assert length(h1_records) == 2
    ids = Enum.map(h1_records, fn {_id, snap} -> snap.id end) |> Enum.sort()
    assert ids == ["a", "b"]

    assert Species.for_hash("nonexistent") == []
  end

  test "top_n/1 returns at most N species" do
    for i <- 1..10 do
      :ets.insert(:lenies, {"x#{i}", %{id: "x#{i}", codeome_hash: "h#{i}", lineage: {nil, 0}}})
    end

    top3 = Species.top_n(3)
    assert length(top3) == 3
  end

  test "aggregate/0 surfaces seed_origin from the sample snapshot" do
    :ets.insert(
      :lenies,
      {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}, seed_origin: "Minimal Replicator"}}
    )

    :ets.insert(
      :lenies,
      {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}, seed_origin: "Minimal Replicator"}}
    )

    :ets.insert(:lenies, {"c", %{id: "c", codeome_hash: "h2", lineage: {nil, 0}}})

    species = Species.aggregate()
    h1 = Enum.find(species, &(&1.hash == "h1"))
    h2 = Enum.find(species, &(&1.hash == "h2"))

    assert h1.seed_origin == "Minimal Replicator"
    # `h2` was inserted without a :seed_origin key — aggregate must surface nil
    # rather than crashing (Lenies snapshotted before this feature, or
    # spawned via Lenie.start_link directly in a test).
    assert h2.seed_origin == nil
  end
end
