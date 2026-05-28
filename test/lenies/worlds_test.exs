defmodule Lenies.WorldsTest do
  # The handle smoke test starts a singleton :primary World, so the module
  # cannot be async. The id_to_path/1 tests are still pure and would be safe
  # in async mode on their own.
  use ExUnit.Case, async: false

  describe "id_to_path/1" do
    test "atom world id renders as the atom name" do
      assert Lenies.Worlds.id_to_path(:primary) == "primary"
      assert Lenies.Worlds.id_to_path(:arena) == "arena"
    end

    test "tuple {atom, integer} renders as 'atom-integer'" do
      assert Lenies.Worlds.id_to_path({:sandbox, 42}) == "sandbox-42"
    end

    test "is filesystem-safe (no slashes or dots)" do
      refute Lenies.Worlds.id_to_path(:primary) =~ "/"
      refute Lenies.Worlds.id_to_path({:sandbox, 42}) =~ "/"
    end
  end

  describe "handle (Task 5 smoke)" do
    # auto_start_simulation is false in test (see config/test.exs); the World
    # must be started by hand. Other tests do the same; tear it down here to
    # avoid a name clash with any subsequent test.
    setup do
      {:ok, pid} = Lenies.World.start_link(tick_interval_ms: 0)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end

        Lenies.World.Tables.delete_all()
      end)

      :ok
    end

    test "primary World exposes a handle with the right tids" do
      handle = GenServer.call(Lenies.World, :get_handle)
      assert %Lenies.WorldHandle{id: :primary, pubsub_prefix: "world:primary"} = handle
      assert is_reference(handle.tables.cells)
      assert is_reference(handle.tables.lenies)
      assert handle.pid == Process.whereis(Lenies.World)
    end
  end
end
