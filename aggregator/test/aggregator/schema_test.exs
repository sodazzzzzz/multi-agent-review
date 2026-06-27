defmodule Aggregator.SchemaTest do
  use ExUnit.Case, async: true

  import Aggregator.Factory
  alias Aggregator.Schema

  describe "validate/1 — валидные конверты" do
    test "полный валидный конверт" do
      assert :ok = Schema.validate(envelope())
    end

    test "пустой список findings допустим" do
      assert :ok = Schema.validate(envelope("codex", []))
    end

    test "line: null допустим (находка без привязки к строке)" do
      assert :ok = Schema.validate(envelope("claude", [finding_map(%{"line" => nil})]))
    end

    test "suggestion: null допустим" do
      assert :ok =
               Schema.validate(envelope("deepseek", [finding_map(%{"suggestion" => "x = 1"})]))

      assert :ok = Schema.validate(envelope("deepseek", [finding_map(%{"suggestion" => nil})]))
    end

    test "все три имени агента валидны" do
      for a <- ["claude", "codex", "deepseek"] do
        assert :ok = Schema.validate(envelope(a))
      end
    end
  end

  describe "validate/1 — невалидные конверты" do
    test "неизвестный агент отвергается" do
      assert {:error, _} = Schema.validate(envelope("gpt5"))
    end

    test "отсутствие обязательного поля (severity) отвергается" do
      bad = envelope("claude", [Map.delete(finding_map(), "severity")])
      assert {:error, reasons} = Schema.validate(bad)
      assert is_list(reasons)
    end

    test "лишний ключ в finding отвергается (additionalProperties: false)" do
      bad = envelope("claude", [finding_map(%{"foo" => "bar"})])
      assert {:error, _} = Schema.validate(bad)
    end

    test "лишний ключ на уровне конверта отвергается" do
      bad = Map.put(envelope(), "extra", 1)
      assert {:error, _} = Schema.validate(bad)
    end

    test "неизвестная severity отвергается" do
      assert {:error, _} =
               Schema.validate(envelope("claude", [finding_map(%{"severity" => "P9"})]))
    end

    test "неизвестная категория отвергается" do
      assert {:error, _} =
               Schema.validate(envelope("claude", [finding_map(%{"category" => "vibes"})]))
    end

    test "line как строка отвергается" do
      assert {:error, _} = Schema.validate(envelope("claude", [finding_map(%{"line" => "42"})]))
    end

    test "line < 1 отвергается" do
      assert {:error, _} = Schema.validate(envelope("claude", [finding_map(%{"line" => 0})]))
    end

    test "пустой message отвергается" do
      assert {:error, _} = Schema.validate(envelope("claude", [finding_map(%{"message" => ""})]))
    end

    test "findings не массив отвергается" do
      assert {:error, _} = Schema.validate(%{"agent" => "claude", "findings" => "nope"})
    end

    test "не-объект на верхнем уровне → ошибка, без краша" do
      for non_object <- [[], "строка", 42, true, nil] do
        assert {:error, _} = Schema.validate(non_object)
      end
    end

    test "пустой suggestion отвергается (minLength)" do
      assert {:error, _} =
               Schema.validate(envelope("claude", [finding_map(%{"suggestion" => ""})]))
    end
  end

  describe "validate_json/1" do
    test "валидный JSON-текст проходит" do
      assert :ok = Schema.validate_json(Jason.encode!(envelope()))
    end

    test "битый JSON → :invalid_json" do
      assert {:error, :invalid_json} = Schema.validate_json("{ not json ")
    end

    test "валидный JSON, но невалидная схема → список причин" do
      assert {:error, reasons} = Schema.validate_json(Jason.encode!(envelope("gpt5")))
      assert is_list(reasons)
    end

    test "валидный JSON-не-объект → {:error}, без краша" do
      assert {:error, _} = Schema.validate_json("[1,2,3]")
      assert {:error, _} = Schema.validate_json("\"просто строка\"")
      assert {:error, _} = Schema.validate_json("42")
    end
  end
end
