defmodule Aggregator.WalkthroughTest do
  use ExUnit.Case, async: true

  alias Aggregator.Walkthrough

  describe "prompt/2" do
    test "включает инструкцию про JSON-объект, когорты и текст диффа" do
      p = Walkthrough.prompt("diff --git a/x b/x\n+code", [])
      assert p =~ "STRICTLY with a single JSON object"
      assert p =~ "GROUP related files into"
      assert p =~ "diff --git a/x b/x"
    end

    test "огромный дифф обрезается по бюджету" do
      p = Walkthrough.prompt(String.duplicate("x", 20_000), [])
      assert p =~ "[diff truncated]"
      assert String.length(p) < 14_000
    end
  end

  describe "parse/1" do
    test "валидный объект с когортами → нормализованная карта" do
      raw =
        Jason.encode!(%{
          "tldr" => "Adds metrics.",
          "groups" => [
            %{
              "title" => "Observability",
              "summary" => "prometheus + otel",
              "files" => [
                %{"path" => "obs.ex", "change" => "setup"},
                %{"path" => "tel.ex", "change" => "metrics"}
              ]
            }
          ],
          "mermaid" => "flowchart TD\nA-->B"
        })

      assert %{
               tldr: "Adds metrics.",
               mermaid: "flowchart TD\nA-->B",
               groups: [
                 %{
                   title: "Observability",
                   summary: "prometheus + otel",
                   files: [
                     %{path: "obs.ex", change: "setup"},
                     %{path: "tel.ex", change: "metrics"}
                   ]
                 }
               ]
             } = Walkthrough.parse(raw)
    end

    test "fallback: плоский files без groups → одна безымянная когорта" do
      raw = Jason.encode!(%{"tldr" => "T.", "files" => [%{"path" => "a.ex", "change" => "x"}]})

      assert %{groups: [%{title: "", summary: "", files: [%{path: "a.ex", change: "x"}]}]} =
               Walkthrough.parse(raw)
    end

    test "изменение файла принимается из change ИЛИ summary (дрейф модели)" do
      raw =
        Jason.encode!(%{
          "tldr" => "T.",
          "groups" => [%{"title" => "G", "files" => [%{"path" => "a.ex", "summary" => "y"}]}]
        })

      assert %{groups: [%{title: "G", summary: "", files: [%{path: "a.ex", change: "y"}]}]} =
               Walkthrough.parse(raw)
    end

    test "пустой change не затирает summary (берём первый непустой)" do
      raw =
        Jason.encode!(%{
          "tldr" => "T.",
          "groups" => [
            %{
              "title" => "G",
              "files" => [%{"path" => "a.ex", "change" => "", "summary" => "real"}]
            }
          ]
        })

      assert %{groups: [%{files: [%{path: "a.ex", change: "real"}]}]} = Walkthrough.parse(raw)
    end

    test "группа без title, но с файлами → безымянная когорта (не теряется)" do
      raw =
        Jason.encode!(%{
          "tldr" => "T.",
          "groups" => [%{"files" => [%{"path" => "a.ex", "change" => "x"}]}]
        })

      assert %{groups: [%{title: "", summary: "", files: [%{path: "a.ex", change: "x"}]}]} =
               Walkthrough.parse(raw)
    end

    test "JSON в ```-заборе/с прозой — выкусываем объект" do
      raw = "Here you go:\n```json\n{\"tldr\":\"X.\",\"groups\":[]}\n```"
      assert %{tldr: "X.", groups: [], mermaid: nil} = Walkthrough.parse(raw)
    end

    test "пустой mermaid → nil; мусор/пустые когорты и плохие файлы отброшены" do
      raw =
        Jason.encode!(%{
          "tldr" => "T.",
          "groups" => [
            "junk",
            %{"title" => "", "files" => []},
            %{
              "title" => "G",
              "files" => [%{"path" => "", "change" => "x"}, %{"path" => "ok.ex", "change" => "y"}]
            }
          ],
          "mermaid" => "   "
        })

      assert %{
               tldr: "T.",
               mermaid: nil,
               groups: [%{title: "G", files: [%{path: "ok.ex", change: "y"}]}]
             } =
               Walkthrough.parse(raw)
    end

    test "нет/пустой tldr, не-JSON, не-строка → nil" do
      assert Walkthrough.parse(Jason.encode!(%{"groups" => []})) == nil
      assert Walkthrough.parse(Jason.encode!(%{"tldr" => "   "})) == nil
      assert Walkthrough.parse("not json at all") == nil
      assert Walkthrough.parse("") == nil
      assert Walkthrough.parse(nil) == nil
      assert Walkthrough.parse(42) == nil
    end

    test "лимиты: 10 когорт, 15 файлов в когорте" do
      groups =
        for i <- 1..14 do
          %{
            "title" => "G#{i}",
            "files" => for(j <- 1..20, do: %{"path" => "f#{i}_#{j}.ex", "change" => "c"})
          }
        end

      assert %{groups: parsed} =
               Walkthrough.parse(Jason.encode!(%{"tldr" => "T.", "groups" => groups}))

      assert length(parsed) == 10
      assert length(hd(parsed).files) == 15
    end
  end
end
