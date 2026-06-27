defmodule Aggregator.PolishTest do
  use ExUnit.Case, async: true

  import Aggregator.Factory
  alias Aggregator.{Cluster, Polish}

  # Один кластer id:1, consensus 2, severity P0, file lib/a.ex, line 10.
  defp clusters do
    Cluster.build([
      finding(agent: "claude", file: "lib/a.ex", line: 10, severity: "P0"),
      finding(agent: "codex", file: "lib/a.ex", line: 11, severity: "P1")
    ])
  end

  describe "merge/2 — применение правок" do
    test "валидная правка по существующему id применяется к message" do
      result = Polish.merge(clusters(), [%{"id" => 1, "message" => "переписанный текст"}])
      assert result.overrides == %{1 => "переписанный текст"}
      assert result.applied == 1
      assert result.rejected == 0
    end

    test "текст обрезается по краям" do
      result = Polish.merge(clusters(), [%{"id" => 1, "message" => "  чистый  "}])
      assert result.overrides == %{1 => "чистый"}
    end

    test "пустой список правок → пустые overrides" do
      assert Polish.merge(clusters(), []) == %{overrides: %{}, applied: 0, rejected: 0}
    end
  end

  describe "merge/2 — отклонение (fact-freeze)" do
    test "несуществующий id отвергается" do
      result = Polish.merge(clusters(), [%{"id" => 99, "message" => "мимо"}])
      assert result.overrides == %{}
      assert result.rejected == 1
    end

    test "пустой/пробельный message отвергается (остаётся детерминированный)" do
      for msg <- ["", "   ", "\n\t"] do
        result = Polish.merge(clusters(), [%{"id" => 1, "message" => msg}])
        assert result.overrides == %{}
        assert result.rejected == 1
      end
    end

    test "message не строка отвергается" do
      result = Polish.merge(clusters(), [%{"id" => 1, "message" => 42}])
      assert result.rejected == 1
    end

    test "id не положительное целое отвергается (в т.ч. строковый \"1\")" do
      for bad <- ["1", 0, -1, 1.0, nil] do
        result = Polish.merge(clusters(), [%{"id" => bad, "message" => "x"}])
        assert result.overrides == %{}
        assert result.rejected == 1
      end
    end

    test "правка-не-map в списке безопасно отвергается" do
      result = Polish.merge(clusters(), ["мусор", 123, nil])
      assert result.overrides == %{}
      assert result.rejected == 3
    end
  end

  describe "merge/2 — эхо-инварианты" do
    test "совпадающее эхо severity/line/file/consensus → применяется" do
      rewrite = %{
        "id" => 1,
        "message" => "ок",
        "severity" => "P0",
        "line" => 10,
        "file" => "lib/a.ex",
        "consensus" => 2
      }

      assert Polish.merge(clusters(), [rewrite]).overrides == %{1 => "ок"}
    end

    test "несовпадающее эхо severity → отвергается" do
      rewrite = %{"id" => 1, "message" => "ок", "severity" => "P2"}
      assert Polish.merge(clusters(), [rewrite]).overrides == %{}
    end

    test "несовпадающее эхо line → отвергается" do
      rewrite = %{"id" => 1, "message" => "ок", "line" => 999}
      assert Polish.merge(clusters(), [rewrite]).overrides == %{}
    end

    test "несовпадающее эхо consensus → отвергается" do
      rewrite = %{"id" => 1, "message" => "ок", "consensus" => 1}
      assert Polish.merge(clusters(), [rewrite]).overrides == %{}
    end

    test "отсутствие эхо-полей не мешает (нечего сверять)" do
      assert Polish.merge(clusters(), [%{"id" => 1, "message" => "ок"}]).overrides == %{1 => "ок"}
    end
  end

  test "смешанный батч: валидные применяются, невалидные считаются rejected" do
    cs =
      Cluster.build([
        finding(agent: "claude", file: "lib/a.ex", line: 10, severity: "P0"),
        finding(agent: "claude", file: "lib/b.ex", line: 5, severity: "P2")
      ])

    rewrites = [
      %{"id" => 1, "message" => "первый"},
      %{"id" => 2, "message" => "второй", "severity" => "WRONG"},
      %{"id" => 2, "message" => "второй-ок"},
      %{"id" => 7, "message" => "нет такого"}
    ]

    result = Polish.merge(cs, rewrites)
    assert result.applied == 2
    assert result.rejected == 2
    assert Map.has_key?(result.overrides, 1)
    assert result.overrides[2] == "второй-ок"
  end
end
