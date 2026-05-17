defmodule Lenies.Manual do
  @moduledoc """
  In-memory store for the Lenies Programming Manual. Loads every `.md`
  file under `docs/manual/` (or `priv/manual/` in releases) at boot,
  parses each with Earmark, and caches `%{title, html}` per filename.

  The editor page renders chapters from this store on demand. Files
  that fail to parse are logged and skipped; the rest of the manual
  is still served.
  """

  use Agent

  require Logger

  @spec start_link(any()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(fn -> load_all() end, name: __MODULE__)
  end

  @doc "Returns the list of loaded chapters, ordered by filename."
  @spec list_chapters() :: [%{filename: String.t(), title: String.t()}]
  def list_chapters do
    Agent.get(__MODULE__, fn state ->
      state
      |> Enum.map(fn {filename, %{title: title}} ->
        %{filename: filename, title: title}
      end)
      |> Enum.sort_by(& &1.filename)
    end)
  end

  @doc "Returns `%{title, html}` for the given chapter filename, or nil."
  @spec get(String.t()) :: %{title: String.t(), html: String.t()} | nil
  def get(filename) when is_binary(filename) do
    Agent.get(__MODULE__, &Map.get(&1, filename))
  end

  # ----- private -----

  defp load_all do
    dir = manual_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reduce(%{}, fn filename, acc ->
          path = Path.join(dir, filename)

          case load_one(path) do
            {:ok, entry} -> Map.put(acc, filename, entry)
            :error -> acc
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "Lenies.Manual: could not list #{dir} (#{inspect(reason)}); manual unavailable"
        )

        %{}
    end
  end

  defp manual_dir do
    priv = Application.app_dir(:lenies, "priv/manual")

    cond do
      File.dir?(priv) -> priv
      File.dir?("docs/manual") -> Path.expand("docs/manual")
      true -> priv
    end
  end

  defp load_one(path) do
    with {:ok, source} <- File.read(path),
         title when is_binary(title) <- extract_title(source),
         {:ok, html, _warnings} <- Earmark.as_html(source) do
      {:ok, %{title: title, html: html}}
    else
      error ->
        Logger.warning("Lenies.Manual: skipping #{path}: #{inspect(error)}")
        :error
    end
  end

  defp extract_title(source) do
    source
    |> String.split("\n", parts: 2)
    |> List.first()
    |> case do
      "# " <> rest -> String.trim(rest)
      _ -> Path.basename("(untitled)", ".md")
    end
  end
end
