defmodule Lenies.CollectionTest do
  use Lenies.DataCase, async: true

  alias Lenies.Collection.Codeome

  @valid_attrs %{
    name: "My Seed",
    color_hex: "#ff8800",
    energy_default: 500.0,
    opcodes: ["nop_1", "store", "eat"]
  }

  describe "Codeome.changeset/2 validations" do
    test "accepts valid attrs" do
      assert %Ecto.Changeset{valid?: true} = Codeome.changeset(%Codeome{}, @valid_attrs)
    end

    test "rejects blank name" do
      cs = Codeome.changeset(%Codeome{}, %{@valid_attrs | name: "   "})
      assert "can't be blank" in errors_on(cs).name
    end

    test "rejects name with no alphanumeric character" do
      cs = Codeome.changeset(%Codeome{}, %{@valid_attrs | name: "----"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :name)
    end

    test "rejects bad color" do
      cs = Codeome.changeset(%Codeome{}, %{@valid_attrs | color_hex: "red"})
      assert Map.has_key?(errors_on(cs), :color_hex)
    end

    test "rejects empty opcodes" do
      cs = Codeome.changeset(%Codeome{}, %{@valid_attrs | opcodes: []})
      assert Map.has_key?(errors_on(cs), :opcodes)
    end

    test "rejects unknown opcode" do
      cs = Codeome.changeset(%Codeome{}, %{@valid_attrs | opcodes: ["nop_1", "not_an_opcode"]})
      assert Map.has_key?(errors_on(cs), :opcodes)
    end

    test "rejects opcodes longer than the configured cap" do
      cap = elem(Lenies.Config.codeome_length_bounds(), 1)
      too_long = List.duplicate("nop_0", cap + 1)
      cs = Codeome.changeset(%Codeome{}, %{@valid_attrs | opcodes: too_long})
      assert Map.has_key?(errors_on(cs), :opcodes)
    end
  end

  describe "context CRUD, owner-scoped" do
    import Lenies.AccountsFixtures

    setup do
      %{user: user_fixture(), other: user_fixture()}
    end

    test "create_codeome/2 persists for the owner", %{user: user} do
      assert {:ok, c} = Lenies.Collection.create_codeome(user, @valid_attrs)
      assert c.owner_id == user.id
      assert c.opcodes == ["nop_1", "store", "eat"]
    end

    test "create_codeome/2 returns changeset error on invalid attrs", %{user: user} do
      assert {:error, %Ecto.Changeset{}} =
               Lenies.Collection.create_codeome(user, %{@valid_attrs | color_hex: "nope"})
    end

    test "create_codeome/2 returns {:error, :name_taken} when (owner, name) already exists",
         %{user: user} do
      assert {:ok, _} = Lenies.Collection.create_codeome(user, @valid_attrs)

      # Second create with same name MUST fail (no silent overwrite — the
      # save-evolved-Lenie flow is fork-only and surfaces this as an inline
      # form error).
      assert {:error, :name_taken} =
               Lenies.Collection.create_codeome(user, %{@valid_attrs | opcodes: ["eat", "move"]})

      # Original row untouched.
      assert [only] = Lenies.Collection.list_codeomes(user)
      assert only.opcodes == ["nop_1", "store", "eat"]
    end

    test "create_codeome/2 with a different name succeeds for the same user", %{user: user} do
      assert {:ok, _} =
               Lenies.Collection.create_codeome(user, %{@valid_attrs | name: "alpha"})

      assert {:ok, _} =
               Lenies.Collection.create_codeome(user, %{@valid_attrs | name: "beta"})

      assert length(Lenies.Collection.list_codeomes(user)) == 2
    end

    test "create_codeome/2 — two users may use the same codeome name (scope is per-owner)",
         %{user: user, other: other} do
      assert {:ok, _} = Lenies.Collection.create_codeome(user, @valid_attrs)
      assert {:ok, _} = Lenies.Collection.create_codeome(other, @valid_attrs)
    end

    test "list_codeomes/1 returns only the owner's rows", %{user: user, other: other} do
      {:ok, _} = Lenies.Collection.create_codeome(user, @valid_attrs)
      {:ok, _} = Lenies.Collection.create_codeome(other, %{@valid_attrs | name: "Theirs"})
      assert [c] = Lenies.Collection.list_codeomes(user)
      assert c.name == "My Seed"
    end

    test "get_codeome/2 is owner-scoped", %{user: user, other: other} do
      {:ok, c} = Lenies.Collection.create_codeome(user, @valid_attrs)
      assert Lenies.Collection.get_codeome(user, c.id).id == c.id
      assert Lenies.Collection.get_codeome(other, c.id) == nil
    end

    test "delete_codeome/2 removes only the owner's row", %{user: user, other: other} do
      {:ok, c} = Lenies.Collection.create_codeome(user, @valid_attrs)
      assert {:error, :not_found} = Lenies.Collection.delete_codeome(other, c.id)
      assert {:ok, _} = Lenies.Collection.delete_codeome(user, c.id)
      assert Lenies.Collection.list_codeomes(user) == []
    end

    test "to_opcode_atoms/1 converts string opcodes to atoms", %{user: user} do
      {:ok, c} = Lenies.Collection.create_codeome(user, @valid_attrs)
      assert Lenies.Collection.to_opcode_atoms(c) == [:nop_1, :store, :eat]
    end

    test "get_codeome/2 returns nil for a non-integer id", %{user: user} do
      assert Lenies.Collection.get_codeome(user, "garbage") == nil
      assert Lenies.Collection.get_codeome(user, "5abc") == nil
    end

    test "delete_codeome/2 returns :not_found for a non-integer id", %{user: user} do
      assert {:error, :not_found} = Lenies.Collection.delete_codeome(user, "garbage")
    end
  end

  describe "get_codeome_by_name/2" do
    import Lenies.AccountsFixtures

    setup do
      %{user: user_fixture()}
    end

    test "finds own codeome by exact (trimmed) name", %{user: user} do
      {:ok, c} = Lenies.Collection.create_codeome(user, %{@valid_attrs | name: "replicator"})

      assert %Lenies.Collection.Codeome{id: id} =
               Lenies.Collection.get_codeome_by_name(user, "replicator")

      assert id == c.id
      assert Lenies.Collection.get_codeome_by_name(user, "  replicator  ").id == c.id
    end

    test "nil for unknown name and for other users' codeomes", %{user: user} do
      other = user_fixture()
      {:ok, _} = Lenies.Collection.create_codeome(other, %{@valid_attrs | name: "theirs"})
      assert Lenies.Collection.get_codeome_by_name(user, "theirs") == nil
      assert Lenies.Collection.get_codeome_by_name(user, "nope") == nil
    end
  end

  describe "overwrite_codeome/2" do
    import Lenies.AccountsFixtures

    setup do
      %{user: user_fixture()}
    end

    test "updates the existing row in place (same id, new content)", %{user: user} do
      {:ok, c} = Lenies.Collection.create_codeome(user, %{@valid_attrs | name: "evo"})

      attrs = %{
        @valid_attrs
        | name: "evo",
          color_hex: "#112233",
          opcodes: ["eat", "move", "eat", "move", "eat", "move", "eat", "move"]
      }

      assert {:ok, updated} = Lenies.Collection.overwrite_codeome(user, attrs)

      assert updated.id == c.id
      assert updated.color_hex == "#112233"
      assert hd(updated.opcodes) == "eat"
      assert length(Lenies.Collection.list_codeomes(user)) == 1
    end

    test "degrades to create when no row has that name", %{user: user} do
      assert {:ok, created} =
               Lenies.Collection.overwrite_codeome(user, %{@valid_attrs | name: "fresh"})

      assert created.name == "fresh"
    end

    test "cannot overwrite another user's codeome (scoped lookup creates own row)", %{user: user} do
      other = user_fixture()

      {:ok, theirs} =
        Lenies.Collection.create_codeome(other, %{@valid_attrs | name: "shared-name"})

      assert {:ok, mine} =
               Lenies.Collection.overwrite_codeome(user, %{@valid_attrs | name: "shared-name"})

      assert mine.id != theirs.id
      assert Lenies.Collection.get_codeome(other, theirs.id).opcodes == theirs.opcodes
    end

    test "invalid attrs surface the changeset", %{user: user} do
      {:ok, _} = Lenies.Collection.create_codeome(user, %{@valid_attrs | name: "evo2"})

      assert {:error, %Ecto.Changeset{}} =
               Lenies.Collection.overwrite_codeome(user, %{
                 @valid_attrs
                 | name: "evo2",
                   color_hex: "nope"
               })
    end
  end

  describe "plasmid persistence" do
    setup do
      %{user: Lenies.AccountsFixtures.user_fixture()}
    end

    test "create_codeome persists plasmids and get_codeome returns them", %{user: user} do
      attrs = %{
        name: "Twitchy",
        color_hex: "#00ff88",
        energy_default: 500.0,
        opcodes: ["nop_1", "store", "eat"],
        plasmids: [%{opcodes: ["nop_0", "move"]}, %{opcodes: ["eat"]}]
      }

      assert {:ok, saved} = Lenies.Collection.create_codeome(user, attrs)
      reloaded = Lenies.Collection.get_codeome(user, saved.id)

      assert [
               %Lenies.Collection.Plasmid{opcodes: ["nop_0", "move"]},
               %Lenies.Collection.Plasmid{opcodes: ["eat"]}
             ] = reloaded.plasmids
    end

    test "a seed saved without plasmids has an empty list", %{user: user} do
      attrs = %{name: "Plain", color_hex: "#112233", energy_default: 500.0, opcodes: ["eat"]}
      assert {:ok, saved} = Lenies.Collection.create_codeome(user, attrs)
      assert Lenies.Collection.get_codeome(user, saved.id).plasmids == []
    end

    test "to_plasmid_structs/1 converts embeds to runtime Plasmid structs", %{user: user} do
      attrs = %{
        name: "Conv",
        color_hex: "#445566",
        energy_default: 500.0,
        opcodes: ["eat"],
        plasmids: [%{opcodes: ["nop_0", "move"]}, %{opcodes: ["eat"]}]
      }

      {:ok, saved} = Lenies.Collection.create_codeome(user, attrs)
      reloaded = Lenies.Collection.get_codeome(user, saved.id)

      assert [%Lenies.Plasmid{opcodes: [:nop_0, :move]}, %Lenies.Plasmid{opcodes: [:eat]}] =
               Lenies.Collection.to_plasmid_structs(reloaded)

      assert Lenies.Collection.to_plasmid_structs(%Lenies.Collection.Codeome{plasmids: []}) == []
    end

    test "rejects a plasmid embed with an unknown opcode", %{user: user} do
      attrs = %{
        name: "BadP",
        color_hex: "#778899",
        energy_default: 500.0,
        opcodes: ["eat"],
        plasmids: [%{opcodes: ["not_an_opcode"]}]
      }

      assert {:error, %Ecto.Changeset{}} = Lenies.Collection.create_codeome(user, attrs)
    end
  end
end
