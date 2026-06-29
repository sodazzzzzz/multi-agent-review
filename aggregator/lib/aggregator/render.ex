defmodule Aggregator.Render do
  @moduledoc """
  Чистая отрисовка итогов ревью в формате «walkthrough + инлайны» (как CodeRabbit).

  `render/2` возвращает `%{summary, comments}`:

    * `summary` — ОДИН issue-комментарий-обзор. Видимы только шапка (счётчики +
      статус gating + баннер упавших агентов); всё содержательное — в сворачиваемых
      `<details>`-дропдаунах: индекс находок и секция «Comments outside the diff»
      (находки, чья строка НЕ попадает в хунк диффа — инлайн к ним невозможен).
    * `comments` — инлайн-комменты PR-review, по одному на кластер, чья строка есть
      в диффе (`Aggregator.Diff.in_hunk?`). Тело инлайна: бейджи (категория · severity ·
      консенсус N/expected), заголовок+проза, «found by», и в дропдаунах — однокликовый
      `suggestion` (только если правка с якорной строки) и промпт для ИИ-агента.

  Всё детерминированно, без сети. Текст замечания — одобренная правка `Polish` по id
  (`:messages`) либо детерминированный из findings. Консенсус/severity/строки заморожены
  в `Aggregator.Cluster`.

  Контекст (поля опциональны, есть дефолты):

    * `:diff_index`    — `Aggregator.Diff.t()` (строки и текст). Дефолт `%{}`.
    * `:panel_size`    — сколько агентов реально отдали вывод (`M` в «panel M/expected»). Дефолт 3.
    * `:expected`      — размер полной панели (знаменатель консенсуса `N/expected`). Дефолт 3.
    * `:failed_agents` — имена не отработавших агентов. Дефолт `[]`.
    * `:decision`      — решение `Aggregator.Gate.decide/2`. Дефолт `{:pass, "advisory"}`.
    * `:messages`      — `%{id => текст}` после `Polish`. Дефолт `%{}`.
  """

  alias Aggregator.{Cluster, Consensus, Diff}

  @type comment :: %{path: String.t(), line: pos_integer(), body: String.t()}
  @type output :: %{summary: String.t(), comments: [comment()]}

  @full_panel 3

  # Лимит тела issue-коммента GitHub — 65536; держим запас. Summary теперь компактный
  # (индекс + свёрнутые секции), но «Comments outside diff» на огромном PR может пробить
  # лимит → деградируем (полные записи → индекс) и в крайнем случае усекаем.
  @max_body 60_000

  @cut_note "\n\n> ⚠️ …review truncated due to GitHub's comment limit (too many findings)."

  # Голова «1-го предложения» оканчивается распространённым сокращением → НЕ граница.
  @abbrev_tail ~r/\b(e\.g|i\.e|etc|vs|cf|al|Mr|Mrs|Ms|Dr|Prof|No|Fig|Eq|Sec|Ch|Inc|Ltd)\.$/i

  @doc "Построить обзор-коммент (`summary`) + инлайн-комменты (`comments`) из кластеров."
  @spec render([Cluster.t()], map()) :: output()
  def render(clusters, context \\ %{}) when is_list(clusters) do
    ctx = normalize(context)
    {inline, outside} = Enum.split_with(clusters, &inline?(&1, ctx))

    %{
      summary: summary(clusters, outside, ctx),
      comments: Enum.map(inline, &inline_comment(&1, ctx))
    }
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

  # Инлайн возможен только если строка кластера реально в хунке диффа (иначе Pulls API → 422).
  defp inline?(%Cluster{file: file, line: line}, ctx),
    do: Diff.in_hunk?(ctx.diff_index, file, line)

  # --- summary (обзор-коммент) ---

  # Полный вид; если не влез в лимит — компактный (вне-диффовые находки свёрнуты в
  # индекс); если и тот велик — жёстко режем. Обзор не теряется целиком.
  defp summary(all, outside, ctx) do
    full = assemble_summary(all, outside, ctx, true)

    if String.length(full) <= @max_body,
      do: full,
      else: hard_cap(assemble_summary(all, outside, ctx, false))
  end

  defp assemble_summary(all, outside, ctx, full?) do
    [
      header(all, ctx),
      failed_banner(ctx.failed_agents),
      gate_line(ctx.decision),
      findings_details(all, ctx),
      outside_details(outside, ctx, full?),
      footer(ctx.decision)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp header([], _ctx), do: "## 🔍 Multi-agent review\n\n✅ No issues found."

  defp header(clusters, ctx) do
    findings = clusters |> Enum.map(&length(&1.items)) |> Enum.sum()

    "## 🔍 Multi-agent review\n\n" <>
      "**#{findings} findings** in #{length(clusters)} clusters · " <>
      "panel #{ctx.panel_size}/#{ctx.expected} · #{breakdown(clusters)}"
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

  # Индекс находок — однострочный, в дропдауне (CR-стиль: содержательное свёрнуто).
  defp findings_details([], _ctx), do: nil

  defp findings_details(clusters, ctx) do
    rows = Enum.map_join(clusters, "\n", &("- " <> index_line(&1, ctx)))
    details_block("🔎 Findings (#{length(clusters)})", rows)
  end

  defp index_line(%Cluster{} = c, ctx) do
    "#{consensus_badge(c.consensus, ctx.expected)} · #{c.severity} · #{label(category(c))} · " <>
      "<code>#{html_escape(location(c))}</code> — #{md_escape(title(c, ctx))}"
  end

  # Находки вне диффа — отдельный дропдаун с полными записями (инлайн к ним нельзя).
  defp outside_details([], _ctx, _full?), do: nil

  defp outside_details(clusters, ctx, true) do
    entries = Enum.map_join(clusters, "\n\n---\n\n", &outside_entry(&1, ctx))
    details_block("💬 Comments outside the diff (#{length(clusters)})", entries)
  end

  # Компактный режим (summary не влез): только индекс вне-диффовых находок.
  defp outside_details(clusters, ctx, false) do
    rows = Enum.map_join(clusters, "\n", &("- " <> index_line(&1, ctx)))

    details_block(
      "💬 Comments outside the diff (#{length(clusters)})",
      "> ⚠️ Full entries collapsed — output exceeded GitHub's comment limit.\n\n#{rows}"
    )
  end

  defp outside_entry(%Cluster{} = c, ctx) do
    [
      badge_line(c, ctx),
      "<code>#{html_escape(location(c))}</code>",
      finding_text(c, ctx),
      suggestion_code(c),
      agent_prompt_details(c, ctx)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  # Показ предложения вне диффа — подписанный код-блок (однокликовый suggestion невозможен).
  defp suggestion_code(%Cluster{} = c) do
    case suggestion(c) do
      nil -> nil
      fix -> "Suggested change:\n\n#{fenced(fix, "")}"
    end
  end

  # --- инлайн-комменты ---

  defp inline_comment(%Cluster{file: file, line: line} = c, ctx),
    do: %{path: file, line: line, body: inline_body(c, ctx)}

  defp inline_body(%Cluster{} = c, ctx) do
    [
      badge_line(c, ctx),
      finding_text(c, ctx),
      found_by(c),
      committable_suggestion(c),
      agent_prompt_details(c, ctx)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  # Бейдж-строка CR-стиля: _категория_ | _severity_ | _консенсус_ (курсив, через `|`).
  defp badge_line(%Cluster{severity: sev, consensus: n} = c, ctx) do
    "_#{category_icon(c)} #{label(category(c))}_ | _#{severity_badge(sev)} #{sev}_ | " <>
      "_#{consensus_badge(n, ctx.expected)} consensus#{low_conf(n)}_"
  end

  defp low_conf(1), do: " · low-confidence"
  defp low_conf(_n), do: ""

  # Заголовок (жирный, 1-е предложение) + проза (остальное). Текст экранируем — тело
  # коммента markdown: < открыл бы HTML-тег, а _/* — паразитный курсив.
  defp finding_text(%Cluster{} = c, ctx) do
    {head, rest} = split_message(message(c, ctx))
    bold = "**#{md_escape(headline_text(head))}**"

    case rest && oneline(rest) do
      prose when is_binary(prose) and prose != "" -> "#{bold}\n\n#{md_escape(prose)}"
      _ -> bold
    end
  end

  defp title(%Cluster{} = c, ctx),
    do: c |> message(ctx) |> split_message() |> elem(0) |> headline_text()

  # Пустой/пробельный заголовок (схема допускает message из пробелов) → плейсхолдер,
  # иначе вышел бы пустой жирный `****`.
  defp headline_text(head) do
    case oneline(head) do
      "" -> "(no description)"
      t -> t
    end
  end

  # Делим сообщение на «заголовок» (1-е предложение) и «прозу» ТОЛЬКО при уверенной
  # границе: .!? + пробел + Заглавная/цифра, и голова не оканчивается распространённым
  # сокращением (e.g./i.e./etc. …). Иначе всё — заголовок (без ложного разрыва).
  defp split_message(msg) do
    case Regex.run(~r/^(.+?[.!?])\s+([A-Z0-9].*)$/su, msg) do
      [_, head, rest] -> if abbrev_tail?(head), do: {msg, nil}, else: {head, rest}
      _ -> {msg, nil}
    end
  end

  defp abbrev_tail?(head), do: Regex.match?(@abbrev_tail, String.trim(head))

  defp found_by(%Cluster{items: items}) do
    agents = items |> Enum.map(& &1.agent) |> Enum.uniq() |> Enum.join(", ")
    "<sub>found by: #{agents}</sub>"
  end

  # Однокликовый suggestion — ТОЛЬКО из находки на якорной строке кластера (её и
  # прокомментировали; GitHub применит правку к этой строке). Если правка есть, но с
  # другой строки окна — отдаём не как committable, а как подписанный код-блок (и она
  # всё равно попадёт в промпт). Так «Commit suggestion» не затрёт не ту строку.
  defp committable_suggestion(%Cluster{} = c) do
    case anchored_suggestion(c) do
      nil ->
        non_anchored_hint(c)

      fix ->
        if String.contains?(fix, "```"),
          do: details_block("📝 Suggested change (not auto-committable)", fenced(fix, "")),
          else: details_block("📝 Committable suggestion", "```suggestion\n#{fix}\n```")
    end
  end

  # Есть правка, но не с якорной строки → показываем как подписанный (не однокликовый)
  # блок, чтобы код-доказательство не терялось, но и не коммитилось не туда.
  defp non_anchored_hint(%Cluster{} = c) do
    case suggestion(c) do
      nil -> nil
      fix -> details_block("📝 Suggested change (not auto-committable)", fenced(fix, ""))
    end
  end

  defp anchored_suggestion(%Cluster{items: items, line: line}) do
    Enum.find_value(items, fn f ->
      if f.line == line and f.suggestion not in [nil, ""], do: f.suggestion
    end)
  end

  defp agent_prompt_details(%Cluster{} = c, ctx),
    do: details_block("🤖 Prompt for AI agent", fenced(agent_prompt(c, ctx), ""))

  defp agent_prompt(%Cluster{} = c, ctx) do
    base = "In #{location(c)}, #{oneline(message(c, ctx))}"

    case suggestion(c) do
      nil -> base <> " Make a minimal, targeted fix that preserves behavior and style."
      fix -> base <> "\nSuggested direction:\n#{fix}"
    end
  end

  # --- общие хелперы ---

  defp details_block(summary_line, body),
    do: "<details>\n<summary>#{summary_line}</summary>\n\n#{body}\n\n</details>"

  # Код-блок с переменной длиной забора (≥3 бэктика, длиннее любой серии внутри текста).
  defp fenced(text, lang) do
    fence = fence_for([text])
    "#{fence}#{lang}\n#{text}\n#{fence}"
  end

  defp consensus_badge(n, expected), do: "#{circle(n, expected)} #{n}/#{expected}"

  # Одна модель = всегда low-confidence (красный), даже если панель из одной модели.
  defp circle(1, _expected), do: "🔴"
  defp circle(n, expected) when n >= expected, do: "🟢"
  defp circle(_n, _expected), do: "🟡"

  defp severity_badge("P0"), do: "🔴"
  defp severity_badge("P1"), do: "🟠"
  defp severity_badge("P2"), do: "🟡"
  defp severity_badge(_other), do: "⚪"

  defp category_icon(%Cluster{} = c) do
    case primary_category(c) do
      "security" -> "🔒"
      "bug" -> "🐛"
      "performance" -> "⚡"
      "design" -> "📐"
      "test" -> "🧪"
      "style" -> "🎨"
      _other -> "🔎"
    end
  end

  defp primary_category(%Cluster{items: items}),
    do: items |> Enum.map(& &1.category) |> Enum.find(&(&1 not in [nil, ""]))

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

  # Первый непустой suggestion среди findings кластера (для промпта/вне-диффовой записи).
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

  # Decision-aware: не врать «advisory», когда fail_on реально блокирует merge.
  defp footer({decision, _reason}) do
    stance =
      case decision do
        :block -> "blocking this merge (per `fail_on`)"
        :pass -> "advisory — not blocking merge"
      end

    "<sub>Independent AI panel · #{stance}. Re-run with `/rerun-review` in a PR comment.</sub>"
  end

  # Забор (≥3 бэктика) длиннее самой длинной серии бэктиков внутри текста — иначе код,
  # сам содержащий ```, закрыл бы блок раньше. Стандартный CommonMark-приём.
  defp fence_for(texts) do
    longest =
      texts
      |> Enum.flat_map(&Regex.scan(~r/`+/, &1))
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 0 end)

    String.duplicate("`", max(3, longest + 1))
  end

  # Текст для бейджа/индекса: HTML + markdown-эмфазис экранированы, `|` → `/` (чтобы не
  # путался с разделителем бейджа и не триггерил pipe-таблицы GitHub).
  defp label(text), do: text |> md_escape() |> String.replace("|", "/")

  # html_escape + нейтрализация markdown-эмфазиса (_ *), т.к. текст модели попадает в
  # markdown-контекст (жирный заголовок, курсивный бейдж). Бэктики НЕ трогаем — пусть
  # code-спаны модели рендерятся как код.
  defp md_escape(text), do: text |> html_escape() |> String.replace(~r/[_*]/, &("\\" <> &1))

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp oneline(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_other), do: false

  # Последний предохранитель: даже компактный summary не влез — режем по границе строки,
  # дозакрываем висящие <details> (иначе коммент «съезжает») и приписываем пометку.
  # Резервируем запас под закрывающие теги и пометку, чтобы не перелезть лимит.
  defp hard_cap(body) do
    if String.length(body) <= @max_body do
      body
    else
      keep = @max_body - String.length(@cut_note) - 64
      cut = body |> String.slice(0, keep) |> String.replace(~r/\n[^\n]*\z/, "")
      cut <> close_dangling(cut) <> @cut_note
    end
  end

  defp close_dangling(text) do
    opens = length(Regex.scan(~r/<details>/, text))
    closes = length(Regex.scan(~r|</details>|, text))
    String.duplicate("\n</details>", max(0, opens - closes))
  end
end
