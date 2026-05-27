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
end
