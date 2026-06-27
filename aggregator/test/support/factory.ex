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

  @doc """
  Валидный finding-map (строковые ключи, как в JSON-артефакте, БЕЗ `agent` —
  он живёт на уровне конверта). Полный набор ключей по контракту.
  """
  def finding_map(overrides \\ %{}) do
    Map.merge(
      %{
        "file" => "lib/a.ex",
        "line" => 42,
        "severity" => "P1",
        "category" => "bug",
        "message" => "что-то не так",
        "suggestion" => nil
      },
      overrides
    )
  end

  @doc """
  Валидный конверт агента со строковыми ключами (как `Jason.decode!` артефакта).

      envelope("claude", [finding_map(), finding_map(%{"line" => 7})])
  """
  def envelope(agent \\ "claude", findings \\ nil) do
    %{
      "agent" => agent,
      "findings" => findings || [finding_map()]
    }
  end
end
