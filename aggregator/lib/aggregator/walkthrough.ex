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
  @type file_change :: %{path: String.t(), change: String.t()}
  @type group :: %{title: String.t(), summary: String.t(), files: [file_change()]}
  @type t :: %{tldr: String.t(), groups: [group()], mermaid: String.t() | nil}

  # Сколько символов диффа отдаём модели. Диффы бывают огромны, а для обзора нужен смысл,
  # не каждая строка — режем по бюджету (дёшево и достаточно для TL;DR/таблицы).
  @diff_budget 12_000

  # Лимиты, чтобы большой PR не раздувал обзор: когорт всего и файлов в одной когорте.
  @max_groups 10
  @max_files 15

  @preamble """
  You are summarizing a pull request for reviewers. Read the unified diff below and produce a concise walkthrough.
  Reply STRICTLY with a single JSON object and nothing else, of the form:
  {"tldr": "<1-3 sentence plain-English summary of what this PR does>",
   "groups": [
     {"title": "<short theme / subsystem name>",
      "summary": "<one phrase on what this group of files changes>",
      "files": [{"path": "<file path>", "change": "<one short phrase on what changed in this file>"}]}
   ],
   "mermaid": "<optional Mermaid diagram of the main flow, or an empty string>"}
  Rules: plain English, no markdown inside any field. Keep "tldr" under ~60 words. GROUP related files into
  cohorts by subsystem/theme (e.g. "Config", "API", "Tests", "Docs"); a small PR may be a single group. Each
  file appears once under its group with a short per-file change. For "mermaid": include a diagram ONLY if it
  genuinely clarifies the change and is valid Mermaid (e.g. `sequenceDiagram` or `flowchart TD`); else use "".
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
        groups: parse_groups(obj),
        mermaid: parse_mermaid(Map.get(obj, "mermaid"))
      }
    else
      _ -> nil
    end
  end

  def parse(_non_binary), do: nil

  # Когорты: список групп. Если модель проигнорировала группировку и вернула плоский
  # `files` — заворачиваем его в одну безымянную когорту (терпимость к дрейфу модели).
  defp parse_groups(obj) do
    case obj |> Map.get("groups") |> normalize_groups() do
      [] ->
        case parse_files(Map.get(obj, "files")) do
          [] -> []
          files -> [%{title: "", summary: "", files: files}]
        end

      groups ->
        groups
    end
  end

  defp normalize_groups(list) when is_list(list),
    do: list |> Enum.flat_map(&parse_group/1) |> Enum.take(@max_groups)

  defp normalize_groups(_non_list), do: []

  # Принимаем любую map-группу: title НЕобязателен (рендер умеет безымянную когорту) —
  # иначе группа с файлами, но без title терялась бы целиком. Пустую целиком отбрасываем.
  defp parse_group(group) when is_map(group) do
    title = trimmed_string(Map.get(group, "title"))
    summary = trimmed_string(Map.get(group, "summary"))
    files = parse_files(Map.get(group, "files"))

    if title == "" and summary == "" and files == [],
      do: [],
      else: [%{title: title, summary: summary, files: files}]
  end

  defp parse_group(_non_group), do: []

  defp parse_files(list) when is_list(list),
    do: list |> Enum.flat_map(&file_entry/1) |> Enum.take(@max_files)

  defp parse_files(_non_list), do: []

  # Изменение файла — первый НЕпустой из "change" или (дрейф модели) "summary"; путь
  # обязателен. (Пустой "change" не должен затирать осмысленный "summary".)
  defp file_entry(%{"path" => path} = file) when is_binary(path) do
    change = first_nonblank([Map.get(file, "change"), Map.get(file, "summary")])

    case String.trim(path) do
      "" -> []
      trimmed -> [%{path: trimmed, change: change}]
    end
  end

  defp file_entry(_non_file), do: []

  defp first_nonblank(values) do
    Enum.find_value(values, "", fn v ->
      case trimmed_string(v) do
        "" -> nil
        s -> s
      end
    end)
  end

  defp trimmed_string(s) when is_binary(s), do: String.trim(s)
  defp trimmed_string(_non_binary), do: ""

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
