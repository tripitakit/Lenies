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
end
