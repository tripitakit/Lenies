defmodule Lenies.Collection do
  @moduledoc """
  Per-user collection of hand-written codeomes. All queries are scoped to an
  owner (a `Lenies.Accounts.User`); a user can only read/modify their own rows.
  Replaces the former global custom-seed store with per-user persistence.
  """
  import Ecto.Query, warn: false
  alias Lenies.Repo
  alias Lenies.Collection.Codeome

  @doc "All codeomes owned by `user`, newest first."
  def list_codeomes(%{id: owner_id}) do
    Repo.all(from c in Codeome, where: c.owner_id == ^owner_id, order_by: [desc: c.inserted_at])
  end

  @doc "Fetch one codeome by id, scoped to `user`. Returns nil if not theirs."
  def get_codeome(%{id: owner_id}, id) do
    case normalize_id(id) do
      nil -> nil
      cid -> Repo.one(from c in Codeome, where: c.owner_id == ^owner_id and c.id == ^cid)
    end
  end

  @doc """
  Create a codeome for `user`. Fork-only: a duplicate `(owner, name)` is
  refused with `{:error, :name_taken}` rather than silently overwriting.
  The save-evolved-Lenie flow surfaces `:name_taken` as an inline form
  error so users always pick a fresh name (no accidental overwrite of a
  previous save).
  """
  def create_codeome(%{id: owner_id}, attrs) do
    %Codeome{owner_id: owner_id}
    |> Codeome.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, codeome} ->
        {:ok, codeome}

      {:error, %Ecto.Changeset{} = cs} ->
        if name_taken?(cs), do: {:error, :name_taken}, else: {:error, cs}
    end
  end

  # The `unique_constraint(:name, ...)` validator on the Codeome changeset
  # surfaces a DB unique-index violation as a `{message, [constraint: :unique, ...]}`
  # error on the :name field. Any other validation error stays a changeset.
  defp name_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:name, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  @doc "Delete a codeome by id, scoped to `user`."
  def delete_codeome(%{id: owner_id}, id) do
    with cid when not is_nil(cid) <- normalize_id(id),
         %Codeome{} = c <-
           Repo.one(from c in Codeome, where: c.owner_id == ^owner_id and c.id == ^cid) do
      Repo.delete(c)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Changeset for forms."
  def change_codeome(%Codeome{} = codeome, attrs \\ %{}) do
    Codeome.changeset(codeome, attrs)
  end

  @doc """
  Convert a codeome's stored string opcodes to interpreter atoms.
  Uses `String.to_existing_atom/1` defensively; the changeset already
  guarantees every element is a known opcode at write time.
  """
  def to_opcode_atoms(%Codeome{opcodes: opcodes}) do
    Enum.map(opcodes, &String.to_existing_atom/1)
  end

  # Normalize a client-supplied id to an integer, or nil if unparseable.
  # Accepts already-integer ids (internal/tests) and strict integer strings.
  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_id(_), do: nil
end
