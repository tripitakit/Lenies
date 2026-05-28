defmodule Lenies.SpeciesTest do
  use ExUnit.Case, async: false

  alias Lenies.Species

  setup do
    {:ok, _world} = Lenies.WorldTestHelpers.start_primary(%{tick_interval_ms: 0})
    handle = Lenies.Worlds.primary_handle()
    # Start from an empty :lenies table — clear whatever the World seeded.
    :ets.delete_all_objects(handle.tables.lenies)

    on_exit(fn -> Lenies.WorldTestHelpers.stop_primary() end)

    {:ok, handle: handle}
  end

  test "aggregate/0 returns empty when :lenies is empty" do
    assert Species.aggregate() == []
  end

  test "aggregate/0 groups by codeome_hash and counts population", %{handle: h} do
    :ets.insert(h.tables.lenies, {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}}})
    :ets.insert(h.tables.lenies, {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}}})
    :ets.insert(h.tables.lenies, {"c", %{id: "c", codeome_hash: "h2", lineage: {nil, 0}}})

    species = Species.aggregate()

    assert length(species) == 2

    h1 = Enum.find(species, &(&1.hash == "h1"))
    assert h1.population == 2
    assert h1.avg_generation == 0.5

    h2 = Enum.find(species, &(&1.hash == "h2"))
    assert h2.population == 1
    assert h2.avg_generation == 0.0
  end

  test "aggregate/0 sorts by population descending", %{handle: h} do
    :ets.insert(h.tables.lenies, {"a", %{id: "a", codeome_hash: "small", lineage: {nil, 0}}})

    for i <- 1..5 do
      :ets.insert(
        h.tables.lenies,
        {"b#{i}", %{id: "b#{i}", codeome_hash: "big", lineage: {nil, 0}}}
      )
    end

    species = Species.aggregate()

    assert hd(species).hash == "big"
    assert hd(species).population == 5
  end

  test "aggregate/0 includes a sample_lenie_id for each species", %{handle: h} do
    :ets.insert(h.tables.lenies, {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}}})
    :ets.insert(h.tables.lenies, {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}}})

    species = Species.aggregate()
    h1 = Enum.find(species, &(&1.hash == "h1"))

    assert h1.sample_lenie_id in ["a", "b"]
  end

  test "for_hash/1 returns all snapshots for that hash", %{handle: h} do
    :ets.insert(h.tables.lenies, {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}}})
    :ets.insert(h.tables.lenies, {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}}})
    :ets.insert(h.tables.lenies, {"c", %{id: "c", codeome_hash: "h2", lineage: {nil, 0}}})

    h1_records = Species.for_hash("h1")
    assert length(h1_records) == 2
    ids = Enum.map(h1_records, fn {_id, snap} -> snap.id end) |> Enum.sort()
    assert ids == ["a", "b"]

    assert Species.for_hash("nonexistent") == []
  end

  test "top_n/1 returns at most N species", %{handle: h} do
    for i <- 1..10 do
      :ets.insert(
        h.tables.lenies,
        {"x#{i}", %{id: "x#{i}", codeome_hash: "h#{i}", lineage: {nil, 0}}}
      )
    end

    top3 = Species.top_n(3)
    assert length(top3) == 3
  end

  test "aggregate/0 surfaces seed_origin from the sample snapshot", %{handle: h} do
    :ets.insert(
      h.tables.lenies,
      {"a", %{id: "a", codeome_hash: "h1", lineage: {nil, 0}, seed_origin: "Minimal Replicator"}}
    )

    :ets.insert(
      h.tables.lenies,
      {"b", %{id: "b", codeome_hash: "h1", lineage: {"a", 1}, seed_origin: "Minimal Replicator"}}
    )

    :ets.insert(h.tables.lenies, {"c", %{id: "c", codeome_hash: "h2", lineage: {nil, 0}}})

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
