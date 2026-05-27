defmodule Lenies.Repo.Migrations.CreateCodeomes do
  use Ecto.Migration

  def change do
    create table(:codeomes) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color_hex, :string, null: false
      add :energy_default, :float, null: false, default: 10000.0
      add :opcodes, {:array, :string}, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:codeomes, [:owner_id])
    create unique_index(:codeomes, [:owner_id, :name])
  end
end
