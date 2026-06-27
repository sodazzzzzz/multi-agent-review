defmodule Aggregator.Cluster do
  @moduledoc """
  Детерминированная кластеризация findings — источник истины по объединённому ревью.

  Агенты часто расходятся на пару строк по одной и той же проблеме, поэтому
  кластер = один `file` + строки в окне `±window` (дефолт 3), а не точный
  `file:line`. После сборки список кластеров и все цифры (консенсус, severity)
  **заморожены**: модель-причёсыватель меняет только текст `message`.

  Поведение жадное и сознательно совпадает с эталонной реализацией:
  привязка идёт к *первому по порядку создания* кластеру, попадающему в окно
  относительно его якорной (первой) строки. Якорь не сдвигается при добавлении
  элементов, поэтому цепочка вида 42 → 45 → 48 при `window: 3` даст {42,45} и
  {48} (48 − 42 = 6 > 3). Это задокументированный дрейф, а не баг — см. тесты.
  """

  alias Aggregator.{Consensus, Finding}

  @default_window 3

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          file: String.t(),
          line: pos_integer() | nil,
          items: [Finding.t()],
          agents: [String.t()],
          consensus: non_neg_integer(),
          severity: String.t() | nil
        }

  defstruct id: nil, file: nil, line: nil, items: [], agents: [], consensus: 0, severity: nil

  @doc """
  Построить отсортированный список кластеров из плоского списка findings.

  Сортировка результата: по консенсусу (убыв.), затем по severity (серьёзнее
  выше). Каждому кластеру присваивается стабильный `id` (1-based) — по нему
  стадия `polish` сопоставляет переписанный текст обратно.
  """
  @spec build([Finding.t()], pos_integer()) :: [t()]
  def build(findings, window \\ @default_window) do
    findings
    |> Enum.sort_by(&sort_key/1)
    |> Enum.reduce([], &insert(&2, &1, window))
    |> finalize()
  end

  # findings с line: nil сортируются в начало (0), но в кластеры не сливаются.
  defp sort_key(%Finding{file: file, line: line}), do: {file, line || 0}

  # Безстрочные findings — всегда собственный кластер (нечего привязывать к строке).
  defp insert(clusters, %Finding{line: nil} = f, _window) do
    clusters ++ [new_cluster(f)]
  end

  # Строчные — в первый подходящий кластер по окну, иначе новый.
  # Аккумулятор держим в порядке создания (append), чтобы «первый подходящий»
  # совпадал с эталонной семантикой. Списки findings малы — O(n^2) здесь неважен.
  defp insert(clusters, %Finding{} = f, window) do
    case Enum.find_index(clusters, &within_window?(&1, f, window)) do
      nil -> clusters ++ [new_cluster(f)]
      idx -> List.update_at(clusters, idx, &add_item(&1, f))
    end
  end

  defp within_window?(%__MODULE__{line: nil}, _f, _window), do: false

  defp within_window?(
         %__MODULE__{file: cfile, line: cline},
         %Finding{file: ffile, line: fline},
         window
       ) do
    cfile == ffile and abs(cline - fline) <= window
  end

  defp new_cluster(%Finding{} = f) do
    %__MODULE__{file: f.file, line: f.line, items: [f]}
  end

  defp add_item(%__MODULE__{} = c, %Finding{} = f) do
    %{c | items: c.items ++ [f]}
  end

  # Посчитать агрегаты, отсортировать, присвоить стабильные id.
  defp finalize(clusters) do
    clusters
    |> Enum.map(&summarize/1)
    |> Enum.sort_by(&order_key/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {c, id} -> %{c | id: id} end)
  end

  defp summarize(%__MODULE__{items: items} = c) do
    %{
      c
      | agents: Consensus.distinct_agents(items),
        consensus: Consensus.count(items),
        severity: Consensus.max_severity(items)
    }
  end

  # Выше — больше консенсус, при равенстве — серьёзнее severity.
  defp order_key(%__MODULE__{consensus: consensus, severity: severity}) do
    {-consensus, Consensus.severity_rank(severity)}
  end
end
