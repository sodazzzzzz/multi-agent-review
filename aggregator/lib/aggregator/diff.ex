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

  @type t :: %{optional(String.t()) => MapSet.t(pos_integer())}

  @doc "Построить индекс: файл (new path) → MapSet RIGHT-строк, присутствующих в хунках."
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
      {:ok, set} -> MapSet.member?(set, line)
      :error -> false
    end
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
      "+" <> _ -> %{state | right: right + 1, acc: record(acc, file, right)}
      " " <> _ -> %{state | right: right + 1, acc: record(acc, file, right)}
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
  defp record(acc, nil, _line), do: acc

  defp record(acc, file, line),
    do: Map.update(acc, file, MapSet.new([line]), &MapSet.put(&1, line))
end
