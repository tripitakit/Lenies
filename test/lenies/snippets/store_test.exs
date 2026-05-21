defmodule Lenies.Snippets.StoreTest do
  use ExUnit.Case, async: false

  alias Lenies.Snippets.Store

  @tmp_file_env :__test_user_snippets_file__

  setup do
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "lenies_user_snippets_#{System.unique_integer([:positive])}.json"
      )

    original_path = Application.get_env(:lenies, @tmp_file_env)
    Application.put_env(:lenies, @tmp_file_env, tmp_path)

    if Process.whereis(Store), do: Agent.stop(Store)
    {:ok, _pid} = Store.start_link([])

    on_exit(fn ->
      if Process.whereis(Store) do
        try do
          Agent.stop(Store)
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

  defp snippet(overrides \\ %{}) do
    Map.merge(%{id: "loop", name: "Loop", opcodes: [:nop_0, :eat, :move]}, overrides)
  end

  test "starts empty" do
    assert Store.all() == []
  end

  test "save then all returns the snippet" do
    assert :ok = Store.save(snippet())
    assert [%{id: "loop", name: "Loop", opcodes: [:nop_0, :eat, :move]}] = Store.all()
  end

  test "save upserts by id (same id overwrites)" do
    :ok = Store.save(snippet())
    :ok = Store.save(snippet(%{opcodes: [:move]}))
    assert [%{id: "loop", opcodes: [:move]}] = Store.all()
  end

  test "rejects empty name" do
    assert {:error, :invalid_name} = Store.save(snippet(%{name: "  ", id: "x"}))
  end

  test "rejects an all-symbol name (no alphanumeric content)" do
    assert {:error, :invalid_name} = Store.save(snippet(%{name: "###", id: "x"}))
  end

  test "accepts a name with alphanumeric content" do
    assert :ok = Store.save(snippet(%{name: "My Loop", id: "my-loop"}))
  end

  test "rejects unknown opcodes" do
    assert {:error, :invalid_opcodes} = Store.save(snippet(%{opcodes: [:not_a_real_op]}))
  end

  test "delete removes by id" do
    :ok = Store.save(snippet())
    :ok = Store.delete("loop")
    assert Store.all() == []
  end

  test "persists across a restart (reload from disk)", %{tmp_path: tmp_path} do
    :ok = Store.save(snippet())
    assert File.exists?(tmp_path)
    Agent.stop(Store)
    {:ok, _} = Store.start_link([])
    assert [%{id: "loop", opcodes: [:nop_0, :eat, :move]}] = Store.all()
  end

  test "get/1 returns nil for an unknown id" do
    assert Store.get("nope") == nil
  end

  test "delete is a no-op for an unknown id" do
    :ok = Store.save(snippet())
    assert :ok = Store.delete("does-not-exist")
    assert [%{id: "loop"}] = Store.all()
  end

  test "load survives a corrupt JSON file by starting empty", %{tmp_path: tmp_path} do
    Agent.stop(Store)
    File.write!(tmp_path, "{not valid json")
    {:ok, _} = Store.start_link([])
    assert Store.all() == []
  end

  test "load drops snippets with unknown opcodes", %{tmp_path: tmp_path} do
    Agent.stop(Store)

    File.write!(
      tmp_path,
      Jason.encode!([
        %{"id" => "good", "name" => "Good", "opcodes" => ["nop_0", "eat"]},
        %{"id" => "bad", "name" => "Bad", "opcodes" => ["totally_unknown_opcode_xyz"]}
      ])
    )

    {:ok, _} = Store.start_link([])
    ids = Store.all() |> Enum.map(& &1.id)
    assert ids == ["good"]
  end

  # ---------------------------------------------------------------
  # MH4 — Versioned envelope tests
  # ---------------------------------------------------------------

  describe "MH4 versioned envelope (write)" do
    test "save writes the new envelope shape to disk", %{tmp_path: tmp_path} do
      :ok = Store.save(snippet())
      {:ok, raw} = File.read(tmp_path)
      decoded = Jason.decode!(raw)
      assert %{"version" => 1, "items" => items} = decoded
      assert is_list(items)
      assert length(items) == 1
      assert hd(items)["id"] == "loop"
    end
  end

  describe "MH4 backward-compat read (old bare-array format)" do
    test "bare-array file loads without data loss", %{tmp_path: tmp_path} do
      Agent.stop(Store)
      File.write!(
        tmp_path,
        Jason.encode!([%{"id" => "loop", "name" => "Loop", "opcodes" => ["nop_0", "eat"]}])
      )

      {:ok, _} = Store.start_link([])
      assert %{id: "loop", name: "Loop", opcodes: [:nop_0, :eat]} = Store.get("loop")
    end

    test "after a save following bare-array load, file is upgraded to envelope", %{
      tmp_path: tmp_path
    } do
      Agent.stop(Store)
      File.write!(
        tmp_path,
        Jason.encode!([%{"id" => "loop", "name" => "Loop", "opcodes" => ["nop_0"]}])
      )

      {:ok, _} = Store.start_link([])
      :ok = Store.save(snippet(%{id: "extra", name: "Extra"}))

      {:ok, raw} = File.read(tmp_path)
      decoded = Jason.decode!(raw)
      assert %{"version" => 1, "items" => _} = decoded
    end
  end

  describe "MH4 unknown future version" do
    test "v999 envelope logs a warning and starts fresh (no items loaded)", %{
      tmp_path: tmp_path
    } do
      future_file = %{
        "version" => 999,
        "items" => [%{"id" => "loop", "name" => "Loop", "opcodes" => ["nop_0"]}]
      }

      Agent.stop(Store)
      File.write!(tmp_path, Jason.encode!(future_file))
      {:ok, _} = Store.start_link([])

      assert Store.all() == []
    end
  end

  # ---------------------------------------------------------------
  # MH1 — Payload-size cap tests
  # ---------------------------------------------------------------

  describe "MH1 payload-size cap (opcodes length)" do
    # The cap for Snippets.Store is @max_snippet_opcodes = 1000.
    @cap 1000

    test "row with opcodes length > cap is DROPPED on load", %{tmp_path: tmp_path} do
      oversized =
        %{
          "id" => "oversized",
          "name" => "Oversized",
          "opcodes" => List.duplicate("nop_0", @cap + 1)
        }

      normal = %{"id" => "normal", "name" => "Normal", "opcodes" => ["nop_0", "eat"]}

      Agent.stop(Store)
      File.write!(tmp_path, Jason.encode!([oversized, normal]))
      {:ok, _} = Store.start_link([])

      assert Store.get("oversized") == nil, "oversized row should be dropped"
      assert %{id: "normal"} = Store.get("normal"), "normal sibling should load"
    end

    test "row with opcodes length == cap is ACCEPTED", %{tmp_path: tmp_path} do
      at_cap = %{
        "id" => "at-cap",
        "name" => "At Cap",
        "opcodes" => List.duplicate("nop_0", @cap)
      }

      Agent.stop(Store)
      File.write!(tmp_path, Jason.encode!([at_cap]))
      {:ok, _} = Store.start_link([])

      assert %{id: "at-cap"} = Store.get("at-cap")
    end

    test "row with non-list opcodes field is DROPPED", %{tmp_path: tmp_path} do
      bad = %{"id" => "bad", "name" => "Bad", "opcodes" => "not_a_list"}

      Agent.stop(Store)
      File.write!(tmp_path, Jason.encode!([bad]))
      {:ok, _} = Store.start_link([])

      assert Store.get("bad") == nil
    end

    test "cap check works with envelope format too", %{tmp_path: tmp_path} do
      oversized = %{
        "id" => "oversized-env",
        "name" => "Oversized Env",
        "opcodes" => List.duplicate("nop_0", @cap + 1)
      }

      normal = %{"id" => "normal-env", "name" => "Normal Env", "opcodes" => ["nop_0"]}

      envelope = %{"version" => 1, "items" => [oversized, normal]}
      Agent.stop(Store)
      File.write!(tmp_path, Jason.encode!(envelope))
      {:ok, _} = Store.start_link([])

      assert Store.get("oversized-env") == nil
      assert %{id: "normal-env"} = Store.get("normal-env")
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
            Store.save(snippet(%{id: "snip-#{i}", name: "Snip #{i}"}))
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      # (a) every save returned :ok
      assert Enum.all?(results, &(&1 == :ok)),
             "Some saves failed: #{inspect(Enum.reject(results, &(&1 == :ok)))}"

      # (b) disk == agent state, both contain all N items
      all_in_memory = Store.all()
      assert length(all_in_memory) == n

      Agent.stop(Store)
      {:ok, _} = Store.start_link([])
      all_from_disk = Store.all()

      memory_ids = all_in_memory |> Enum.map(& &1.id) |> Enum.sort()
      disk_ids = all_from_disk |> Enum.map(& &1.id) |> Enum.sort()
      expected_ids = Enum.map(1..n, &"snip-#{&1}") |> Enum.sort()

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

      :ok = Store.save(snippet())

      stale =
        File.ls!(dir)
        |> Enum.filter(&String.starts_with?(&1, base))
        |> Enum.filter(&String.contains?(&1, ".tmp"))

      assert stale == [], "Stale tmp files: #{inspect(stale)}"
    end
  end
end
