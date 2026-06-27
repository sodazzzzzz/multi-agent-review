defmodule Aggregator.Render do
  @moduledoc """
  Чистая отрисовка итогов ревью в Markdown.

  Вход — замороженные кластеры (`Aggregator.Cluster`) и контекст прогона; выход —
  `%{summary: markdown, comments: [...]}`:

    * `summary` — один сводный коммент: счётчики, статус gating (advisory/блок),
      пометка об упавших агентах и СПИСОК ВСЕХ находок (ничего не прячем),
      уже отсортированный `Cluster`'ом по консенсусу. У каждой — метка уверенности
      (`N/M` моделей, `low-confidence` при единственной модели), severity и категория.
    * `comments` — однокликовые `suggestion`-правки для PR-review. Только для
      находок, чья строка реально попадает в дифф (`Aggregator.Diff.in_hunk?/3`):
      иначе GitHub Pulls API вернёт 422. Каждая — `%{path, line, body}` с
      fenced ```suggestion.

  Никакой сети — всё детерминированно. Текст замечания берётся из `:messages`
  (одобренные `Aggregator.Polish`-правки по `id`); при отсутствии — детерминированный
  из самих findings, поэтому отрисовка работает и без стадии причёсывания.

  Контекст (все поля опциональны, есть дефолты):

    * `:diff_index`    — `Aggregator.Diff.t()` (что попадает в хунки). Дефолт `%{}`.
    * `:panel_size`    — сколько агентов реально отдали вывод (`M` в `N/M`). Дефолт 3.
    * `:expected`      — размер полной панели (для строки «M из N моделей»). Дефолт 3.
    * `:failed_agents` — имена не отработавших агентов (для пометки). Дефолт `[]`.
    * `:decision`      — решение `Aggregator.Gate.decide/2`. Дефолт `{:pass, ...}`.
    * `:messages`      — `%{id => текст}` после `Polish`. Дефолт `%{}`.
  """

  alias Aggregator.{Cluster, Consensus, Diff}

  @type comment :: %{path: String.t(), line: pos_integer(), body: String.t()}
  @type output :: %{summary: String.t(), comments: [comment()]}

  @full_panel 3

  @doc "Построить сводный коммент и список однокликовых правок из кластеров."
  @spec render([Cluster.t()], map()) :: output()
  def render(clusters, context \\ %{}) when is_list(clusters) do
    ctx = normalize(context)
    %{summary: summary(clusters, ctx), comments: comments(clusters, ctx)}
  end

  defp normalize(context) do
    %{
      diff_index: Map.get(context, :diff_index, %{}),
      panel_size: Map.get(context, :panel_size, @full_panel),
      expected: Map.get(context, :expected, @full_panel),
      failed_agents: Map.get(context, :failed_agents, []),
      decision: Map.get(context, :decision, {:pass, "advisory"}),
      messages: Map.get(context, :messages, %{})
    }
  end

  # --- однокликовые правки (review comments) ---

  defp comments(clusters, ctx) do
    clusters
    |> Enum.filter(&inline?(&1, ctx.diff_index))
    |> Enum.map(&inline_comment(&1, ctx))
  end

  # Правку показываем, только если есть suggestion И строка попадает в дифф.
  defp inline?(%Cluster{line: nil}, _index), do: false

  defp inline?(%Cluster{file: file, line: line} = c, index) do
    suggestion(c) != nil and Diff.in_hunk?(index, file, line)
  end

  defp inline_comment(%Cluster{file: file, line: line} = c, ctx) do
    %{path: file, line: line, body: inline_body(c, ctx)}
  end

  defp inline_body(c, ctx) do
    code = suggestion(c)
    fence = suggestion_fence(code)

    """
    #{badge(c, ctx)}

    #{message(c, ctx)}

    #{fence}suggestion
    #{code}
    #{fence}
    """
    |> String.trim_trailing()
  end

  # Забор (≥3 бэктика) длиннее самой длинной серии бэктиков ВНУТРИ кода: иначе
  # `suggestion`, сам содержащий ```, закрыл бы блок раньше → битый markdown,
  # и GitHub отверг бы весь POST review 422-м. Переменная длина забора — стандартный
  # CommonMark-приём, поддерживаемый и suggestion-блоками GitHub.
  defp suggestion_fence(code) do
    longest =
      ~r/`+/
      |> Regex.scan(code)
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 0 end)

    String.duplicate("`", max(3, longest + 1))
  end

  # Первый непустой suggestion среди findings кластера.
  defp suggestion(%Cluster{items: items}) do
    Enum.find_value(items, fn f -> if f.suggestion in [nil, ""], do: nil, else: f.suggestion end)
  end

  # --- сводный коммент (summary) ---

  defp summary(clusters, ctx) do
    [
      "## 🔍 Мульти-агентное ревью",
      overview(clusters, ctx),
      failed_banner(ctx.failed_agents),
      gate_line(ctx.decision),
      findings_section(clusters, ctx),
      footer()
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp overview(clusters, ctx) do
    findings = clusters |> Enum.map(&length(&1.items)) |> Enum.sum()

    "Панель: #{ctx.panel_size} из #{ctx.expected} моделей · " <>
      "#{findings} находок · #{length(clusters)} кластеров · #{breakdown(clusters)}"
  end

  defp breakdown(clusters) do
    counts = Enum.frequencies_by(clusters, & &1.severity)
    Enum.map_join(["P0", "P1", "P2"], " · ", fn sev -> "#{sev}: #{Map.get(counts, sev, 0)}" end)
  end

  defp failed_banner([]), do: nil

  defp failed_banner(agents) do
    "> ⚠️ Не отработали: #{Enum.join(agents, ", ")} — ревью по оставшимся моделям."
  end

  defp gate_line({:pass, reason}), do: "**Статус:** ✅ не блокирует merge — #{reason}"
  defp gate_line({:block, reason}), do: "**Статус:** ⛔ блокирует merge — #{reason}"

  defp findings_section([], _ctx), do: "✅ Замечаний нет."

  defp findings_section(clusters, ctx) do
    rows = Enum.map(clusters, &bullet(&1, ctx))
    Enum.join(["### Находки (по консенсусу)" | rows], "\n")
  end

  defp bullet(%Cluster{} = c, ctx) do
    note =
      if inline?(c, ctx.diff_index), do: " _(однокликовая правка в дифф-комментах)_", else: ""

    "- #{badge(c, ctx)} · #{location(c)} — #{oneline(message(c, ctx))}#{note}"
  end

  defp footer do
    "<sub>Перезапуск — команда `/rerun-review` в комментарии к PR. " <>
      "Это независимая ИИ-панель: рекомендации, не блокер (пока не включён `fail_on`).</sub>"
  end

  # --- общие хелперы отрисовки ---

  # «N/M» + цвет уверенности. Единственная модель (consensus 1) → low-confidence.
  defp badge(%Cluster{severity: sev, consensus: n} = c, ctx) do
    "**#{sev}** · #{confidence(n, ctx.panel_size)} · #{category(c)}"
  end

  defp confidence(1, panel), do: "🔴 1/#{panel} · low-confidence"
  defp confidence(n, panel) when n >= panel, do: "🟢 #{n}/#{panel}"
  defp confidence(n, panel), do: "🟡 #{n}/#{panel}"

  defp category(%Cluster{items: items}) do
    items
    |> Enum.map(& &1.category)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> "—"
      cats -> Enum.join(cats, "/")
    end
  end

  defp location(%Cluster{file: file, line: nil}), do: "`#{file}`"
  defp location(%Cluster{file: file, line: line}), do: "`#{file}:#{line}`"

  # Текст: одобренная правка по id, иначе детерминированный из findings.
  defp message(%Cluster{id: id} = c, ctx) do
    case Map.fetch(ctx.messages, id) do
      {:ok, msg} -> msg
      :error -> deterministic_message(c)
    end
  end

  # Представитель — message самой серьёзной находки кластера.
  defp deterministic_message(%Cluster{items: items}) do
    case Enum.reject(items, &is_nil(&1.message)) do
      [] -> "(без описания)"
      msgs -> msgs |> Enum.min_by(&Consensus.severity_rank(&1.severity)) |> Map.get(:message)
    end
  end

  defp oneline(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
