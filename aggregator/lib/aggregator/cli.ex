defmodule Aggregator.CLI do
  @moduledoc """
  Точка входа аггрегатора: связывает чистое ядро и эффект-слой в один прогон.

  Поток: артефакты агентов → flatten findings → кластеризация (заморозка цифр) →
  причёсывание прозы (best-effort, факты заморожены) → решение gating → отрисовка →
  постинг в GitHub → запись `GITHUB_OUTPUT` → код выхода по `Aggregator.Gate`.

  `run/2` принимает уже собранный `Aggregator.Github`-клиент и конфиг — так его
  можно прогнать в тестах из конца в конец без сети (фейковый Req-адаптер) и без
  установленного `claude` (фейк-скрипт). `run/0` собирает то и другое из окружения.
  Эффекты тонкие; вся логика — в чистых модулях, которые здесь только склеиваются.
  """

  require Logger

  alias Aggregator.{Artifacts, Claude, Cluster, Gate, Github, Polish, Render}

  @expected_agents ["claude", "codex", "deepseek"]
  @default_model "claude-opus-4-8"

  @doc "Энтрипоинт релиза: прогнать и завершить процесс кодом выхода Gate."
  @spec main() :: no_return()
  def main do
    # Релиз вызывается через `bin/aggregator eval` — приложения загружены, но не
    # запущены; поднимаем :aggregator (тянет :req/:finch/:logger) перед прогоном.
    {:ok, _started} = Application.ensure_all_started(:aggregator)
    run() |> System.halt()
  end

  @doc "Собрать клиент и конфиг из окружения и выполнить прогон."
  @spec run() :: 0 | 1
  def run do
    run(client_from_env(), config_from_env())
  end

  @doc """
  Выполнить прогон с явными зависимостями. Возвращает код выхода (`Aggregator.Gate`).

  `cfg` — map: `:reviews_dir`, `:diff_path` (nil → без inline-комментов),
  `:window`, `:fail_on`, `:model`, `:claude_bin`, `:expected_agents`, `:github_output`.
  """
  @spec run(Github.t(), map()) :: 0 | 1
  def run(%Github{} = client, cfg) do
    %{ok: oks} = result = Artifacts.load(cfg.reviews_dir)

    clusters =
      oks
      |> Enum.flat_map(& &1.findings)
      |> Cluster.build(cfg.window)

    decision = Gate.decide(clusters, Gate.parse_mode(cfg.fail_on))

    output =
      Render.render(clusters, %{
        diff_index: load_diff_index(cfg.diff_path),
        panel_size: length(oks),
        expected: length(cfg.expected_agents),
        failed_agents: Artifacts.missing_agents(result, cfg.expected_agents),
        decision: decision,
        messages: polish(clusters, cfg)
      })

    summary_url = post(client, output)
    write_outputs(cfg.github_output, clusters, decision, summary_url)
    Gate.exit_code(decision)
  end

  # --- причёсывание (best-effort) ---

  defp polish([], _cfg), do: %{}

  defp polish(clusters, cfg) do
    clusters
    |> Polish.prompt()
    |> Claude.rewrite(model: cfg.model, bin: cfg.claude_bin)
    |> Polish.parse_rewrites()
    |> then(&Polish.merge(clusters, &1))
    |> Map.fetch!(:overrides)
  end

  # --- постинг (ошибки логируем, прогон не роняем) ---

  defp post(client, %{summary: summary, comments: comments}) do
    log_result("review", Github.post_review(client, comments))

    case Github.post_summary(client, summary) do
      {:ok, url} when is_binary(url) ->
        url

      other ->
        log_result("summary", other)
        ""
    end
  end

  defp log_result(_what, {:ok, _}), do: :ok

  defp log_result(what, {:error, reason}) do
    Logger.error("постинг #{what} не удался: #{inspect(reason)}")
    :error
  end

  # --- GITHUB_OUTPUT ---

  defp write_outputs(nil, _clusters, _decision, _url), do: :ok

  defp write_outputs(path, clusters, {verdict, _reason}, url) do
    data = [
      {"clusters", length(clusters)},
      {"blocking", verdict == :block},
      {"summary_url", url}
    ]

    content = Enum.map_join(data, "", fn {k, v} -> "#{k}=#{v}\n" end)

    case File.write(path, content, [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("не удалось записать GITHUB_OUTPUT (#{path}): #{inspect(reason)}")
    end
  end

  # --- дифф ---

  defp load_diff_index(nil), do: %{}

  defp load_diff_index(path) do
    case File.read(path) do
      {:ok, patch} -> Aggregator.Diff.right_lines(patch)
      {:error, _} -> %{}
    end
  end

  # --- окружение ---

  defp client_from_env do
    [owner, repo] = String.split(System.fetch_env!("GITHUB_REPOSITORY"), "/", parts: 2)

    Github.new(
      owner: owner,
      repo: repo,
      pr: String.to_integer(System.fetch_env!("PR_NUMBER")),
      token: System.fetch_env!("GITHUB_TOKEN")
    )
  end

  defp config_from_env do
    %{
      reviews_dir: workspace_path(env("REVIEWS_DIR", "reviews")),
      diff_path: optional_workspace_path(System.get_env("DIFF_PATH")),
      window: env_int("CLUSTER_WINDOW", 3),
      fail_on: env("FAIL_ON", "none"),
      model: env("POLISH_MODEL", @default_model),
      claude_bin: env("CLAUDE_BIN", "claude"),
      expected_agents: expected_agents_from_env(),
      github_output: System.get_env("GITHUB_OUTPUT")
    }
  end

  # Размер ожидаемой панели настраивается (EXPECTED_AGENTS, через запятую): чтобы
  # 2-агентная конфигурация показывала N/2, а не вечное «третий не отработал».
  defp expected_agents_from_env do
    case System.get_env("EXPECTED_AGENTS") do
      blank when blank in [nil, ""] -> @expected_agents
      csv -> csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp env(key, default), do: System.get_env(key) || default

  # Относительные пути экшена резолвим от GITHUB_WORKSPACE: GitHub монтирует туда
  # репо/артефакты (download-artifact), а WORKDIR контейнера — /app. Path.expand
  # оставляет абсолютные пути как есть.
  defp workspace_path(path) do
    case System.get_env("GITHUB_WORKSPACE") do
      ws when is_binary(ws) and ws != "" -> Path.expand(path, ws)
      _ -> path
    end
  end

  # diff-path по умолчанию "" (input не задан) → nil: без inline-комментов, только summary.
  defp optional_workspace_path(path) when path in [nil, ""], do: nil
  defp optional_workspace_path(path), do: workspace_path(path)

  defp env_int(key, default) do
    with value when is_binary(value) <- System.get_env(key),
         {int, _rest} <- Integer.parse(value) do
      int
    else
      _ -> default
    end
  end
end
