defmodule Aggregator.Diff do
  @moduledoc """
  Чистый парсер unified diff → множество строк новой версии (RIGHT) внутри хунков.

  Нужен для pre-flight: однокликовый `suggestion` можно привязать только к строке,
  которая попадает в дифф, иначе Pulls API вернёт 422. Строка «в хунке», если у
  неё есть номер на RIGHT-стороне — то есть добавленная (`+`) или контекстная (` `);
  удалённые (`-`) строки RIGHT-номера не имеют.

  Парсер ведёт явный флаг in_hunk, чтобы заголовки файла (`--- a/…`, `+++ b/…`) не
  путались с контентом (содержимое строки тоже может начинаться с `-`/`+`).
  """

  @type t :: %{optional(String.t()) => MapSet.t(pos_integer())}

  @doc "Построить индекс: файл (new path) → MapSet RIGHT-строк, присутствующих в хунках."
  @spec right_lines(String.t()) :: t()
  def right_lines(patch) when is_binary(patch) do
    patch
    |> String.split("\n")
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

  # Новый файл: путь берём из "diff --git a/… b/…" (однозначный маркер), сбрасываем хунк.
  defp step("diff --git " <> rest, state) do
    %{state | file: new_path(rest), right: 0, in_hunk: false}
  end

  # Заголовок хунка "@@ -a,b +c,d @@": стартовая RIGHT-строка = c, входим в хунк.
  defp step("@@" <> _ = line, state) do
    %{state | right: hunk_start(line), in_hunk: true}
  end

  # Вне хунка (заголовки index/---/+++/режимы) — игнорируем.
  defp step(_line, %{in_hunk: false} = state), do: state

  # Внутри хунка считаем RIGHT-строки.
  defp step(line, %{in_hunk: true, file: file, right: right, acc: acc} = state) do
    case line do
      "+" <> _ -> %{state | right: right + 1, acc: record(acc, file, right)}
      " " <> _ -> %{state | right: right + 1, acc: record(acc, file, right)}
      "-" <> _ -> state
      "\\" <> _ -> state
      _ -> state
    end
  end

  # "a/lib/x.ex b/lib/x.ex" → "lib/x.ex" (new-сторона после " b/").
  defp new_path(rest) do
    case String.split(rest, " b/", parts: 2) do
      [_a, b] -> b
      _ -> nil
    end
  end

  defp hunk_start(line) do
    case Regex.run(~r/\+(\d+)/, line) do
      [_, n] -> String.to_integer(n)
      _ -> 1
    end
  end

  defp record(acc, file, line) do
    Map.update(acc, file, MapSet.new([line]), &MapSet.put(&1, line))
  end
end
