defmodule Lenies.MixProject do
  use Mix.Project

  def project do
    [
      app: :lenies,
      version: "0.1.5",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: [
        lenies: [
          # Custom step: bundle docs/manual/*.md into priv/manual/ so the
          # release self-contains the manual content. Lenies.Manual reads
          # from `Application.app_dir(:lenies, "priv/manual")` in releases;
          # without this copy, prod silently serves no chapters (the dev
          # fallback `__DIR__/../../docs/manual` points outside the release
          # boundary and is not portable). Source of truth stays at
          # docs/manual; priv/manual is gitignored and rebuilt every release.
          steps: [&copy_manual_to_priv/1, :assemble]
        ]
      ]
    ]
  end

  defp copy_manual_to_priv(%Mix.Release{} = release) do
    src = "docs/manual"
    dest = "priv/manual"

    if File.dir?(src) do
      File.rm_rf!(dest)
      File.cp_r!(src, dest)
      n = Path.wildcard(dest <> "/*.md") |> length()
      IO.puts("[release] bundled #{n} manual chapters: #{src}/ -> #{dest}/")
    else
      IO.warn("[release] manual source dir not found: #{src}; release will lack manual content")
    end

    release
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Lenies.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:swoosh, "~> 1.16"},
      {:finch, "~> 0.18"},
      {:bandit, "~> 1.5"},
      {:earmark, "~> 1.4"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind lenies", "esbuild lenies"],
      "assets.deploy": [
        # `compile` must run first so Phoenix.LiveView's compiler can write the
        # virtual `phoenix-colocated/lenies` module that `js/app.js` imports
        # (colocated LiveView JS hooks). Without this, a fresh prod build with
        # empty `_build/prod/` fails esbuild with
        # `Could not resolve "phoenix-colocated/lenies"`.
        "compile",
        "tailwind lenies --minify",
        "esbuild lenies --minify",
        "phx.digest"
      ],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
