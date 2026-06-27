defmodule Aggregator.Artifacts do
  @moduledoc """
  Чтение и валидация JSON-артефактов агентов из директории.

  `download-artifact` кладёт каждый артефакт в свою поддиректорию, поэтому ищем
  `review-*.json` рекурсивно. Каждый файл декодируется и валидируется по
  `Aggregator.Schema`. Битый/невалидный/отсутствующий файл = «агент упал» — это
  не роняет прогон (отказоустойчивость), а отмечается в `:failed`.
  """

  alias Aggregator.{Finding, Schema}

  @type envelope :: %{agent: String.t(), findings: [Finding.t()]}
  @type failure :: %{source: String.t(), reason: term()}
  @type result :: %{ok: [envelope()], failed: [failure()]}

  @doc "Загрузить и провалидировать все `review-*.json` под `dir`."
  @spec load(Path.t()) :: result()
  def load(dir) do
    {oks, errs} =
      dir
      |> find_files()
      |> Enum.map(&load_one/1)
      |> Enum.split_with(&match?({:ok, _}, &1))

    %{
      ok: Enum.map(oks, fn {:ok, env} -> env end),
      failed: Enum.map(errs, fn {:error, failure} -> failure end)
    }
  end

  @doc """
  Какие из ожидаемых агентов не дали валидного результата.

  Сравниваем по присутствию в `:ok`; используется для отметки «codex: недоступен»
  в summary.
  """
  @spec missing_agents(result(), [String.t()]) :: [String.t()]
  def missing_agents(%{ok: oks}, expected) do
    present = MapSet.new(oks, & &1.agent)
    Enum.reject(expected, &MapSet.member?(present, &1))
  end

  defp find_files(dir) do
    dir
    |> Path.join("**/review-*.json")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp load_one(path) do
    with {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body),
         :ok <- Schema.validate(data) do
      {:ok, %{agent: data["agent"], findings: Finding.from_envelope(data)}}
    else
      {:error, reason} -> {:error, %{source: path, reason: reason}}
    end
  end
end
