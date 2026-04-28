defmodule SelectoDBPostgreSQL.MixProject do
  use Mix.Project

  @version "0.4.3"
  @source_url "https://github.com/seeken/selecto_db_postgresql"

  def project do
    [
      app: :selecto_db_postgresql,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "SelectoDBPostgreSQL",
      description: "PostgreSQL adapter package for Selecto",
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      selecto_dep(),
      {:postgrex, ">= 0.0.0"},
      {:ecto_sql, "~> 3.12"},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false}
    ]
  end

  defp selecto_dep do
    if use_local_ecosystem?() do
      {:selecto, path: "../selecto"}
    else
      {:selecto, ">= 0.4.0 and < 0.6.0"}
    end
  end

  defp use_local_ecosystem? do
    case System.get_env("SELECTO_ECOSYSTEM_USE_LOCAL") do
      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
      value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] -> false
      _ -> File.dir?(Path.expand("../selecto", __DIR__))
    end
  end

  defp package do
    [
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs),
      licenses: ["MIT"],
      links: %{
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "GitHub" => @source_url,
        "Selecto" => "https://github.com/seeken/selecto"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
