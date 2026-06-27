defmodule Aggregator.FindingTest do
  use ExUnit.Case, async: true

  import Aggregator.Factory
  alias Aggregator.Finding

  describe "from_envelope/1" do
    test "разбирает конверт в список Finding и протаскивает agent в каждый" do
      env =
        envelope("codex", [
          finding_map(%{"line" => 10, "severity" => "P0"}),
          finding_map(%{"line" => 20, "severity" => "P2"})
        ])

      assert [%Finding{} = a, %Finding{} = b] = Finding.from_envelope(env)
      assert a.agent == "codex"
      assert b.agent == "codex"
      assert a.line == 10 and a.severity == "P0"
      assert b.line == 20 and b.severity == "P2"
    end

    test "пустой findings → пустой список" do
      assert [] = Finding.from_envelope(envelope("claude", []))
    end

    test "line: null сохраняется" do
      assert [%Finding{line: nil}] =
               Finding.from_envelope(envelope("claude", [finding_map(%{"line" => nil})]))
    end

    test "поле agent из элемента игнорируется в пользу конверта" do
      # даже если агент случайно прокрался в finding — побеждает уровень конверта
      env = envelope("deepseek", [finding_map(%{"agent" => "claude"})])
      assert [%Finding{agent: "deepseek"}] = Finding.from_envelope(env)
    end
  end

  describe "from_map/1" do
    test "опциональные поля отсутствуют → nil" do
      f = Finding.from_map(%{"agent" => "claude", "file" => "a.ex", "severity" => "P1"})
      assert f.line == nil and f.category == nil and f.message == nil and f.suggestion == nil
    end
  end
end
