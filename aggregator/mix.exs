defmodule Aggregator.MixProject do
  use Mix.Project

  def project do
    [
      app: :aggregator,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      releases: releases()
    ]
  end

  # Релиз под Docker-action: один self-contained бинарь, энтрипоинт — eval main/0.
  defp releases do
    [
      aggregator: [
        include_executables_for: [:unix],
        strip_beams: Mix.env() == :prod
      ]
    ]
  end

  # Запускаем эти задачи в :test, чтобы анализ покрывал и test/support.
  def cli do
    [preferred_envs: [check: :test]]
  end

  # Единая «калитка» Definition of Done — её же гоняет CI по матрице.
  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "deps.audit",
        "dialyzer",
        "test"
      ]
    ]
  end

  # PLT'ы живут под priv/plts (в .gitignore) — CI кэширует их одной директорией.
  defp dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_local_path: "priv/plts",
      plt_add_apps: [:ex_unit, :mix]
    ]
  end

  # В тестах подключаем хелперы из test/support.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Рантайм.
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"},
      {:req, "~> 0.6"},
      # Инструменты разработки/CI (не идут в рантайм-релиз).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end
end
