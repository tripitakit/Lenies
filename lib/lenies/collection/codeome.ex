defmodule Lenies.Collection.Codeome do
  @moduledoc """
  A user-owned codeome (the personal-collection equivalent of a seed).
  Validations mirror the global built-in seed definitions.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @hex_re ~r/^#[0-9a-fA-F]{6}$/
  @alnum_re ~r/[a-zA-Z0-9]/

  schema "codeomes" do
    field :name, :string
    field :color_hex, :string
    field :energy_default, :float, default: 10_000.0
    field :opcodes, {:array, :string}
    belongs_to :owner, Lenies.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(codeome, attrs) do
    codeome
    |> cast(attrs, [:name, :color_hex, :energy_default, :opcodes])
    |> update_change(:name, &maybe_trim/1)
    |> validate_required([:name, :color_hex, :energy_default, :opcodes])
    |> validate_format(:name, @alnum_re, message: "must contain a letter or digit")
    |> validate_format(:color_hex, @hex_re, message: "must be a #RRGGBB hex colour")
    |> validate_opcodes()
  end

  defp maybe_trim(nil), do: nil
  defp maybe_trim(s) when is_binary(s), do: String.trim(s)

  defp validate_opcodes(changeset) do
    validate_change(changeset, :opcodes, fn :opcodes, opcodes ->
      cap = elem(Lenies.Config.codeome_length_bounds(), 1)
      whitelist = MapSet.new(Enum.map(Lenies.Codeome.Opcodes.all(), &Atom.to_string/1))

      cond do
        opcodes == [] ->
          [opcodes: "can't be empty"]

        length(opcodes) > cap ->
          [opcodes: "exceeds the maximum length of #{cap}"]

        not Enum.all?(opcodes, &MapSet.member?(whitelist, &1)) ->
          [opcodes: "contains an unknown opcode"]

        true ->
          []
      end
    end)
  end
end
