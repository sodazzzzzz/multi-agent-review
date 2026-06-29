defmodule Aggregator.RenderTest do
  use ExUnit.Case, async: true

  import Aggregator.Factory
  alias Aggregator.{Cluster, Render}

  # diff_index теперь хранит и текст строк: %{file => %{line => content}}.
  defp diff_index(file, pairs), do: %{file => Map.new(pairs)}

  describe "summary — каркас" do
    test "пустые кластеры → заголовок и «замечаний нет», без комментов" do
      out = Render.render([])
      assert out.comments == []
      assert out.summary =~ "Multi-agent review"
      assert out.summary =~ "No issues found"
      assert out.summary =~ "/rerun-review"
    end

    test "счётчики: находки, кластеры, разбивка по severity" do
      clusters =
        Cluster.build([
          finding(agent: "claude", file: "lib/a.ex", line: 1, severity: "P0"),
          finding(agent: "codex", file: "lib/a.ex", line: 1, severity: "P0"),
          finding(agent: "claude", file: "lib/b.ex", line: 50, severity: "P2")
        ])

      out = Render.render(clusters)
      assert out.summary =~ "3 findings"
      assert out.summary =~ "2 clusters"
      assert out.summary =~ "P0: 1"
      assert out.summary =~ "P2: 1"
    end

    test "advisory по умолчанию → статус «не блокирует»" do
      out = Render.render(Cluster.build([finding(line: 1)]))
      assert out.summary =~ "✅ does not block merge"
    end

    test "решение block → статус «блокирует»; упавшие агенты в баннере" do
      out =
        Render.render(Cluster.build([finding(line: 1, severity: "P0")]), %{
          failed_agents: ["codex"],
          panel_size: 2,
          decision: {:block, "a blocking P0 was found"}
        })

      assert out.summary =~ "⛔ blocks merge"
      assert out.summary =~ "Did not complete: codex"
      # #5: denominator is the full panel (expected=3), not the agents that ran (2)
      assert out.summary =~ "1/3"
      assert out.summary =~ "Panel: 2/3 models"
    end
  end

  describe "summary — метки уверенности" do
    test "единственная модель (consensus 1) → low-confidence + N/M" do
      out = Render.render(Cluster.build([finding(agent: "claude", line: 1, severity: "P1")]))
      assert out.summary =~ "low-confidence"
      assert out.summary =~ "1/3"
    end

    test "полный консенсус 3/3 → зелёная метка, без low-confidence" do
      clusters =
        Cluster.build([
          finding(agent: "claude", line: 5, severity: "P0"),
          finding(agent: "codex", line: 5, severity: "P0"),
          finding(agent: "deepseek", line: 5, severity: "P0")
        ])

      out = Render.render(clusters)
      assert out.summary =~ "3/3"
      refute out.summary =~ "low-confidence"
    end

    test "категории кластера объединяются" do
      clusters =
        Cluster.build([
          finding(agent: "claude", file: "lib/a.ex", line: 10, category: "bug", severity: "P1"),
          finding(
            agent: "codex",
            file: "lib/a.ex",
            line: 10,
            category: "security",
            severity: "P1"
          )
        ])

      assert Render.render(clusters).summary =~ "bug/security"
    end
  end

  describe "summary — текст замечания" do
    test "одобренная правка (messages по id) вытесняет детерминированный текст" do
      clusters =
        Cluster.build([finding(agent: "claude", line: 1, severity: "P1", message: "сырой")])

      out = Render.render(clusters, %{messages: %{1 => "причёсанный"}})
      assert out.summary =~ "причёсанный"
      refute out.summary =~ "сырой"
    end

    test "без правок берётся message самой серьёзной находки кластера" do
      clusters =
        Cluster.build([
          finding(agent: "claude", file: "lib/a.ex", line: 10, severity: "P2", message: "мелочь"),
          finding(agent: "codex", file: "lib/a.ex", line: 10, severity: "P0", message: "критично")
        ])

      out = Render.render(clusters)
      assert out.summary =~ "критично"
    end

    test "многострочный текст схлопывается в одну строку в шапке находки" do
      clusters = Cluster.build([finding(line: 1, message: "первая\nвторая")])
      out = Render.render(clusters, %{messages: %{1 => "строка-а\n\nстрока-б"}})
      refute out.summary =~ "строка-а\n\nстрока-б"
      assert out.summary =~ "строка-а строка-б"
    end

    test "html-спецсимволы в тексте экранируются (контекст <summary>/буллет)" do
      clusters = Cluster.build([finding(line: 1, message: "host='x; rm' и <тег> & co")])
      out = Render.render(clusters)
      assert out.summary =~ "&lt;тег&gt;"
      assert out.summary =~ "&amp; co"
    end

    test "путь файла экранируется внутри <code> (защита HTML-контекста)" do
      out = Render.render(Cluster.build([finding(file: "src/<x>.ex", line: 1)]))
      assert out.summary =~ "<code>src/&lt;x&gt;.ex:1</code>"
    end
  end

  describe "консолидированный вид — один коммент, находки плоским списком" do
    test "inline-комментов больше нет — всё в summary (comments == [])" do
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: "x = 1")])
      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [{10, "  x = 0"}])})
      assert out.comments == []
    end

    test "каждая находка — обычный буллет (и с правкой, и без)" do
      clusters =
        Cluster.build([
          finding(file: "lib/a.ex", line: 10, severity: "P0", suggestion: "x = 1"),
          finding(file: "lib/b.ex", line: 5, severity: "P2", suggestion: nil, message: "плохо")
        ])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [{10, "  x = 0"}])})
      assert out.summary =~ "### Findings"
      assert out.summary =~ "- **P0**"
      assert out.summary =~ "- **P2**"
    end

    test "сколько бы правок ни было — дропдаун ровно один (находки не сворачиваются)" do
      index =
        Map.merge(diff_index("lib/a.ex", [{10, "x=0"}]), diff_index("lib/b.ex", [{20, "y=0"}]))

      clusters =
        Cluster.build([
          finding(file: "lib/a.ex", line: 10, severity: "P0", suggestion: "x = 1"),
          finding(file: "lib/b.ex", line: 20, severity: "P1", suggestion: "y = 2")
        ])

      out = Render.render(clusters, %{diff_index: index})
      assert out.summary |> String.split("<details>") |> length() == 2
    end
  end

  describe "общий дропдаун — код-доказательства + промпт" do
    test "находка с правкой → внутри дропдауна diff «сломанное → предложение»" do
      clusters =
        Cluster.build([finding(file: "lib/a.ex", line: 10, severity: "P0", suggestion: "x = 1")])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [{10, "  x = 0"}])})
      assert out.summary =~ "<details>"
      assert out.summary =~ "Code evidence"
      assert out.summary =~ "Broken code"
      assert out.summary =~ "```diff"
      assert out.summary =~ "-   x = 0"
      assert out.summary =~ "+ x = 1"
    end

    test "строки нет в диффе → только предложение (+), без сломанной (-)" do
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: "x = 1")])
      out = Render.render(clusters, %{diff_index: %{}})
      assert out.summary =~ "```diff"
      assert out.summary =~ "+ x = 1"

      # внутри diff-блока нет удаляемой (-) стороны (буллеты находок «- …» не в счёт)
      refute out.summary =~ "diff\n- "
    end

    test "ни одной правки → блока доказательств нет, но промпт есть" do
      clusters =
        Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: nil, message: "плохо")])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [{10, "code"}])})
      refute out.summary =~ "```diff"
      refute out.summary =~ "Broken code"
      assert out.summary =~ "#### Prompt"
    end

    test "suggestion с тройными бэктиками → забор диффа длиннее (блок не рвётся)" do
      code = "```\nIO.puts(1)\n```"
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: code)])
      out = Render.render(clusters, %{diff_index: %{}})
      assert out.summary =~ "````diff"
      assert out.summary =~ "IO.puts(1)"
    end

    test "готовый текст-промпт перечисляет все находки" do
      clusters =
        Cluster.build([
          finding(
            file: "lib/a.ex",
            line: 10,
            severity: "P0",
            message: "инъекция",
            suggestion: "safe()"
          ),
          finding(file: "lib/b.ex", line: 5, severity: "P1", message: "деление", suggestion: nil)
        ])

      out = Render.render(clusters, %{diff_index: %{}})
      assert out.summary =~ "AI-agent prompt"
      assert out.summary =~ "```text"
      assert out.summary =~ "1. lib/a.ex:10"
      assert out.summary =~ "2. lib/b.ex:5"
      assert out.summary =~ "инъекция"
      assert out.summary =~ "suggestion:"
      assert out.summary =~ "safe()"
    end

    test "пустые кластеры → дропдауна нет" do
      out = Render.render([]).summary
      refute out =~ "AI-agent prompt"
      refute out =~ "<details>"
    end
  end

  describe "лимит размера (защита от 422 GitHub)" do
    test "большой PR не пробивает лимит — деградирует/усекается, обзор не теряется" do
      big =
        for i <- 1..200 do
          finding(
            file: "lib/f#{i}.ex",
            line: i,
            severity: "P1",
            message: String.duplicate("очень длинное описание проблемы ", 30),
            suggestion: String.duplicate("x = #{i}\n", 8)
          )
        end

      out = Render.render(Cluster.build(big))
      assert String.length(out.summary) <= 60_000
      assert out.summary =~ "limit"

      # шапка и сами находки всё равно на месте — обзор не пропал целиком
      assert out.summary =~ "Multi-agent review"
      assert out.summary =~ "### Findings"
    end

    test "обычный PR: полный вид влезает — без пометок о деградации, с промптом" do
      out =
        Render.render(Cluster.build([finding(file: "lib/a.ex", line: 1, suggestion: "x = 1")]))

      refute out.summary =~ "exceeded"
      refute out.summary =~ "truncated"
      assert out.summary =~ "AI-agent prompt"
    end
  end
end
