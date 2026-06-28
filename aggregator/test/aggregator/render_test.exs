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
      assert out.summary =~ "Мульти-агентное ревью"
      assert out.summary =~ "Замечаний нет"
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
      assert out.summary =~ "3 находок"
      assert out.summary =~ "2 кластеров"
      assert out.summary =~ "P0: 1"
      assert out.summary =~ "P2: 1"
    end

    test "advisory по умолчанию → статус «не блокирует»" do
      out = Render.render(Cluster.build([finding(line: 1)]))
      assert out.summary =~ "✅ не блокирует merge"
    end

    test "решение block → статус «блокирует»; упавшие агенты в баннере" do
      out =
        Render.render(Cluster.build([finding(line: 1, severity: "P0")]), %{
          failed_agents: ["codex"],
          panel_size: 2,
          decision: {:block, "найден блокирующий P0"}
        })

      assert out.summary =~ "⛔ блокирует merge"
      assert out.summary =~ "Не отработали: codex"
      assert out.summary =~ "1/2"
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

  describe "консолидированный вид — один коммент, дропдауны, дифф" do
    test "inline-комментов больше нет — всё в summary (comments == [])" do
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: "x = 1")])
      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [{10, "  x = 0"}])})
      assert out.comments == []
    end

    test "находка с правкой → <details> с diff «сломанное → предложение»" do
      clusters =
        Cluster.build([
          finding(file: "lib/a.ex", line: 10, severity: "P0", suggestion: "x = 1")
        ])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [{10, "  x = 0"}])})
      assert out.summary =~ "<details>"
      assert out.summary =~ "<summary>"
      assert out.summary =~ "```diff"
      assert out.summary =~ "-   x = 0"
      assert out.summary =~ "+ x = 1"
    end

    test "строки нет в диффе → только предложение (+), без сломанной (-)" do
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: "x = 1")])
      out = Render.render(clusters, %{diff_index: %{}})
      assert out.summary =~ "```diff"
      assert out.summary =~ "+ x = 1"
      refute out.summary =~ "\n- "
    end

    test "находка без suggestion → обычный буллет, без diff-блока" do
      clusters =
        Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: nil, message: "плохо")])

      out = Render.render(clusters, %{diff_index: diff_index("lib/a.ex", [{10, "code"}])})
      assert out.summary =~ "- **P2**"
      refute out.summary =~ "```diff"
    end

    test "suggestion с тройными бэктиками → забор диффа длиннее (блок не рвётся)" do
      code = "```\nIO.puts(1)\n```"
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: code)])
      out = Render.render(clusters, %{diff_index: %{}})
      assert out.summary =~ "````diff"
      assert out.summary =~ "IO.puts(1)"
    end
  end

  describe "промпт «исправить все находки»" do
    test "<details> с готовым текстом-промптом и всеми находками" do
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
      assert out.summary =~ "Промпт для ИИ-агента"
      assert out.summary =~ "```text"
      assert out.summary =~ "1. lib/a.ex:10"
      assert out.summary =~ "2. lib/b.ex:5"
      assert out.summary =~ "инъекция"
      assert out.summary =~ "предложение:"
      assert out.summary =~ "safe()"
    end

    test "пустые кластеры → промпта нет" do
      refute Render.render([]).summary =~ "Промпт для ИИ-агента"
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
      assert out.summary =~ "лимит"

      # шапка и сами находки всё равно на месте — обзор не пропал целиком
      assert out.summary =~ "Мульти-агентное ревью"
      assert out.summary =~ "### Находки"
    end

    test "обычный PR: полный вид влезает — без пометок о деградации, с промптом" do
      out =
        Render.render(Cluster.build([finding(file: "lib/a.ex", line: 1, suggestion: "x = 1")]))

      refute out.summary =~ "не уместил"
      refute out.summary =~ "обрезан"
      assert out.summary =~ "Промпт для ИИ-агента"
    end
  end
end
