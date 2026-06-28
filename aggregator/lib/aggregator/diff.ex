defmodule Aggregator.Diff do
  @moduledoc """
  Чистый парсер unified diff → множество строк новой версии (RIGHT) внутри хунков.

  Нужен для pre-flight: однокликовый `suggestion` можно привязать только к строке,
  которая попадает в дифф, иначе Pulls API вернёт 422. Строка «в хунке», если у
  неё есть номер на RIGHT-стороне — то есть добавленная (`+`) или контекстная (` `);
  удалённые (`-`) строки RIGHT-номера не имеют.

  Имя файла берём из заголовка `+++ b/<path>` (а не из `diff --git a/… b/…`): это
  однозначно даже когда путь содержит пробелы или подстроку ` b/`. `+++ /dev/null`
  (удалённый файл) → строки не привязываем. Вход терпим к CRLF.
  """

  @type t :: %{optional(String.t()) => %{optional(pos_integer()) => String.t()}}

  @doc "Построить индекс: файл (new path) → `%{RIGHT-строка => её текст}` внутри хунков."
  @spec right_lines(String.t()) :: t()
  def right_lines(patch) when is_binary(patch) do
    patch
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce(%{file: nil, right: 0, in_hunk: false, acc: %{}}, &step/2)
    |> Map.fetch!(:acc)
  end

  @doc "Попадает ли (file, line) в дифф (RIGHT-сторона)? `nil`-строка — никогда."
  @spec in_hunk?(t(), String.t(), pos_integer() | nil) :: boolean()
  def in_hunk?(_index, _file, nil), do: false

  def in_hunk?(index, file, line) do
    case Map.fetch(index, file) do
      {:ok, lines} -> Map.has_key?(lines, line)
      :error -> false
    end
  end

  @doc "Текст RIGHT-строки `(file, line)` из диффа, либо `nil`, если её там нет."
  @spec line_content(t(), String.t(), pos_integer() | nil) :: String.t() | nil
  def line_content(_index, _file, nil), do: nil

  def line_content(index, file, line) do
    index |> Map.get(file, %{}) |> Map.get(line)
  end

  # Граница файла: путь возьмём из "+++ b/…", здесь только сбрасываем состояние.
  defp step("diff --git " <> _rest, state), do: %{state | file: nil, in_hunk: false}

  # Заголовок хунка "@@ -a,b +c,d @@": стартовая RIGHT-строка = c, входим в хунк.
  defp step("@@" <> _ = line, state), do: %{state | right: hunk_start(line), in_hunk: true}

  # До хунка — заголовки файла; внутри хунка — контент.
  defp step(line, %{in_hunk: false} = state), do: header(line, state)
  defp step(line, %{in_hunk: true} = state), do: content(line, state)

  # Имя нового файла однозначно из "+++ b/path"; удалённый файл — без привязки строк.
  defp header("+++ /dev/null", state), do: %{state | file: nil}
  defp header("+++ b/" <> path, state), do: %{state | file: path}
  defp header(_other, state), do: state

  defp content(line, %{file: file, right: right, acc: acc} = state) do
    case line do
      "+" <> rest -> %{state | right: right + 1, acc: record(acc, file, right, rest)}
      " " <> rest -> %{state | right: right + 1, acc: record(acc, file, right, rest)}
      "-" <> _ -> state
      "\\" <> _ -> state
      _ -> state
    end
  end

  defp hunk_start(line) do
    case Regex.run(~r/\+(\d+)/, line) do
      [_, n] -> String.to_integer(n)
      _ -> 1
    end
  end

  # nil-файл (например, после "+++ /dev/null") строк не накапливает.
  defp record(acc, nil, _line, _text), do: acc

  defp record(acc, file, line, text),
    do: Map.update(acc, file, %{line => text}, &Map.put(&1, line, text))
end
