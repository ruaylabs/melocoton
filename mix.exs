defmodule Melocoton.MixProject do
  use Mix.Project

  def project do
    [
      app: :melocoton,
      version: "0.33.1",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 60]],
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Melocoton.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases do
    [
      melocoton: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux: [os: :linux, cpu: :x86_64],
            linux_arm: [os: :linux, cpu: :aarch64],
            macos: [os: :darwin, cpu: :aarch64],
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:postgrex, "~> 0.22.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1"},
      {:lazy_html, ">= 0.0.0", only: :test},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:lucide,
       github: "lucide-icons/lucide",
       tag: "v0.265.0",
       sparse: "icons",
       app: false,
       compile: false,
       depth: 1},
      {:gettext, "~> 0.20"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"},
      {:burrito, "~> 1.5"},
      {:csv, "~> 3.2"},
      {:elixlsx, "~> 0.6"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:req_llm, "~> 1.8"},
      {:earmark, "~> 1.4"},
      {:makeup, "~> 1.0"},
      {:makeup_sql, "~> 0.1"},
      {:html_sanitize_ex, "~> 1.4"},
      {:myxql, "~> 0.8"},
      {:testcontainers, "~> 2.0", only: [:dev, :test]},
      # Security fix (GHSA-52mm-h59v-f3c7 & friends): earmark is abandoned and retired;
      # hackney 1.x has unpatched SSRF/CRLF advisories. Pin 4.x (first patched 4.0.1).
      {:hackney, "~> 4.8", override: true}
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
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind melocoton", "esbuild melocoton", &copy_fonts/1],
      "assets.deploy": [
        "tailwind melocoton --minify",
        "esbuild melocoton --minify",
        &copy_fonts/1,
        "phx.digest"
      ],
      ci: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "credo --strict",
        "deps.audit --ignore-file .deps_audit_ignore",
        "test --cover"
      ]
    ]
  end

  defp copy_fonts(_) do
    source = "assets/node_modules/@fontsource/jetbrains-mono/files"
    dest = "priv/static/fonts"
    File.mkdir_p!(dest)

    Enum.each(
      ~w(jetbrains-mono-latin-400-normal.woff2 jetbrains-mono-latin-400-normal.woff),
      &File.cp!(Path.join(source, &1), Path.join(dest, &1))
    )
  end
end
