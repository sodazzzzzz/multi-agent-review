defmodule Aggregator.ConsensusTest do
  use ExUnit.Case, async: true

  import Aggregator.Factory
  alias Aggregator.Consensus

  describe "severity_rank/1" do
    test "P0 серьёзнее P1 серьёзнее P2 (меньший ранг = серьёзнее)" do
      assert Consensus.severity_rank("P0") < Consensus.severity_rank("P1")
      assert Consensus.severity_rank("P1") < Consensus.severity_rank("P2")
    end

    test "падает на неизвестной severity (намеренно — ловим мусор от агентов)" do
      assert_raise KeyError, fn -> Consensus.severity_rank("P9") end
    end
  end

  describe "max_severity/1" do
    test "берёт самую серьёзную из набора" do
      findings = [finding(severity: "P2"), finding(severity: "P0"), finding(severity: "P1")]
      assert Consensus.max_severity(findings) == "P0"
    end

    test "одинаковые severity → она же" do
      assert Consensus.max_severity([finding(severity: "P1"), finding(severity: "P1")]) == "P1"
    end

    test "пустой список падает намеренно (контракт: вход непустой)" do
      assert_raise Enum.EmptyError, fn -> Consensus.max_severity([]) end
    end
  end

  describe "count/1 — консенсус = число РАЗНЫХ агентов" do
    test "три разных агента → 3" do
      findings = [finding(agent: "claude"), finding(agent: "codex"), finding(agent: "deepseek")]
      assert Consensus.count(findings) == 3
    end

    test "дубли от одного агента не накручивают консенсус" do
      findings = [finding(agent: "claude"), finding(agent: "claude"), finding(agent: "codex")]
      assert Consensus.count(findings) == 2
    end
  end

  describe "blocking?/1" do
    test "есть P0 → блокирует" do
      assert Consensus.blocking?([finding(severity: "P2"), finding(severity: "P0")])
    end

    test "только P1/P2 → не блокирует" do
      refute Consensus.blocking?([finding(severity: "P1"), finding(severity: "P2")])
    end
  end
end
