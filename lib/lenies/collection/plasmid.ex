defmodule Lenies.Collection.Plasmid do
  @moduledoc """
  One extra-chromosomal plasmid carried by a saved `Lenies.Collection.Codeome`,
  stored as an `embeds_many` (jsonb). Just an opcode list; the runtime form is
  `Lenies.Plasmid` (see `Lenies.Collection.to_plasmid_structs/1`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :opcodes, {:array, :string}
  end

  @doc false
  def changeset(plasmid, attrs) do
    plasmid
    |> cast(attrs, [:opcodes])
    |> validate_required([:opcodes])
    |> validate_opcodes()
  end

  defp validate_opcodes(changeset) do
    validate_change(changeset, :opcodes, fn :opcodes, opcodes ->
      max = Lenies.Plasmid.max_length()
      whitelist = MapSet.new(Enum.map(Lenies.Codeome.Opcodes.all(), &Atom.to_string/1))

      cond do
        opcodes == [] -> [opcodes: "can't be empty"]
        length(opcodes) > max -> [opcodes: "exceeds the maximum length of #{max}"]
        not Enum.all?(opcodes, &MapSet.member?(whitelist, &1)) -> [opcodes: "contains an unknown opcode"]
        true -> []
      end
    end)
  end
end
