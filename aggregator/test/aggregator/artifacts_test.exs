defmodule Aggregator.ArtifactsTest do
  use ExUnit.Case, async: true

  import Aggregator.Factory
  alias Aggregator.{Artifacts, Finding}

  defp write(dir, rel, content) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  @tag :tmp_dir
  test "валидный артефакт читается, битый и схема-невалидный уходят в failed", %{tmp_dir: dir} do
    write(dir, "review-claude/review-claude.json", Jason.encode!(envelope("claude")))
    write(dir, "review-codex/review-codex.json", "{ битый json")

    write(
      dir,
      "review-deepseek/review-deepseek.json",
      Jason.encode!(%{"agent" => "deepseek", "findings" => [%{"file" => "x"}]})
    )

    result = Artifacts.load(dir)

    assert [%{agent: "claude", findings: [%Finding{} | _]}] = result.ok
    assert length(result.failed) == 2
    assert Enum.all?(result.failed, &is_map_key(&1, :source))
  end

  @tag :tmp_dir
  test "missing_agents отмечает не-ok агентов, сохраняя порядок ожидаемых", %{tmp_dir: dir} do
    write(dir, "review-claude/review-claude.json", Jason.encode!(envelope("claude")))

    result = Artifacts.load(dir)

    assert Artifacts.missing_agents(result, ["claude", "codex", "deepseek"]) == [
             "codex",
             "deepseek"
           ]
  end

  @tag :tmp_dir
  test "пустая директория → пусто и все агенты missing", %{tmp_dir: dir} do
    result = Artifacts.load(dir)
    assert result.ok == []
    assert result.failed == []
    assert Artifacts.missing_agents(result, ["claude", "codex"]) == ["claude", "codex"]
  end

  @tag :tmp_dir
  test "валидный JSON, но не объект ([]) уходит в failed, не роняя разбор", %{tmp_dir: dir} do
    write(dir, "review-codex/review-codex.json", "[1,2,3]")
    result = Artifacts.load(dir)
    assert result.ok == []
    assert [%{source: _}] = result.failed
  end
end
