defmodule Aggregator.CLITest do
  use ExUnit.Case, async: true

  import Aggregator.Factory
  alias Aggregator.{CLI, Github}

  @moduletag :tmp_dir

  @patch """
  diff --git a/lib/a.ex b/lib/a.ex
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -9,0 +10,1 @@
  +строка 10 в хунке
  """

  defp write_review(dir, agent, finding) do
    sub = Path.join([dir, "reviews", "review-#{agent}"])
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "review-#{agent}.json"), Jason.encode!(envelope(agent, [finding])))
  end

  # Фейк-«claude»: печатает JSON-конверт с правкой message по id:1.
  defp fake_claude(dir) do
    inner = Jason.encode!([%{"id" => 1, "message" => "причёсано P0"}])
    out = Path.join(dir, "claude_out.json")
    File.write!(out, Jason.encode!(%{"type" => "result", "result" => inner}))
    bin = Path.join(dir, "fake_claude.sh")

    # Путь в кавычки: tmp_dir ExUnit включает имя теста, где бывают скобки/пробелы —
    # без кавычек sh сломался бы на них (и причёсывание молча отвалилось бы).
    File.write!(bin, "#!/bin/sh\ncat '#{out}'\n")
    File.chmod!(bin, 0o755)
    bin
  end

  # Клиент с адаптером, который шлёт каждый POST тест-процессу и отвечает 201.
  defp capturing_client do
    test = self()

    adapter = fn req ->
      url = to_string(req.url)
      send(test, {:posted, url, req.body})

      body =
        if String.contains?(url, "/issues/"), do: %{"html_url" => "HTML_URL"}, else: %{"id" => 99}

      {req, Req.Response.new(status: 201, body: body)}
    end

    Github.new(owner: "o", repo: "r", pr: 7, token: "t", req_options: [adapter: adapter])
  end

  # Теперь ревью — ОДИН issue-комментарий (inline-комментов к строкам нет).
  # Возвращает распарсенное тело summary, проверив, что второго постинга не было.
  defp gather_summary do
    assert_received {:posted, url, body}
    assert String.contains?(url, "/issues/")
    refute_received {:posted, _u, _b}
    body |> IO.iodata_to_binary() |> Jason.decode!()
  end

  setup %{tmp_dir: dir} do
    write_review(
      dir,
      "claude",
      finding_map(%{
        "line" => 10,
        "severity" => "P0",
        "message" => "сырой claude",
        "suggestion" => "x = 1"
      })
    )

    write_review(
      dir,
      "codex",
      finding_map(%{"line" => 11, "severity" => "P1", "message" => "сырой codex"})
    )

    patch_path = Path.join(dir, "diff.patch")
    File.write!(patch_path, @patch)
    out_path = Path.join(dir, "gh_output")

    cfg = %{
      reviews_dir: Path.join(dir, "reviews"),
      diff_path: patch_path,
      window: 3,
      fail_on: "none",
      model: "claude-opus-4-8",
      claude_bin: fake_claude(dir),
      expected_agents: ["claude", "codex", "deepseek"],
      github_output: out_path
    }

    %{cfg: cfg, out_path: out_path, client: capturing_client()}
  end

  test "end-to-end: ОДИН консолидированный коммент (правка в дропдауне) + причёсанный текст, advisory → exit 0",
       %{cfg: cfg, out_path: out_path, client: client} do
    assert CLI.run(client, cfg) == 0

    summary = gather_summary()["body"]

    # Консолидировано: причёсанный текст (override), упавший агент, метка панели, файл:строка
    assert summary =~ "причёсано P0"
    assert summary =~ "Did not complete: deepseek"
    # #5: 2 of 3 expected agents agree (deepseek absent) → 2/3, not 2/2
    assert summary =~ "2/3"
    assert summary =~ "lib/a.ex:10"

    # Сама находка — буллетом в списке; правка ушла в общий дропдаун: diff
    # «сломанное → предложение» внутри того же коммента
    assert summary =~ "<details>"
    assert summary =~ "```diff"
    assert summary =~ "- строка 10 в хунке"
    assert summary =~ "+ x = 1"

    # И готовый промпт «исправь все находки» в том же дропдауне
    assert summary =~ "AI-agent prompt"

    # GITHUB_OUTPUT
    output = File.read!(out_path)
    assert output =~ "clusters=1"
    assert output =~ "blocking=false"
    assert output =~ "summary_url=HTML_URL"
  end

  test "fail_on=p0 + P0-кластер → exit 1 и статус «блокирует»",
       %{cfg: cfg, client: client} do
    assert CLI.run(client, %{cfg | fail_on: "p0"}) == 1

    assert gather_summary()["body"] =~ "⛔ blocks merge"
  end

  test "нет diff_path → нет inline-комментов, постится только summary",
       %{cfg: cfg, client: client} do
    assert CLI.run(client, %{cfg | diff_path: nil}) == 0

    assert_received {:posted, url, body}
    assert String.contains?(url, "/issues/")

    # находка всё равно в сводке, просто без однокликовой правки
    assert (body |> IO.iodata_to_binary() |> Jason.decode!())["body"] =~ "lib/a.ex:10"
    refute_received {:posted, _u, _b}
  end

  test "пустые артефакты → «замечаний нет», exit 0, постится только summary (review-POST не уходит)",
       %{cfg: cfg, client: client} do
    empty = Path.join(Path.dirname(cfg.reviews_dir), "empty_reviews")
    File.mkdir_p!(empty)

    assert CLI.run(client, %{cfg | reviews_dir: empty}) == 0

    assert_received {:posted, url, body}
    assert String.contains?(url, "/issues/")
    assert (body |> IO.iodata_to_binary() |> Jason.decode!())["body"] =~ "No issues found"

    # пустой список комментов → POST на /pulls/.../reviews не отправляется
    refute_received {:posted, _other, _b}
  end
end
