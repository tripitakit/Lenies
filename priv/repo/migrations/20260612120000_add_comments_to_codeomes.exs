defmodule Lenies.Repo.Migrations.AddCommentsToCodeomes do
  use Ecto.Migration

  def change do
    alter table(:codeomes) do
      # Non-executable cell annotations, keyed by flat exec index (as a string)
      # → comment text. Stripped before the codeome is built for the VM.
      add :comments, :map, null: false, default: %{}
    end
  end
end
