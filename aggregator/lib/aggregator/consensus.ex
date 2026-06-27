defmodule Aggregator.Consensus do
  @moduledoc """
  Чистая арифметика severity и консенсуса.

  Источник истины по «насколько серьёзно» и «сколько агентов согласны».
  Эти числа считаются ТОЛЬКО кодом и после стадии кластеризации заморожены —
  модель-причёсыватель (`polish`) не имеет права их менять.
  """

  # Меньший ранг = серьёзнее. P0 — самый серьёзный (блокирует merge).
  @rank %{"P0" => 0, "P1" => 1, "P2" => 2}

  @doc "Числовой ранг severity. Меньше = серьёзнее. Падает на неизвестном значении (намеренно)."
  @spec severity_rank(String.t()) :: non_neg_integer()
  def severity_rank(severity), do: Map.fetch!(@rank, severity)

  @doc """
  Максимальная (самая серьёзная) severity среди findings.

  P0 > P1 > P2. Реализовано как `min_by` по рангу, потому что меньший ранг —
  серьёзнее. Не «чини» на `max_by`: это перевернёт блокировку merge.
  """
  @spec max_severity([Aggregator.Finding.t()]) :: String.t()
  def max_severity(findings) do
    findings
    |> Enum.map(& &1.severity)
    |> Enum.min_by(&severity_rank/1)
  end

  @doc """
  Консенсус = число *разных* агентов, поднявших замечание.

  Два findings от одного агента на одной строке = консенсус 1, а не 2.
  """
  @spec count([Aggregator.Finding.t()]) :: non_neg_integer()
  def count(findings) do
    findings
    |> distinct_agents()
    |> length()
  end

  @doc "Отсортированный список уникальных агентов в наборе findings."
  @spec distinct_agents([Aggregator.Finding.t()]) :: [String.t()]
  def distinct_agents(findings) do
    findings
    |> Enum.map(& &1.agent)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Есть ли среди findings хоть один блокирующий (`P0`)."
  @spec blocking?([Aggregator.Finding.t()]) :: boolean()
  def blocking?(findings) do
    Enum.any?(findings, &(&1.severity == "P0"))
  end
end
