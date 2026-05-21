defmodule Lenies.Slug do
  @moduledoc """
  Turns a human name into a URL/id-safe slug.

  When the input contains no alphanumeric characters (e.g. `"###"`), the
  slugified result would be an empty string, which is unsafe as an id.
  In that case `slugify/1` returns `"x"` as a non-empty fallback.
  """

  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: "x", else: slug
  end
end
