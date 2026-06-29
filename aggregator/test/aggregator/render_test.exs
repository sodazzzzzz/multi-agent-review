defmodule Aggregator.RenderTest do
  use ExUnit.Case, async: true

  import Aggregator.Factory
  alias Aggregator.{Cluster, Render}

  # diff_index: %{file => %{line => text}} — наличие строки = «в хунке» (инлайн возможен).
  defp diff_index(file, lines), do: %{file => Map.new(lines, &{&1, "code at #{&1}"})}

  describe "summary — каркас" do
    test "пустые кластеры → «No issues found», без инлайнов" do
      out = Render.render([])
      assert out.comments == []
      assert out.summary =~ "Multi-agent review"
      assert out.summary =~ "No issues found"
      assert out.summary =~ "/rerun-review"
    end

    test "шапка: счётчики находок/кластеров, панель, разбивка severity" do
      clusters =
        Cluster.build([
          finding(agent: "claude", file: "lib/a.ex", line: 1, severity: "P0"),
          finding(agent: "codex", file: "lib/a.ex", line: 1, severity: "P0"),
          finding(agent: "claude", file: "lib/b.ex", line: 50, severity: "P2")
        ])

      out = Render.render(clusters)
      assert out.summary =~ "**3 findings** in 2 clusters"
      assert out.summary =~ "panel 3/3"
      assert out.summary =~ "P0: 1"
      assert out.summary =~ "P2: 1"
    end

    test "advisory → «does not block» + advisory-футер; block → «blocks merge» + блокирующий футер" do
      pass = Render.render(Cluster.build([finding(line: 1)]))
      assert pass.summary =~ "✅ does not block merge"
      assert pass.summary =~ "advisory — not blocking merge"

      block =
        Render.render(Cluster.build([finding(line: 1, severity: "P0")]), %{
          decision: {:block, "blocking P0 found"}
        })

      assert block.summary =~ "⛔ blocks merge"
      assert block.summary =~ "blocking this merge (per `fail_on`)"
    end

    test "баннер упавших агентов виден в summary" do
      out =
        Render.render(Cluster.build([finding(line: 1)]), %{
          failed_agents: ["codex"],
          panel_size: 2
        })

      assert out.summary =~ "Did not complete: codex"
      assert out.summary =~ "panel 2/3"
    end
  end

  describe "индекс находок (свёрнутый дропдаун)" do
    test "находки — в <details> Findings, по строке на кластер" do
      clusters =
        Cluster.build([
          finding(
            agent: "claude",
            file: "lib/a.ex",
            line: 10,
            severity: "P0",
            message: "Bug one."
          ),
          finding(agent: "codex", file: "lib/b.ex", line: 20, severity: "P2", message: "Nit two.")
        ])

      out = Render.render(clusters)
      assert out.summary =~ "<summary>🔎 Findings (2)</summary>"
      assert out.summary =~ "<code>lib/a.ex:10</code>"
      assert out.summary =~ "Bug one."
    end
  end

  describe "консенсус-бейдж — знаменатель = expected (#5)" do
    test "полный консенсус 3/3 → зелёный; одиночка → 1/3 low-confidence" do
      three =
        Cluster.build(
          for a <- ~w(claude codex deepseek),
              do: finding(agent: a, file: "lib/a.ex", line: 5, severity: "P0")
        )

      assert Render.render(three).summary =~ "🟢 3/3"

      one = Cluster.build([finding(agent: "claude", line: 1, severity: "P1")])
      out = Render.render(one)
      assert out.summary =~ "🔴 1/3"
      assert out.summary =~ "low-confidence"
    end

    test "упавший агент: согласие двух → 2/3 жёлтый (не 2/2)" do
      clusters =
        Cluster.build([
          finding(agent: "claude", file: "lib/a.ex", line: 5, severity: "P0"),
          finding(agent: "codex", file: "lib/a.ex", line: 5, severity: "P0")
        ])

      out = Render.render(clusters, %{panel_size: 2, expected: 3, failed_agents: ["deepseek"]})
      assert out.summary =~ "🟡 2/3"
      refute out.summary =~ "2/2"
    end
  end

  describe "инлайн-комменты (in-hunk) vs Comments outside diff" do
    test "находка на строке в хунке → инлайн-коммент path/line/body со всеми частями" do
      clusters =
        Cluster.build([
          finding(
            agent: "claude",
            file: "lib/a.ex",
            line: 10,
            severity: "P0",
            category: "security",
            message: "SQLi here.",
            suggestion: "safe()"
          )
        ])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10])})
      assert [%{path: "lib/a.ex", line: 10, body: body}] = out.comments
      assert body =~ "_🔴 P0_"
      assert body =~ "_🔒 security_"
      assert body =~ "**SQLi here.**"
      assert body =~ "found by: claude"
      assert body =~ "<summary>📝 Committable suggestion</summary>"
      assert body =~ "```suggestion\nsafe()\n```"
      assert body =~ "<summary>🤖 Prompt for AI agent</summary>"
    end

    test "находка вне диффа → НЕ инлайн, а в дропдауне Comments outside diff" do
      clusters =
        Cluster.build([
          finding(
            file: "lib/a.ex",
            line: 999,
            severity: "P1",
            message: "Off diff.",
            suggestion: "x"
          )
        ])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10])})
      assert out.comments == []
      assert out.summary =~ "Comments outside the diff (1)"
      assert out.summary =~ "Off diff."
    end

    test "часть инлайн, часть вне диффа — разводятся правильно" do
      clusters =
        Cluster.build([
          finding(
            agent: "claude",
            file: "lib/a.ex",
            line: 10,
            severity: "P0",
            message: "In hunk."
          ),
          finding(
            agent: "claude",
            file: "lib/a.ex",
            line: 999,
            severity: "P2",
            message: "Out hunk."
          )
        ])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10])})
      assert length(out.comments) == 1
      assert hd(out.comments).line == 10
      assert out.summary =~ "Comments outside the diff (1)"
    end
  end

  describe "committable suggestion" do
    test "без suggestion → инлайн без блока правки, но с промптом" do
      clusters =
        Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: nil, message: "No fix.")])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10])})
      body = hd(out.comments).body
      refute body =~ "Committable suggestion"
      assert body =~ "Prompt for AI agent"
    end

    test "suggestion с ```-забором → не нативный suggestion (обычный код-блок, забор длиннее)" do
      code = "```\nIO.puts(1)\n```"
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: code)])
      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10])})
      body = hd(out.comments).body
      refute body =~ "```suggestion"
      assert body =~ "````"
      assert body =~ "IO.puts(1)"
    end
  end

  describe "экранирование и oneline" do
    test "html-спецсимволы в тексте экранируются (заголовок и индекс)" do
      clusters = Cluster.build([finding(file: "src/<x>.ex", line: 1, message: "host=<tag> & co")])
      out = Render.render(clusters, %{diff_index: diff_index("src/<x>.ex", [1])})
      body = hd(out.comments).body
      assert body =~ "&lt;tag&gt;"
      assert body =~ "&amp; co"
      assert out.summary =~ "src/&lt;x&gt;.ex"
    end

    test "многострочный текст схлопывается в одну строку" do
      clusters = Cluster.build([finding(line: 1, message: "first part")])
      out = Render.render(clusters, %{messages: %{1 => "line a\n\nline b"}})
      refute out.summary =~ "line a\n\nline b"
      assert out.summary =~ "line a line b"
    end
  end

  describe "правка Polish (messages по id)" do
    test "одобренная правка вытесняет детерминированный текст" do
      clusters =
        Cluster.build([finding(agent: "claude", line: 1, severity: "P1", message: "raw")])

      out = Render.render(clusters, %{messages: %{1 => "polished text."}})
      assert out.summary =~ "polished text."
      refute out.summary =~ "raw"
    end
  end

  describe "fidelity PR4 — suggestion↔строка (#3/#4)" do
    test "инлайн якорится на строке несущей правку находки → committable именно там" do
      clusters =
        Cluster.build([
          finding(agent: "claude", file: "lib/a.ex", line: 10, severity: "P0", message: "Bug."),
          finding(
            agent: "codex",
            file: "lib/a.ex",
            line: 12,
            severity: "P0",
            message: "Bug.",
            suggestion: "fix_line_12()"
          )
        ])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10, 11, 12])})

      # якорь смещён на строку 12 — туда, где правка → suggestion применится корректно
      assert [%{line: 12, body: body}] = out.comments
      assert body =~ "```suggestion\nfix_line_12()\n```"
    end

    test "несколько правок в хунке → якорь на более серьёзной строке" do
      clusters =
        Cluster.build([
          finding(
            agent: "claude",
            file: "lib/a.ex",
            line: 10,
            severity: "P1",
            message: "Bug.",
            suggestion: "fix_p1()"
          ),
          finding(
            agent: "codex",
            file: "lib/a.ex",
            line: 12,
            severity: "P0",
            message: "Bug.",
            suggestion: "fix_p0()"
          )
        ])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10, 11, 12])})
      # обе несут правку → выбираем более серьёзную (P0@12)
      assert [%{line: 12, body: body}] = out.comments
      assert body =~ "```suggestion\nfix_p0()\n```"
    end

    test "индекс summary указывает на строку инлайна (якорь), а не на замороженную строку кластера" do
      clusters =
        Cluster.build([
          finding(agent: "claude", file: "lib/a.ex", line: 10, severity: "P1", message: "Issue."),
          finding(
            agent: "codex",
            file: "lib/a.ex",
            line: 12,
            severity: "P1",
            message: "Issue.",
            suggestion: "fix()"
          )
        ])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10, 11, 12])})

      # инлайн якорится на 12 (там правка) → индекс тоже должен указывать на 12, не на 10
      assert [%{line: 12}] = out.comments
      assert out.summary =~ "<code>lib/a.ex:12</code>"
      refute out.summary =~ "<code>lib/a.ex:10</code>"
    end

    test "якорная (мин.) строка не в хунке, соседняя из окна — в хунке → всё равно инлайн" do
      clusters =
        Cluster.build([
          finding(agent: "claude", file: "lib/a.ex", line: 10, severity: "P1", message: "Issue."),
          finding(agent: "codex", file: "lib/a.ex", line: 12, severity: "P1", message: "Issue.")
        ])

      # в хунке только строка 12; якорь кластера (10) — нет
      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [12])})
      assert [%{line: 12}] = out.comments
      refute out.summary =~ "Comments outside the diff"
    end

    test "правка с НЕ-вхунковой строки → не committable, но видна и в промпте" do
      clusters =
        Cluster.build([
          finding(agent: "claude", file: "lib/a.ex", line: 10, severity: "P0", message: "Bug."),
          finding(
            agent: "codex",
            file: "lib/a.ex",
            line: 12,
            severity: "P0",
            message: "Bug.",
            suggestion: "fix_off_hunk()"
          )
        ])

      # в хунке только якорь (10); строка правки (12) вне хунка
      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10])})
      assert [%{line: 10, body: body}] = out.comments
      refute body =~ "```suggestion"
      assert body =~ "not auto-committable"
      assert body =~ "fix_off_hunk()"
    end
  end

  describe "фиксы ревью PR3" do
    test "B: сокращение (e.g.) не рвёт заголовок — весь текст остаётся целым" do
      clusters =
        Cluster.build([finding(line: 1, message: "Avoid magic numbers e.g. 42 in the loop.")])

      assert Render.render(clusters).summary =~ "Avoid magic numbers e.g. 42 in the loop."
    end

    test "B: настоящая граница предложения делит заголовок и прозу" do
      clusters =
        Cluster.build([
          finding(file: "lib/a.ex", line: 10, message: "Title here. Prose follows.")
        ])

      body =
        hd(Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10])}).comments).body

      assert body =~ "**Title here.**"
      assert body =~ "Prose follows."
    end

    test "C: _ и * в тексте экранируются (нет паразитного курсива)" do
      clusters =
        Cluster.build([finding(file: "lib/a.ex", line: 10, message: "Use foo_bar not foo*baz.")])

      body =
        hd(Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10])}).comments).body

      assert body =~ "foo\\_bar"
      assert body =~ "foo\\*baz"
    end

    test "G: message из пробелов → плейсхолдер, не пустой ****" do
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, message: "   ")])

      body =
        hd(Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [10])}).comments).body

      assert body =~ "(no description)"
      refute body =~ "****"
    end
  end

  describe "walkthrough (LLM-обзор PR)" do
    test "nil → секции нет" do
      out = Render.render(Cluster.build([finding(line: 1)]), %{walkthrough: nil})
      refute out.summary =~ "Walkthrough"
    end

    test "tldr + таблица файлов + валидный mermaid → секция со всем" do
      wt = %{
        tldr: "Adds a guard to refunds.",
        files: [%{path: "lib/a.ex", summary: "guard zero"}],
        mermaid: "flowchart TD\nA-->B"
      }

      out = Render.render(Cluster.build([finding(line: 1)]), %{walkthrough: wt})
      assert out.summary =~ "<summary>📝 Walkthrough</summary>"
      assert out.summary =~ "Adds a guard to refunds."
      assert out.summary =~ "| File | Change |"
      assert out.summary =~ "<code>lib/a.ex</code>"
      assert out.summary =~ "```mermaid\nflowchart TD\nA-->B\n```"
    end

    test "невалидный mermaid отбрасывается, tldr остаётся" do
      wt = %{tldr: "T.", files: [], mermaid: "not a diagram, just prose"}
      out = Render.render(Cluster.build([finding(line: 1)]), %{walkthrough: wt})
      assert out.summary =~ "<summary>📝 Walkthrough</summary>"
      assert out.summary =~ "T."
      refute out.summary =~ "```mermaid"
    end

    test "mermaid с ```-забором отбрасывается (не ломает блок)" do
      wt = %{tldr: "T.", files: [], mermaid: "flowchart TD\nA-->B\n```evil"}
      out = Render.render(Cluster.build([finding(line: 1)]), %{walkthrough: wt})
      refute out.summary =~ "```mermaid"
    end

    test "`|` в ячейке таблицы экранируется сущностью (не ломает таблицу)" do
      wt = %{tldr: "T.", files: [%{path: "a.ex", summary: "do a | b"}], mermaid: nil}
      out = Render.render(Cluster.build([finding(line: 1)]), %{walkthrough: wt})
      assert out.summary =~ "do a &#124; b"
    end

    test "тройной ``` в tldr/summary глушится сущностью (не открывает код-забор)" do
      wt = %{tldr: "Done. ```", files: [%{path: "a.ex", summary: "see ```js"}], mermaid: nil}
      out = Render.render(Cluster.build([finding(line: 1)]), %{walkthrough: wt})
      assert out.summary =~ "Done. &#96;&#96;&#96;"
      assert out.summary =~ "see &#96;&#96;&#96;js"
    end
  end

  describe "лимит размера summary (защита от 422 GitHub)" do
    test "большой PR → summary не пробивает лимит, обзор не теряется целиком" do
      big =
        for i <- 1..300 do
          finding(
            file: "lib/f#{i}.ex",
            line: i,
            severity: "P1",
            message: String.duplicate("long problem description ", 30),
            suggestion: String.duplicate("x = #{i}\n", 8)
          )
        end

      # без diff_index → все находки «вне диффа» → крупная секция → деградация/усечение
      out = Render.render(Cluster.build(big))
      assert String.length(out.summary) <= 60_000
      assert out.summary =~ "Multi-agent review"
    end
  end
end
