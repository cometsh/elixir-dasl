defmodule DASL.MixProject do
  use Mix.Project

  @version "0.1.0"
  @github "https://github.com/cometsh/elixir-dasl"
  @tangled "https://tangled.org/@comet.sh/elixir-dasl"

  def project do
    [
      app: :dasl,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "dasl",
      description: "An Elixir implementation of DASL primitives.",
      package: package(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cbor, "~> 1.0.0"},
      {:typedstruct, "~> 0.5"},
      {:varint, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @github, "Tangled" => @tangled}
    ]
  end

  defp docs do
    [
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      main: "readme",
      source_url: @github,
      source_ref: "v#{@version}",
      formatters: ["html"]
    ]
  end
end
