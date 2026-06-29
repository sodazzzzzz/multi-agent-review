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
    * сами находки — плоским списком-буллетами, без дропдаунов (чтобы их легко
      было сканировать);
    * один общий `<details>` снизу: «код-доказательства» (diff «сломанный код →
      предложение» по находкам с готовой правкой; код заморожен) + готовый ПРОМПТ
      «исправь все находки» для ИИ-агента.

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

  # Лимит тела issue-комментария GitHub — 65536 символов; держим запас. Полный вид
  # (диффы + промпт, дублирующий suggestion'ы) на большом PR легко его пробивает →
  # POST вернул бы 422 и ВЕСЬ обзор пропал бы. Поэтому деградируем по тирам.
  @max_body 60_000

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

  # Полный вид = список находок + общий дропдаун (доказательства + промпт). Если он не
  # влезает в лимит — деградируем до одного списка находок; если и тот не влез (сотни
  # находок) — жёстко режем. Обзор не теряется целиком. Компактный вид считаем максимум
  # один раз: hard_cap вернёт его как есть, если влезает, иначе усечёт.
  defp summary(clusters, ctx) do
    full = assemble(clusters, ctx, true)

    if String.length(full) <= @max_body,
      do: full,
      else: hard_cap(assemble(clusters, ctx, false))
  end

  defp assemble(clusters, ctx, extras) do
    [
      "## 🔍 Multi-agent review",
      overview(clusters, ctx),
      failed_banner(ctx.failed_agents),
      gate_line(ctx.decision),
      size_note(extras, clusters),
      findings_section(clusters, ctx),
      if(extras, do: action_section(clusters, ctx)),
      footer(ctx.decision)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  # Пометка о деградации — только когда общий дропдаун свёрнут и находки есть.
  defp size_note(true, _clusters), do: nil
  defp size_note(_extras, []), do: nil

  defp size_note(false, _clusters),
    do:
      "> ⚠️ Evidence and the fix-all prompt are collapsed — the full output exceeded GitHub's " <>
        "comment limit (too many findings). The findings are listed below."

  @cut_note "\n\n> ⚠️ …review truncated due to GitHub's comment limit (too many findings)."

  # Последний предохранитель: даже компактный вид не влез — режем по границе строки.
  # Резервируем РОВНО длину приписываемой пометки (а не «магические» 60), иначе
  # cut + @cut_note может перелезть лимит на пару символов и нарушить инвариант.
  defp hard_cap(body) do
    if String.length(body) <= @max_body do
      body
    else
      keep = @max_body - String.length(@cut_note)
      cut = body |> String.slice(0, keep) |> String.replace(~r/\n[^\n]*\z/, "")
      cut <> @cut_note
    end
  end

  defp overview(clusters, ctx) do
    findings = clusters |> Enum.map(&length(&1.items)) |> Enum.sum()

    "Panel: #{ctx.panel_size}/#{ctx.expected} models · " <>
      "#{findings} findings · #{length(clusters)} clusters · #{breakdown(clusters)}"
  end

  defp breakdown(clusters) do
    counts = Enum.frequencies_by(clusters, & &1.severity)
    Enum.map_join(["P0", "P1", "P2"], " · ", fn sev -> "#{sev}: #{Map.get(counts, sev, 0)}" end)
  end

  defp failed_banner([]), do: nil

  defp failed_banner(agents),
    do: "> ⚠️ Did not complete: #{Enum.join(agents, ", ")} — review based on the remaining models."

  defp gate_line({:pass, reason}), do: "**Status:** ✅ does not block merge — #{reason}"
  defp gate_line({:block, reason}), do: "**Status:** ⛔ blocks merge — #{reason}"

  # --- список находок ---

  # Все находки — обычными буллетами, без дропдаунов. По решению продукта код-диффы и
  # промпт уходят в отдельный общий дропдаун, а сам список находок остаётся плоским и
  # легко сканируемым.
  defp findings_section([], _ctx), do: "✅ No issues found."

  defp findings_section(clusters, ctx) do
    bullets = Enum.map(clusters, &("- " <> headline(&1, ctx)))
    Enum.join(["### Findings (by consensus)" | bullets], "\n")
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

  # --- общий дропдаун: код-доказательства + промпт «исправь всё» ---

  defp action_section([], _ctx), do: nil

  defp action_section(clusters, ctx) do
    body =
      [evidence_block(clusters, ctx), prompt_block(clusters, ctx)]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    details_block("🛠 Code evidence and an AI-agent prompt to fix all findings", body)
  end

  # «Сломанный код → предложенная правка» по каждой находке, у которой есть правка.
  # Находки без suggestion сюда не попадают (нечего показывать в +стороне) — они уже
  # перечислены буллетами в списке находок.
  defp evidence_block(clusters, ctx) do
    clusters
    |> Enum.map(fn c -> {c, code_diff_block(c, ctx)} end)
    |> Enum.reject(fn {_c, diff} -> is_nil(diff) end)
    |> case do
      [] ->
        nil

      pairs ->
        entries = Enum.map(pairs, fn {c, diff} -> evidence_entry(c, ctx, diff) end)
        Enum.join(["#### Broken code → suggested fix" | entries], "\n\n")
    end
  end

  defp evidence_entry(%Cluster{} = c, ctx, diff) do
    head =
      "**<code>#{html_escape(location(c))}</code>** — #{html_escape(oneline(message(c, ctx)))}"

    "#{head}\n\n#{diff}"
  end

  defp prompt_block(clusters, ctx) do
    prompt = fix_all_prompt(clusters, ctx)
    fence = fence_for([prompt])
    "#### Prompt\n\n#{fence}text\n#{prompt}\n#{fence}"
  end

  defp fix_all_prompt(clusters, ctx) do
    intro =
      "Fix the problems listed below. Make minimal, targeted changes; preserve behavior " <>
        "and style; do not touch unrelated code. For each: file:line, the issue, and the " <>
        "direction of the fix."

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
      fix -> "#{head}\n   suggestion:\n#{indent(fix)}"
    end
  end

  defp indent(text),
    do: text |> String.split(["\r\n", "\n"]) |> Enum.map_join("\n", &"     #{&1}")

  # Decision-aware: must not claim "advisory" when fail_on is actually blocking this
  # merge (and vice versa). Stance is derived from the gate decision, not hard-coded.
  defp footer({decision, _reason}) do
    stance =
      case decision do
        :block -> "blocking this merge (per `fail_on`)"
        :pass -> "advisory — not blocking merge"
      end

    "<sub>Independent AI panel · #{stance}. Re-run with `/rerun-review` in a PR comment.</sub>"
  end

  # --- общие хелперы ---

  # Denominator is the FULL panel (`expected`), not the agents that actually ran:
  # honest coverage. With a failed agent the max consensus is < expected → never
  # green (yellow at best); the failed-agent banner explains the missing vote.
  defp badge(%Cluster{severity: sev, consensus: n} = c, ctx),
    do: "**#{sev}** · #{confidence(n, ctx.expected)} · #{category(c)}"

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
      [] -> "(no description)"
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
