defmodule Lenies.CollectionSpawnTest do
  # async: false because we start a real world (OTP process tree + ETS tables)
  # alongside the DB sandbox, which requires shared sandbox mode.
  use Lenies.DataCase, async: false

  import Lenies.AccountsFixtures

  @moduletag timeout: 30_000

  describe "plasmid persistence — spawn round-trip" do
    setup do
      %{user: user_fixture()}
    end

    test "a custom seed's stored plasmid is carried by the spawned Lenie", %{user: user} do
      {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
      on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)

      attrs = %{
        name: "SpawnP",
        color_hex: "#abcdef",
        energy_default: 500.0,
        opcodes: ["nop_0", "move", "eat"],
        plasmids: [%{opcodes: ["turn_left"]}]
      }

      {:ok, saved} = Lenies.Collection.create_codeome(user, attrs)
      seed = Lenies.Collection.get_codeome(user, saved.id)

      codeome = Lenies.Codeome.from_list(Lenies.Collection.to_opcode_atoms(seed))

      {:ok, {id, _pos}} =
        Lenies.Worlds.spawn_lenie(world_id, codeome,
          energy: 500.0,
          plasmids: Lenies.Collection.to_plasmid_structs(seed)
        )

      snap =
        Lenies.WorldTestHelpers.lenies(world_id)
        |> :ets.tab2list()
        |> Enum.find_value(fn {i, s} -> if i == id, do: s end)

      assert length(Map.get(snap, :plasmids, [])) == 1
    end
  end
end
