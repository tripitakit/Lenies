defmodule Lenies.Worlds do
  @moduledoc """
  Facade for the multi-world simulation engine. Other modules in this file
  will be filled in by later tasks (start_world, stop_world, handle, list,
  spawn_lenie, action, ...). For now only the `id_to_path/1` helper exists.

  ## world_id convention

  - Fixed worlds use atoms: `:primary`, `:arena` (one atom per id, safe).
  - Dynamic worlds use tuples with bounded atoms: `{:sandbox, user_id}` where
    `user_id` is an integer. **Never** `String.to_atom("sandbox_\#{user_id}")`
    — would re-introduce the atom-table pollution that the multi-world design
    explicitly avoids.
  """

  @doc """
  Render a `world_id` as a filesystem- and topic-safe string.

  Examples:
      iex> Lenies.Worlds.id_to_path(:primary)
      "primary"
      iex> Lenies.Worlds.id_to_path({:sandbox, 42})
      "sandbox-42"
  """
  @spec id_to_path(term()) :: String.t()
  def id_to_path(id) when is_atom(id), do: Atom.to_string(id)

  def id_to_path({atom, rest}) when is_atom(atom) do
    "#{atom}-#{rest}"
  end
end
