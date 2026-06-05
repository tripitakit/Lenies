defmodule Lenies.Repo.Migrations.AddPlasmidsToCodeomes do
  use Ecto.Migration

  def change do
    # embeds_many → jsonb. Ecto recommends a :map column for embeds_many.
    # Nullable: Ecto loads a nil value as [] for embeds_many; new inserts write
    # [] from the schema default.
    alter table(:codeomes) do
      add :plasmids, :map
    end
  end
end
