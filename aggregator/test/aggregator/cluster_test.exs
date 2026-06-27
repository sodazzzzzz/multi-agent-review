defmodule Aggregator.ClusterTest do
  use ExUnit.Case, async: true

  import Aggregator.Factory
  alias Aggregator.Cluster

  describe "build/2 — группировка по окну строк" do
    test "findings в пределах окна сливаются в один кластер" do
      findings = [
        finding(agent: "claude", file: "lib/a.ex", line: 40),
        finding(agent: "codex", file: "lib/a.ex", line: 42)
      ]

      assert [%Cluster{items: items, consensus: 2}] = Cluster.build(findings, 3)
      assert length(items) == 2
    end

    test "findings дальше окна — разные кластеры" do
      findings = [
        finding(agent: "claude", file: "lib/a.ex", line: 10),
        finding(agent: "codex", file: "lib/a.ex", line: 100)
      ]

      assert [_, _] = Cluster.build(findings, 3)
    end

    test "один и тот же файл, но разные хунки не путаются" do
      clusters =
        Cluster.build(
          [
            finding(file: "lib/a.ex", line: 5),
            finding(file: "lib/a.ex", line: 6),
            finding(file: "lib/a.ex", line: 200)
          ],
          3
        )

      assert length(clusters) == 2
    end

    test "разные файлы никогда не сливаются, даже на близких строках" do
      findings = [
        finding(file: "lib/a.ex", line: 10),
        finding(file: "lib/b.ex", line: 10)
      ]

      assert length(Cluster.build(findings, 3)) == 2
    end
  end

  describe "build/2 — задокументированный дрейф якоря" do
    test "цепочка 42 → 45 → 48 при window 3 даёт {42,45} и {48}" do
      findings = [
        finding(agent: "claude", file: "lib/a.ex", line: 42),
        finding(agent: "codex", file: "lib/a.ex", line: 45),
        finding(agent: "deepseek", file: "lib/a.ex", line: 48)
      ]

      clusters = Cluster.build(findings, 3)

      assert length(clusters) == 2
      first = Enum.find(clusters, &(&1.line == 42))
      assert length(first.items) == 2
      assert Enum.any?(clusters, &(&1.line == 48 and length(&1.items) == 1))
    end
  end

  describe "build/2 — консенсус и severity внутри кластера" do
    test "консенсус считает разных агентов, а не findings" do
      findings = [
        finding(agent: "claude", file: "lib/a.ex", line: 10),
        finding(agent: "claude", file: "lib/a.ex", line: 11)
      ]

      assert [%Cluster{consensus: 1, agents: ["claude"]}] = Cluster.build(findings, 3)
    end

    test "severity кластера = максимум по входящим" do
      findings = [
        finding(agent: "claude", file: "lib/a.ex", line: 10, severity: "P2"),
        finding(agent: "codex", file: "lib/a.ex", line: 11, severity: "P0")
      ]

      assert [%Cluster{severity: "P0"}] = Cluster.build(findings, 3)
    end

    test "агенты в кластере отсортированы и уникальны" do
      findings = [
        finding(agent: "deepseek", file: "lib/a.ex", line: 10),
        finding(agent: "claude", file: "lib/a.ex", line: 11),
        finding(agent: "claude", file: "lib/a.ex", line: 12)
      ]

      assert [%Cluster{agents: ["claude", "deepseek"]}] = Cluster.build(findings, 3)
    end
  end

  describe "build/2 — findings без строки (line: nil)" do
    test "каждый идёт в собственный кластер и не сливается с другими" do
      findings = [
        finding(file: "lib/a.ex", line: nil),
        finding(file: "lib/a.ex", line: nil)
      ]

      clusters = Cluster.build(findings, 3)
      assert length(clusters) == 2
      assert Enum.all?(clusters, &(&1.line == nil))
    end

    test "безстрочный finding не приклеивается к строчному того же файла" do
      findings = [
        finding(agent: "claude", file: "lib/a.ex", line: 1),
        finding(agent: "codex", file: "lib/a.ex", line: nil)
      ]

      assert length(Cluster.build(findings, 3)) == 2
    end
  end

  describe "build/2 — сортировка и стабильные id" do
    test "кластеры с большим консенсусом идут выше" do
      findings = [
        # одиночка
        finding(agent: "claude", file: "lib/z.ex", line: 5, severity: "P0"),
        # тройной консенсус
        finding(agent: "claude", file: "lib/a.ex", line: 10),
        finding(agent: "codex", file: "lib/a.ex", line: 10),
        finding(agent: "deepseek", file: "lib/a.ex", line: 10)
      ]

      [first | _] = Cluster.build(findings, 3)
      assert first.consensus == 3
    end

    test "при равном консенсусе выше — серьёзнее severity" do
      findings = [
        finding(agent: "claude", file: "lib/a.ex", line: 10, severity: "P2"),
        finding(agent: "codex", file: "lib/b.ex", line: 10, severity: "P0")
      ]

      [first, second] = Cluster.build(findings, 3)
      assert first.severity == "P0"
      assert second.severity == "P2"
    end

    test "id присваиваются 1..n по финальному порядку" do
      findings = [
        finding(agent: "claude", file: "lib/a.ex", line: 10),
        finding(agent: "codex", file: "lib/a.ex", line: 10),
        finding(agent: "claude", file: "lib/b.ex", line: 5)
      ]

      ids = Cluster.build(findings, 3) |> Enum.map(& &1.id)
      assert ids == [1, 2]
    end
  end

  test "пустой вход → пустой список" do
    assert Cluster.build([], 3) == []
  end
end
