defmodule Aggregator.ClaudeTest do
  use ExUnit.Case, async: true

  alias Aggregator.{Claude, Polish}

  # Фейк-«claude»: игнорирует аргументы и печатает заранее заданный stdout.
  defp fake_claude(dir, stdout) do
    payload = Path.join(dir, "out.txt")
    File.write!(payload, stdout)
    script = Path.join(dir, "fake_claude.sh")
    File.write!(script, "#!/bin/sh\ncat #{payload}\n")
    File.chmod!(script, 0o755)
    script
  end

  @tag :tmp_dir
  test "извлекает result из JSON-конверта claude --output-format json", %{tmp_dir: dir} do
    inner = ~s([{"id":1,"message":"улучшено"}])
    envelope = Jason.encode!(%{"type" => "result", "result" => inner})
    bin = fake_claude(dir, envelope)

    raw = Claude.rewrite("любой промпт", bin: bin)
    assert raw == inner
    assert [%{"id" => 1, "message" => "улучшено"}] = Polish.parse_rewrites(raw)
  end

  @tag :tmp_dir
  test "вывод без поля result возвращается как есть", %{tmp_dir: dir} do
    bin = fake_claude(dir, ~s([{"id":2,"message":"raw"}]))
    assert Claude.rewrite("p", bin: bin) == ~s([{"id":2,"message":"raw"}])
  end

  test "отсутствующий бинарь → \"\" (best-effort, не роняет прогон)" do
    assert Claude.rewrite("p", bin: "/no/such/claude-xyz-binary") == ""
  end

  @tag :tmp_dir
  test "ненулевой код выхода → \"\"", %{tmp_dir: dir} do
    script = Path.join(dir, "boom.sh")
    File.write!(script, "#!/bin/sh\nexit 3\n")
    File.chmod!(script, 0o755)
    assert Claude.rewrite("p", bin: script) == ""
  end
end
