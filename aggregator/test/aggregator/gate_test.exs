defmodule Aggregator.GateTest do
  use ExUnit.Case, async: true

  alias Aggregator.{Cluster, Gate}

  defp cluster(severity, consensus), do: %Cluster{severity: severity, consensus: consensus}

  describe "parse_mode/1" do
    test "известные значения" do
      assert Gate.parse_mode("p0") == :p0
      assert Gate.parse_mode("consensus-p0") == :consensus_p0
      assert Gate.parse_mode("none") == :none
    end

    test "неизвестное/nil → :none (безопасный advisory-дефолт)" do
      assert Gate.parse_mode("whatever") == :none
      assert Gate.parse_mode(nil) == :none
    end
  end

  describe "decide/2" do
    test ":none всегда pass, даже при P0 3/3" do
      assert {:pass, _} = Gate.decide([cluster("P0", 3)], :none)
    end

    test ":p0 блокирует при любом P0" do
      assert {:block, _} = Gate.decide([cluster("P2", 3), cluster("P0", 1)], :p0)
    end

    test ":p0 пропускает без P0" do
      assert {:pass, _} = Gate.decide([cluster("P1", 3), cluster("P2", 2)], :p0)
    end

    test ":consensus_p0 блокирует только при P0 с консенсусом ≥ 2" do
      assert {:block, _} = Gate.decide([cluster("P0", 2)], :consensus_p0)
      assert {:block, _} = Gate.decide([cluster("P0", 3)], :consensus_p0)
    end

    test ":consensus_p0 пропускает одиночный P0 (1/3)" do
      assert {:pass, _} = Gate.decide([cluster("P0", 1)], :consensus_p0)
    end

    test "пустой список — pass в любом режиме" do
      for mode <- [:none, :p0, :consensus_p0] do
        assert {:pass, _} = Gate.decide([], mode)
      end
    end
  end

  describe "exit_code/1" do
    test "pass → 0, block → 1" do
      assert Gate.exit_code({:pass, "x"}) == 0
      assert Gate.exit_code({:block, "x"}) == 1
    end
  end
end
