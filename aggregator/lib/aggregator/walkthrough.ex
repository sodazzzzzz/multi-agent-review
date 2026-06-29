defmodule Aggregator.Walkthrough do
  @moduledoc """
  LLM-обзор PR («walkthrough») для верхней части summary: TL;DR + таблица «файл → что
  изменилось» + (опционально) mermaid-диаграмма основного потока.

  Best-effort, ровно как `Aggregator.Polish`: чистые `prompt/2` (строит запрос модели)
  и `parse/1` (терпимый разбор ответа в нормализованную карту либо `nil`). Сам вызов
  модели живёт в эффект-слое (`Aggregator.CLI` через `Aggregator.Claude`), а рендер
  секции — в `Aggregator.Render` (там же экранирование и guard на синтаксис mermaid).
  При любом сбое (нет claude, кривой/пустой ответ) `parse/1` даёт `nil` → секция просто
  не появляется. Walkthrough не влияет на цифры и не может ронять прогон.
  """

  alias Aggregator.Cluster

  @typedoc "Нормализованный обзор: непустой TL;DR, список файлов, mermaid либо nil."
  @type t :: %{
          tldr: String.t(),
          files: [%{path: String.t(), summary: String.t()}],
          mermaid: String.t() | nil
        }

  # Сколько символов диффа отдаём модели. Диффы бывают огромны, а для обзора нужен смысл,
  # не каждая строка — режем по бюджету (дёшево и достаточно для TL;DR/таблицы).
  @diff_budget 12_000

  # Максимум строк в таблице файлов — большие PR не должны раздувать обзор.
  @max_files 12

  @preamble """
  You are summarizing a pull request for reviewers. Read the unified diff below and produce a concise walkthrough.
  Reply STRICTLY with a single JSON object and nothing else, of the form:
  {"tldr": "<1-3 sentence plain-English summary of what this PR does>",
   "files": [{"path": "<file path>", "summary": "<one short phrase on what changed>"}],
   "mermaid": "<optional Mermaid diagram of the main flow, or an empty string>"}
  Rules: plain English, no markdown inside any field. Keep "tldr" under ~60 words. List only the
  most important files. For "mermaid": include a diagram ONLY if it genuinely clarifies the change
  and is valid Mermaid (e.g. starting with `sequenceDiagram` or `flowchart TD`); otherwise use "".
  """

  @doc "Построить промпт обзора из текста диффа (кластеры пока не используются — задел)."
  @spec prompt(String.t(), [Cluster.t()]) :: String.t()
  def prompt(diff_text, _clusters \\ []) when is_binary(diff_text) do
    @preamble <> "\n\nUnified diff:\n" <> trim_diff(diff_text)
  end

  defp trim_diff(diff) do
    if String.length(diff) > @diff_budget,
      do: String.slice(diff, 0, @diff_budget) <> "\n… [diff truncated]",
      else: diff
  end

  @doc """
  Разобрать сырой ответ модели в нормализованный обзор либо `nil`.

  Принимает чистый JSON-объект или JSON в ```-заборе/с прозой вокруг (выкусываем
  `{...}`). Требует непустой строковый `tldr`; `files`/`mermaid` нормализуются
  терпимо (мусорные элементы отброшены). Любой иной ввод → `nil`.
  """
  @spec parse(term()) :: t() | nil
  def parse(raw) when is_binary(raw) do
    with {:ok, obj} <- extract_object(raw),
         tldr when is_binary(tldr) <- Map.get(obj, "tldr"),
         trimmed when trimmed != "" <- String.trim(tldr) do
      %{
        tldr: trimmed,
        files: parse_files(Map.get(obj, "files")),
        mermaid: parse_mermaid(Map.get(obj, "mermaid"))
      }
    else
      _ -> nil
    end
  end

  def parse(_non_binary), do: nil

  defp parse_files(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"path" => p, "summary" => s} when is_binary(p) and is_binary(s) ->
        case {String.trim(p), String.trim(s)} do
          {"", _} -> []
          {path, summary} -> [%{path: path, summary: summary}]
        end

      _other ->
        []
    end)
    |> Enum.take(@max_files)
  end

  defp parse_files(_non_list), do: []

  defp parse_mermaid(m) when is_binary(m) do
    case String.trim(m) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_mermaid(_non_binary), do: nil

  # Сначала весь текст как JSON-объект; если модель добавила прозу/```-забор — выкусываем
  # подстроку от первой `{` до последней `}` (жадный `.*` с флагом /s).
  defp extract_object(text) do
    trimmed = String.trim(text)

    case Jason.decode(trimmed) do
      {:ok, obj} when is_map(obj) -> {:ok, obj}
      _ -> slice_braces(trimmed)
    end
  end

  defp slice_braces(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] ->
        case Jason.decode(json) do
          {:ok, obj} when is_map(obj) -> {:ok, obj}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
