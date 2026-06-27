defmodule Aggregator.Factory do
  @moduledoc "Лаконичные хелперы для сборки findings в тестах."

  alias Aggregator.Finding

  @doc """
  Собрать `Finding` с разумными дефолтами.

      finding(agent: "claude", file: "a.ex", line: 10, severity: "P1")
  """
  def finding(opts \\ []) do
    %Finding{
      agent: Keyword.get(opts, :agent, "claude"),
      file: Keyword.get(opts, :file, "lib/a.ex"),
      line: Keyword.get(opts, :line, 1),
      severity: Keyword.get(opts, :severity, "P2"),
      category: Keyword.get(opts, :category, "bug"),
      message: Keyword.get(opts, :message, "msg"),
      suggestion: Keyword.get(opts, :suggestion, nil)
    }
  end
end
