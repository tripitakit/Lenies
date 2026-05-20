defmodule Lenies.Slug do
  @moduledoc """
  Turns a human name into a URL/id-safe slug.
  """

  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
