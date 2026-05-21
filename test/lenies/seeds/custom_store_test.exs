defmodule Lenies.Seeds.CustomStoreTest do
  use ExUnit.Case, async: false

  alias Lenies.Seeds.CustomStore

  @tmp_file_env :__test_user_seeds_file__

  setup do
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "lenies_user_seeds_#{System.unique_integer([:positive])}.json"
      )

    original_path = Application.get_env(:lenies, @tmp_file_env)
    Application.put_env(:lenies, @tmp_file_env, tmp_path)

    # Restart the store so it picks up the new path.
    if Process.whereis(CustomStore) do
      Agent.stop(CustomStore)
    end

    {:ok, _pid} = CustomStore.start_link([])

    on_exit(fn ->
      if Process.whereis(CustomStore) do
        try do
          Agent.stop(CustomStore)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm(tmp_path)

      if original_path do
        Application.put_env(:lenies, @tmp_file_env, original_path)
      else
        Application.delete_env(:lenies, @tmp_file_env)
      end
    end)

    {:ok, tmp_path: tmp_path}
  end

  defp valid_seed(overrides \\ %{}) do
    Map.merge(
      %{
        id: "my-seed",
        name: "My Seed",
        color_hex: "#ff8800",
        energy_default: 10_000.0,
        opcodes: [
          :nop_1,
          :get_size,
          :push0,
          :store,
          :push0,
          :load,
          :allocate,
          :push0,
          :push1,
          :store,
          :nop_1
        ]
      },
      overrides
    )
  end

  describe "save/1 and get/1" do
    test "round-trips a record" do
      :ok = CustomStore.save(valid_seed())
      assert %{name: "My Seed", color_hex: "#ff8800"} = CustomStore.get("my-seed")
    end

    test "overwrites an existing record with the same id" do
      :ok = CustomStore.save(valid_seed(%{name: "first"}))
      :ok = CustomStore.save(valid_seed(%{name: "second"}))
      assert %{name: "second"} = CustomStore.get("my-seed")
    end

    test "get/1 returns nil for unknown id" do
      assert CustomStore.get("does-not-exist") == nil
    end
  end

  describe "all/0" do
    test "returns an empty list initially" do
      assert CustomStore.all() == []
    end

    test "returns all saved records" do
      :ok = CustomStore.save(valid_seed(%{id: "a", name: "A"}))
      :ok = CustomStore.save(valid_seed(%{id: "b", name: "B"}))
      ids = CustomStore.all() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["a", "b"]
    end
  end

  describe "delete/1" do
    test "removes a record" do
      :ok = CustomStore.save(valid_seed())
      assert :ok = CustomStore.delete("my-seed")
      assert CustomStore.get("my-seed") == nil
    end

    test "is idempotent on a missing id" do
      assert :ok = CustomStore.delete("never-there")
    end
  end

  describe "validation" do
    test "rejects an empty name" do
      assert {:error, :invalid_name} = CustomStore.save(valid_seed(%{name: ""}))
    end

    test "rejects a whitespace-only name" do
      assert {:error, :invalid_name} = CustomStore.save(valid_seed(%{name: "   "}))
    end

    test "rejects a name that slugs to an empty id" do
      seed = valid_seed(%{id: "", name: "!!!"})
      assert {:error, :invalid_name} = CustomStore.save(seed)
    end

    test "rejects an all-symbol name (no alphanumeric content)" do
      seed = valid_seed(%{id: "x", name: "###"})
      assert {:error, :invalid_name} = CustomStore.save(seed)
    end

    test "accepts a name with alphanumeric content" do
      assert :ok = CustomStore.save(valid_seed(%{id: "my-seed-2", name: "My Custom Seed"}))
    end

    test "rejects a malformed color_hex" do
      assert {:error, :invalid_color} = CustomStore.save(valid_seed(%{color_hex: "red"}))
    end

    test "rejects an opcode that isn't in the whitelist" do
      assert {:error, :invalid_opcodes} =
               CustomStore.save(valid_seed(%{opcodes: [:nop_1, :nonexistent, :store]}))
    end
  end

  describe "persistence across restart" do
    test "save then restart-agent then get retains the record", %{tmp_path: tmp_path} do
      :ok = CustomStore.save(valid_seed())
      assert File.exists?(tmp_path)

      Agent.stop(CustomStore)
      {:ok, _pid} = CustomStore.start_link([])

      assert %{name: "My Seed"} = CustomStore.get("my-seed")
    end

    test "load survives a corrupt JSON file by starting empty", %{tmp_path: tmp_path} do
      File.write!(tmp_path, "{not valid json")

      Agent.stop(CustomStore)
      {:ok, _pid} = CustomStore.start_link([])

      assert CustomStore.all() == []
    end
  end

  # Helper: write raw JSON rows to disk and reload the agent.
  defp reload_from_json(tmp_path, rows) do
    File.write!(tmp_path, Jason.encode!(rows))
    Agent.stop(CustomStore)
    {:ok, _pid} = CustomStore.start_link([])
  end

  # A JSON-shape row (string keys) that is fully valid.
  defp valid_json_row(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "json-seed",
        "name" => "JSON Seed",
        "color_hex" => "#aabb11",
        "energy_default" => 5_000.0,
        "opcodes" => ["nop_1", "push0", "store", "push0", "load", "nop_1"]
      },
      overrides
    )
  end

  describe "load-path validation (decode_seed)" do
    test "a fully valid row loads correctly", %{tmp_path: tmp_path} do
      reload_from_json(tmp_path, [valid_json_row()])
      assert %{id: "json-seed", name: "JSON Seed", color_hex: "#aabb11"} =
               CustomStore.get("json-seed")
    end

    test "energy_default absent defaults to 10_000.0", %{tmp_path: tmp_path} do
      row = valid_json_row() |> Map.delete("energy_default")
      reload_from_json(tmp_path, [row])
      assert %{energy_default: 10_000.0} = CustomStore.get("json-seed")
    end

    test "invalid color_hex (CSS injection) is DROPPED", %{tmp_path: tmp_path} do
      reload_from_json(tmp_path, [valid_json_row(%{"color_hex" => "javascript:alert(1)"})])
      assert CustomStore.get("json-seed") == nil
      assert CustomStore.all() == []
    end

    test "energy_default as a JSON string is DROPPED", %{tmp_path: tmp_path} do
      reload_from_json(tmp_path, [valid_json_row(%{"energy_default" => "oops"})])
      assert CustomStore.get("json-seed") == nil
    end

    test "numeric id (JSON integer) is DROPPED", %{tmp_path: tmp_path} do
      reload_from_json(tmp_path, [valid_json_row(%{"id" => 123})])
      assert CustomStore.all() == []
    end

    test "opcodes: [] is DROPPED", %{tmp_path: tmp_path} do
      reload_from_json(tmp_path, [valid_json_row(%{"opcodes" => []})])
      assert CustomStore.get("json-seed") == nil
    end

    test "unknown opcode is DROPPED (existing behaviour preserved)", %{tmp_path: tmp_path} do
      reload_from_json(tmp_path, [valid_json_row(%{"opcodes" => ["nop_1", "not_an_opcode"]})])
      assert CustomStore.get("json-seed") == nil
    end

    test "invalid row is dropped but valid sibling still loads", %{tmp_path: tmp_path} do
      bad = valid_json_row(%{"id" => "bad", "color_hex" => "red"})
      good = valid_json_row(%{"id" => "good", "name" => "Good Seed"})
      reload_from_json(tmp_path, [bad, good])
      assert CustomStore.get("bad") == nil
      assert %{name: "Good Seed"} = CustomStore.get("good")
    end
  end

  describe "save/1 empty-opcodes guard" do
    test "save with opcodes: [] returns {:error, :invalid_opcodes}" do
      assert {:error, :invalid_opcodes} = CustomStore.save(valid_seed(%{opcodes: []}))
    end
  end

  # ---------------------------------------------------------------
  # MH4 — Versioned envelope tests
  # ---------------------------------------------------------------

  describe "MH4 versioned envelope (write)" do
    test "save writes the new envelope shape to disk", %{tmp_path: tmp_path} do
      :ok = CustomStore.save(valid_seed())
      {:ok, raw} = File.read(tmp_path)
      decoded = Jason.decode!(raw)
      assert %{"version" => 1, "items" => items} = decoded
      assert is_list(items)
      assert length(items) == 1
      assert hd(items)["id"] == "my-seed"
    end
  end

  describe "MH4 backward-compat read (old bare-array format)" do
    test "bare-array file loads without data loss", %{tmp_path: tmp_path} do
      # Write old bare-array format by hand
      File.write!(tmp_path, Jason.encode!([valid_json_row()]))
      Agent.stop(CustomStore)
      {:ok, _} = CustomStore.start_link([])

      assert %{id: "json-seed", name: "JSON Seed"} = CustomStore.get("json-seed")
    end

    test "after a save following bare-array load, file is upgraded to envelope", %{
      tmp_path: tmp_path
    } do
      # Write old bare-array format
      File.write!(tmp_path, Jason.encode!([valid_json_row()]))
      Agent.stop(CustomStore)
      {:ok, _} = CustomStore.start_link([])

      # Now trigger a write via delete (or save a new one)
      :ok = CustomStore.save(valid_seed(%{id: "extra", name: "Extra Seed"}))

      # File should now be in envelope format
      {:ok, raw} = File.read(tmp_path)
      decoded = Jason.decode!(raw)
      assert %{"version" => 1, "items" => _} = decoded
    end
  end

  describe "MH4 unknown future version" do
    test "v999 envelope logs a warning and starts fresh (no items loaded)", %{
      tmp_path: tmp_path
    } do
      # A file from a hypothetical future build with schema version 999
      future_file = %{
        "version" => 999,
        "items" => [valid_json_row()]
      }

      File.write!(tmp_path, Jason.encode!(future_file))
      Agent.stop(CustomStore)

      # Should not crash; chosen behavior: start fresh and log a warning
      {:ok, _} = CustomStore.start_link([])
      assert CustomStore.all() == []
    end
  end

  # ---------------------------------------------------------------
  # MH1 — Payload-size cap tests
  # ---------------------------------------------------------------

  describe "MH1 payload-size cap (opcodes length)" do
    # The cap for CustomStore is 1000 (codeome_length_bounds max).
    # We use cap+1 entries to exercise the boundary cheaply.
    @cap 1000

    test "row with opcodes length > cap is DROPPED on load", %{tmp_path: tmp_path} do
      oversized_row =
        valid_json_row(%{
          "id" => "oversized",
          "opcodes" => List.duplicate("nop_1", @cap + 1)
        })

      normal_row = valid_json_row(%{"id" => "normal"})

      File.write!(tmp_path, Jason.encode!([oversized_row, normal_row]))
      Agent.stop(CustomStore)
      {:ok, _} = CustomStore.start_link([])

      assert CustomStore.get("oversized") == nil,
             "oversized row should have been dropped"

      assert %{id: "normal"} = CustomStore.get("normal"),
             "normal sibling should still load"
    end

    test "row with opcodes length == cap is ACCEPTED", %{tmp_path: tmp_path} do
      at_cap_row =
        valid_json_row(%{
          "id" => "at-cap",
          "opcodes" => List.duplicate("nop_1", @cap)
        })

      File.write!(tmp_path, Jason.encode!([at_cap_row]))
      Agent.stop(CustomStore)
      {:ok, _} = CustomStore.start_link([])

      assert %{id: "at-cap"} = CustomStore.get("at-cap"),
             "row at exactly the cap should load"
    end

    test "row with non-list opcodes field is DROPPED", %{tmp_path: tmp_path} do
      bad_row = valid_json_row(%{"id" => "non-list", "opcodes" => "not_a_list"})

      File.write!(tmp_path, Jason.encode!([bad_row]))
      Agent.stop(CustomStore)
      {:ok, _} = CustomStore.start_link([])

      assert CustomStore.get("non-list") == nil
    end

    test "cap check works with envelope format too", %{tmp_path: tmp_path} do
      oversized_row =
        valid_json_row(%{
          "id" => "oversized-env",
          "opcodes" => List.duplicate("nop_1", @cap + 1)
        })

      normal_row = valid_json_row(%{"id" => "normal-env"})

      envelope = %{"version" => 1, "items" => [oversized_row, normal_row]}
      File.write!(tmp_path, Jason.encode!(envelope))
      Agent.stop(CustomStore)
      {:ok, _} = CustomStore.start_link([])

      assert CustomStore.get("oversized-env") == nil
      assert %{id: "normal-env"} = CustomStore.get("normal-env")
    end
  end

  describe "concurrency safety (I10)" do
    test "concurrent saves all return :ok, disk == agent state, no stale tmp files",
         %{tmp_path: tmp_path} do
      n = 20
      dir = Path.dirname(tmp_path)

      tasks =
        Enum.map(1..n, fn i ->
          Task.async(fn ->
            seed = valid_seed(%{id: "seed-#{i}", name: "Seed #{i}"})
            CustomStore.save(seed)
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      # (a) every save returned :ok
      assert Enum.all?(results, &(&1 == :ok)),
             "Some saves failed: #{inspect(Enum.reject(results, &(&1 == :ok)))}"

      # (b) disk == agent state, and both contain all N items
      all_in_memory = CustomStore.all()
      assert length(all_in_memory) == n

      Agent.stop(CustomStore)
      {:ok, _} = CustomStore.start_link([])
      all_from_disk = CustomStore.all()

      memory_ids = all_in_memory |> Enum.map(& &1.id) |> Enum.sort()
      disk_ids = all_from_disk |> Enum.map(& &1.id) |> Enum.sort()
      expected_ids = Enum.map(1..n, &"seed-#{&1}") |> Enum.sort()

      assert memory_ids == expected_ids, "In-memory IDs mismatch: #{inspect(memory_ids)}"
      assert disk_ids == expected_ids, "On-disk IDs mismatch: #{inspect(disk_ids)}"

      # (c) no leftover .tmp* files
      tmp_files =
        File.ls!(dir)
        |> Enum.filter(&String.contains?(&1, ".tmp"))
        |> Enum.filter(&String.starts_with?(&1, Path.basename(tmp_path)))

      assert tmp_files == [], "Stale tmp files remain: #{inspect(tmp_files)}"
    end

    test "after a normal save no .tmp* file remains", %{tmp_path: tmp_path} do
      dir = Path.dirname(tmp_path)
      base = Path.basename(tmp_path)

      :ok = CustomStore.save(valid_seed())

      stale =
        File.ls!(dir)
        |> Enum.filter(&String.starts_with?(&1, base))
        |> Enum.filter(&String.contains?(&1, ".tmp"))

      assert stale == [], "Stale tmp files: #{inspect(stale)}"
    end
  end
end
