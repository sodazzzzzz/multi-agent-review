defmodule Aggregator.Claude do
  @moduledoc """
  Эффектная обёртка вызова Claude CLI для причёсывания прозы.

  Единственный эффект слоя: запустить `claude -p <prompt> --output-format json` и
  вернуть СЫРОЙ текст ответа модели. Разбор (`Aggregator.Polish.parse_rewrites/1`) и
  заморозка фактов (`Aggregator.Polish.merge/2`) — чистые и живут отдельно.

  Причёсывание **необязательно**: при любом сбое (нет бинаря, ненулевой код, кривой
  вывод) возвращаем `""`. Тогда `parse_rewrites/1` даст `[]`, `merge/2` — пустые
  overrides, и `Aggregator.Render` просто покажет детерминированный текст. Полировка
  никогда не должна ронять прогон.

  Точные флаги CLI вынесены в `args/2` и переопределяемы через опции — на случай
  тюнинга под конкретную версию `claude`.
  """

  require Logger

  @default_model "claude-opus-4-8"
  @default_bin "claude"
  @default_timeout_ms 120_000

  @doc """
  Причесать прозу: отдать модели `prompt`, вернуть сырой текст ответа (или `""`).

  Опции:
    * `:model` — id модели (дефолт `#{@default_model}`);
    * `:bin`   — путь/имя бинаря (дефолт `#{@default_bin}`; для тестов — фейк-скрипт);
    * `:timeout_ms` — таймаут процесса (дефолт 120000).
  """
  @spec rewrite(String.t(), keyword()) :: String.t()
  def rewrite(prompt, opts \\ []) when is_binary(prompt) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    task = Task.async(fn -> run(prompt, opts) end)

    # System.cmd сам по себе таймаута НЕ имеет: зависший claude подвесил бы весь
    # прогон до job-таймаута раннера. Оборачиваем в Task — по таймауту brutal_kill
    # закрывает порт и убивает внешний процесс. Причёсывание best-effort → "".
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, raw} ->
        raw

      _timeout_or_crash ->
        Logger.warning("claude не уложился в #{timeout} мс; пропускаю причёсывание")
        ""
    end
  end

  # Выполняется внутри Task; любой сбой ловим здесь и отдаём "", чтобы Task не упал
  # (иначе линк уронил бы вызывающего).
  defp run(prompt, opts) do
    bin = Keyword.get(opts, :bin, @default_bin)

    case System.cmd(bin, args(prompt, opts), stderr_to_stdout: false) do
      {out, 0} ->
        extract_result(out)

      {_out, code} ->
        Logger.warning("claude вышел с кодом #{code}; пропускаю причёсывание")
        ""
    end
  rescue
    error ->
      Logger.warning("claude недоступен (#{Exception.message(error)}); пропускаю причёсывание")
      ""
  end

  # Заголовочный (headless) режим: -p печатает ответ и выходит; json-конверт даёт
  # стабильную обёртку; одна итерация — причёсывание не агентская задача.
  defp args(prompt, opts) do
    [
      "-p",
      prompt,
      "--model",
      Keyword.get(opts, :model, @default_model),
      "--output-format",
      "json",
      "--max-turns",
      "1"
    ]
  end

  # `--output-format json` печатает {"type":"result","result":"<текст>",...}.
  # Достаём поле result; если формат иной — возвращаем вывод как есть (пусть разбирает Polish).
  defp extract_result(out) do
    case Jason.decode(out) do
      {:ok, %{"result" => result}} when is_binary(result) -> result
      _ -> out
    end
  end
end
