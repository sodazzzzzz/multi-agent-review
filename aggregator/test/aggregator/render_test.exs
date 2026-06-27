defmodule Aggregator.RenderTest do
  use ExUnit.Case, async: true

  import Aggregator.Factory
  alias Aggregator.{Cluster, Render}

  defp in_hunk(file, lines), do: %{file => MapSet.new(lines)}

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

    test "многострочный текст схлопывается в одну строку в bullet'е" do
      clusters = Cluster.build([finding(line: 1, message: "первая\nвторая")])
      out = Render.render(clusters, %{messages: %{1 => "строка-а\n\nстрока-б"}})
      refute out.summary =~ "строка-а\n\nстрока-б"
      assert out.summary =~ "строка-а строка-б"
    end
  end

  describe "comments — однокликовые правки" do
    test "suggestion + строка в диффе → review-коммент с fenced suggestion" do
      clusters =
        Cluster.build([
          finding(
            agent: "claude",
            file: "lib/a.ex",
            line: 10,
            severity: "P0",
            suggestion: "x = 1"
          )
        ])

      out = Render.render(clusters, %{diff_index: in_hunk("lib/a.ex", [10])})
      assert [%{path: "lib/a.ex", line: 10, body: body}] = out.comments
      assert body =~ "```suggestion"
      assert body =~ "x = 1"
      assert body =~ "P0"
    end

    test "suggestion есть, но строка вне диффа → коммента нет (но в summary есть)" do
      clusters =
        Cluster.build([
          finding(
            agent: "claude",
            file: "lib/a.ex",
            line: 10,
            severity: "P0",
            suggestion: "x = 1"
          )
        ])

      out = Render.render(clusters, %{diff_index: %{}})
      assert out.comments == []
      assert out.summary =~ "lib/a.ex:10"
    end

    test "без suggestion коммент не создаётся даже если строка в диффе" do
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: nil)])
      out = Render.render(clusters, %{diff_index: in_hunk("lib/a.ex", [10])})
      assert out.comments == []
    end

    test "коммент-находка помечается в summary как имеющая правку" do
      clusters =
        Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: "y = 2")])

      out = Render.render(clusters, %{diff_index: in_hunk("lib/a.ex", [10])})
      assert out.summary =~ "однокликовая правка"
    end

    test "обычный suggestion (без бэктиков) обрамляется забором из 3 бэктиков" do
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: "x = 1")])
      out = Render.render(clusters, %{diff_index: in_hunk("lib/a.ex", [10])})
      assert [%{body: body}] = out.comments
      assert body =~ "```suggestion\n"
      refute body =~ "````suggestion"
    end

    test "suggestion с тройными бэктиками → забор длиннее, блок не закрывается раньше" do
      code = "```\nIO.puts(1)\n```"
      clusters = Cluster.build([finding(file: "lib/a.ex", line: 10, suggestion: code)])
      out = Render.render(clusters, %{diff_index: in_hunk("lib/a.ex", [10])})
      assert [%{body: body}] = out.comments

      # внутри серия из 3 бэктиков → внешний забор минимум 4
      assert body =~ "````suggestion\n"
      assert body =~ code
      # закрывающий забор тоже из 4 бэктиков
      assert String.ends_with?(body, "\n````")
    end
  end
end
