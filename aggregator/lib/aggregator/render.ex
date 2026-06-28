defmodule Aggregator.Render do
  @moduledoc """
  Чистая отрисовка итогов ревью в ОДИН Markdown-комментарий.

  Вход — замороженные кластеры (`Aggregator.Cluster`) и контекст прогона; выход —
  `%{summary: markdown, comments: []}`. Всё ревью консолидировано в `summary`
  (отдельные inline-комменты к строкам больше не постим — выходило слишком объёмно,
  находки дублировались):

    * шапка: счётчики, статус gating, пометка об упавших агентах;
    * список ВСЕХ находок (ничего не прячем), отсортированный `Cluster`'ом по
      консенсусу; у каждой — метка уверенности (`N/M`, `low-confidence` при одной
      модели), severity и категория;
    * у находок с готовой правкой — раскрывающийся `<details>` со сравнением
      «сломанный код → предложение» (diff-блоком); сам код правки заморожен;
    * общий `<details>` с готовым ПРОМПТОМ «исправь все находки» для ИИ-агента.

  Никакой сети — детерминированно. Текст замечания берётся из `:messages`
  (одобренные `Aggregator.Polish`-правки по `id`), иначе — детерминированный из
  findings. «Сломанный код» берётся из `:diff_index` (`Aggregator.Diff` хранит и
  текст RIGHT-строк); если строки в диффе нет — показываем только предложение.

  Контекст (все поля опциональны, есть дефолты):

    * `:diff_index`    — `Aggregator.Diff.t()` (строки и их текст). Дефолт `%{}`.
    * `:panel_size`    — сколько агентов реально отдали вывод (`M` в `N/M`). Дефолт 3.
    * `:expected`      — размер полной панели. Дефолт 3.
    * `:failed_agents` — имена не отработавших агентов. Дефолт `[]`.
    * `:decision`      — решение `Aggregator.Gate.decide/2`. Дефолт `{:pass, ...}`.
    * `:messages`      — `%{id => текст}` после `Polish`. Дефолт `%{}`.
  """

  alias Aggregator.{Cluster, Consensus, Diff}

  @type output :: %{summary: String.t(), comments: []}

  @full_panel 3

  @doc "Построить ОДИН консолидированный коммент-ревью из кластеров."
  @spec render([Cluster.t()], map()) :: output()
  def render(clusters, context \\ %{}) when is_list(clusters) do
    ctx = normalize(context)

    # Inline-комментов больше нет — всё в одном summary (см. moduledoc).
    %{summary: summary(clusters, ctx), comments: []}
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

  # --- сборка коммента ---

  defp summary(clusters, ctx) do
    [
      "## 🔍 Мульти-агентное ревью",
      overview(clusters, ctx),
      failed_banner(ctx.failed_agents),
      gate_line(ctx.decision),
      findings_section(clusters, ctx),
      fix_all_section(clusters, ctx),
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

  defp failed_banner(agents),
    do: "> ⚠️ Не отработали: #{Enum.join(agents, ", ")} — ревью по оставшимся моделям."

  defp gate_line({:pass, reason}), do: "**Статус:** ✅ не блокирует merge — #{reason}"
  defp gate_line({:block, reason}), do: "**Статус:** ⛔ блокирует merge — #{reason}"

  # --- список находок ---

  defp findings_section([], _ctx), do: "✅ Замечаний нет."

  defp findings_section(clusters, ctx) do
    blocks = Enum.map(clusters, &finding_entry(&1, ctx))
    Enum.join(["### Находки (по консенсусу)" | blocks], "\n\n")
  end

  # С готовой правкой → раскрывающийся <details> с диффом; без неё → обычный буллет.
  defp finding_entry(%Cluster{} = c, ctx) do
    case code_diff_block(c, ctx) do
      nil -> "- #{headline(c, ctx)}"
      diff -> details_block(headline(c, ctx), diff)
    end
  end

  defp details_block(summary_line, body) do
    ["<details>", "<summary>#{summary_line}</summary>", "", body, "", "</details>"]
    |> Enum.join("\n")
  end

  # Шапка находки: severity · уверенность · категория · файл:строка — текст (1 строкой).
  # Путь — в <code> с экранированием (а не в `бэктики`): корректно и безопасно и в
  # HTML-контексте <summary>, и в markdown-буллете, даже если путь содержит < > &.
  defp headline(%Cluster{} = c, ctx) do
    "#{badge(c, ctx)} · <code>#{html_escape(location(c))}</code> — " <>
      html_escape(oneline(message(c, ctx)))
  end

  # Блок «сломанный код → предложение» (diff). Только при наличии правки: без
  # предложения показывать один «сломанный» код незачем (тогда — обычный буллет).
  defp code_diff_block(%Cluster{} = c, ctx) do
    case suggestion(c) do
      nil ->
        nil

      fix ->
        broken = broken_code(c, ctx)
        sides = Enum.reject([diff_side(broken, "-"), diff_side(fix, "+")], &is_nil/1)
        fence = fence_for(Enum.reject([broken, fix], &is_nil/1))
        "#{fence}diff\n#{Enum.join(sides, "\n")}\n#{fence}"
    end
  end

  defp diff_side(nil, _marker), do: nil

  defp diff_side(text, marker),
    do: text |> String.split(["\r\n", "\n"]) |> Enum.map_join("\n", &"#{marker} #{&1}")

  defp broken_code(%Cluster{file: file, line: line}, ctx),
    do: Diff.line_content(ctx.diff_index, file, line)

  # --- промпт «исправь всё» ---

  defp fix_all_section([], _ctx), do: nil

  defp fix_all_section(clusters, ctx) do
    prompt = fix_all_prompt(clusters, ctx)
    fence = fence_for([prompt])

    details_block(
      "🛠 Промпт для ИИ-агента — исправить все находки",
      "#{fence}text\n#{prompt}\n#{fence}"
    )
  end

  defp fix_all_prompt(clusters, ctx) do
    intro =
      "Исправь перечисленные ниже проблемы в коде. Вноси минимальные точечные правки, " <>
        "сохраняй поведение и стиль, не трогай несвязанный код. Для каждой — файл:строка, " <>
        "суть и направление правки."

    items =
      clusters
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {c, i} -> fix_all_item(c, ctx, i) end)

    "#{intro}\n\n#{items}"
  end

  defp fix_all_item(%Cluster{severity: sev} = c, ctx, i) do
    head = "#{i}. #{location(c)} [#{sev}/#{category(c)}] — #{oneline(message(c, ctx))}"

    case suggestion(c) do
      nil -> head
      fix -> "#{head}\n   предложение:\n#{indent(fix)}"
    end
  end

  defp indent(text),
    do: text |> String.split(["\r\n", "\n"]) |> Enum.map_join("\n", &"     #{&1}")

  defp footer do
    "<sub>Перезапуск — команда `/rerun-review` в комментарии к PR. " <>
      "Это независимая ИИ-панель: рекомендации, не блокер (пока не включён `fail_on`).</sub>"
  end

  # --- общие хелперы ---

  defp badge(%Cluster{severity: sev, consensus: n} = c, ctx),
    do: "**#{sev}** · #{confidence(n, ctx.panel_size)} · #{category(c)}"

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

  defp location(%Cluster{file: file, line: nil}), do: file
  defp location(%Cluster{file: file, line: line}), do: "#{file}:#{line}"

  # Первый непустой suggestion среди findings кластера.
  defp suggestion(%Cluster{items: items}),
    do:
      Enum.find_value(items, fn f ->
        if f.suggestion in [nil, ""], do: nil, else: f.suggestion
      end)

  # Текст: одобренная правка по id, иначе детерминированный из findings.
  defp message(%Cluster{id: id} = c, ctx) do
    case Map.fetch(ctx.messages, id) do
      {:ok, msg} -> msg
      :error -> deterministic_message(c)
    end
  end

  defp deterministic_message(%Cluster{items: items}) do
    case Enum.reject(items, &is_nil(&1.message)) do
      [] -> "(без описания)"
      msgs -> msgs |> Enum.min_by(&Consensus.severity_rank(&1.severity)) |> Map.get(:message)
    end
  end

  # Забор (≥3 бэктика) длиннее самой длинной серии бэктиков внутри текста: иначе
  # код, сам содержащий ```, закрыл бы блок раньше → битый markdown. Переменная
  # длина забора — стандартный CommonMark-приём.
  defp fence_for(texts) do
    longest =
      texts
      |> Enum.flat_map(&Regex.scan(~r/`+/, &1))
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 0 end)

    String.duplicate("`", max(3, longest + 1))
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp oneline(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
