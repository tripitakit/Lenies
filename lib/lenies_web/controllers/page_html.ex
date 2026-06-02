defmodule LeniesWeb.PageHTML do
  use LeniesWeb, :html

  embed_templates "page_html/*"

  @doc """
  Current application version (SemVer MAJOR.MINOR.PATCH), read from the
  compiled `:lenies` app spec — whose single source of truth is the
  `version:` in `mix.exs`. Bumped on every push (PATCH by default).
  """
  def version, do: Application.spec(:lenies, :vsn) |> List.to_string()
end
