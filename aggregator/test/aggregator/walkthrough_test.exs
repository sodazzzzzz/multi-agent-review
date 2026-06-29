defmodule Aggregator.WalkthroughTest do
  use ExUnit.Case, async: true

  alias Aggregator.Walkthrough

  describe "prompt/2" do
    test "включает инструкцию вернуть JSON-объект и текст диффа" do
      p = Walkthrough.prompt("diff --git a/x b/x\n+code", [])
      assert p =~ "STRICTLY with a single JSON object"
      assert p =~ "diff --git a/x b/x"
    end

    test "огромный дифф обрезается по бюджету" do
      p = Walkthrough.prompt(String.duplicate("x", 20_000), [])
      assert p =~ "[diff truncated]"
      assert String.length(p) < 14_000
    end
  end

  describe "parse/1" do
    test "валидный объект → нормализованная карта" do
      raw =
        Jason.encode!(%{
          "tldr" => "Adds a guard.",
          "files" => [%{"path" => "a.ex", "summary" => "guard"}],
          "mermaid" => "flowchart TD\nA-->B"
        })

      assert %{
               tldr: "Adds a guard.",
               files: [%{path: "a.ex", summary: "guard"}],
               mermaid: "flowchart TD\nA-->B"
             } = Walkthrough.parse(raw)
    end

    test "JSON в ```-заборе/с прозой — выкусываем объект" do
      raw = "Here you go:\n```json\n{\"tldr\":\"X.\",\"files\":[]}\n```"
      assert %{tldr: "X.", files: [], mermaid: nil} = Walkthrough.parse(raw)
    end

    test "пустой mermaid → nil; мусорные элементы files отброшены" do
      raw =
        Jason.encode!(%{
          "tldr" => "T.",
          "files" => [
            %{"path" => "", "summary" => "x"},
            "junk",
            %{"path" => "ok.ex", "summary" => "y"}
          ],
          "mermaid" => "   "
        })

      assert %{tldr: "T.", files: [%{path: "ok.ex", summary: "y"}], mermaid: nil} =
               Walkthrough.parse(raw)
    end

    test "нет/пустой tldr, не-JSON, не-строка → nil" do
      assert Walkthrough.parse(Jason.encode!(%{"files" => []})) == nil
      assert Walkthrough.parse(Jason.encode!(%{"tldr" => "   "})) == nil
      assert Walkthrough.parse("not json at all") == nil
      assert Walkthrough.parse("") == nil
      assert Walkthrough.parse(nil) == nil
      assert Walkthrough.parse(42) == nil
    end

    test "files ограничены лимитом (12)" do
      files = for i <- 1..30, do: %{"path" => "f#{i}.ex", "summary" => "s"}

      assert %{files: parsed} =
               Walkthrough.parse(Jason.encode!(%{"tldr" => "T.", "files" => files}))

      assert length(parsed) == 12
    end
  end
end
