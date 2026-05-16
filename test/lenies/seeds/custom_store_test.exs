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
end
