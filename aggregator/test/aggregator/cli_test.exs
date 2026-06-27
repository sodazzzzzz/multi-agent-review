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
    File.write!(bin, "#!/bin/sh\ncat #{out}\n")
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

  defp gather_posts do
    assert_received {:posted, url1, body1}
    assert_received {:posted, url2, body2}

    Enum.reduce([{url1, body1}, {url2, body2}], %{}, fn {url, body}, acc ->
      decoded = body |> IO.iodata_to_binary() |> Jason.decode!()

      cond do
        String.contains?(url, "/pulls/") -> Map.put(acc, :review, decoded)
        String.contains?(url, "/issues/") -> Map.put(acc, :summary, decoded)
      end
    end)
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

  test "end-to-end: постит review с suggestion + причёсанный summary, advisory → exit 0",
       %{cfg: cfg, out_path: out_path, client: client} do
    assert CLI.run(client, cfg) == 0

    posts = gather_posts()

    # PR-review с однокликовой правкой на строке 10 (в хунке)
    assert %{"event" => "COMMENT", "comments" => [comment]} = posts.review
    assert comment["path"] == "lib/a.ex"
    assert comment["line"] == 10
    assert comment["side"] == "RIGHT"
    assert comment["body"] =~ "```suggestion"
    assert comment["body"] =~ "x = 1"

    # Сводка: причёсанный текст (override), пометка упавшего агента, метка панели
    summary = posts.summary["body"]
    assert summary =~ "причёсано P0"
    assert summary =~ "Не отработали: deepseek"
    assert summary =~ "2/2"
    assert summary =~ "lib/a.ex:10"

    # GITHUB_OUTPUT
    output = File.read!(out_path)
    assert output =~ "clusters=1"
    assert output =~ "blocking=false"
    assert output =~ "summary_url=HTML_URL"
  end

  test "fail_on=p0 + P0-кластер → exit 1 и статус «блокирует»",
       %{cfg: cfg, client: client} do
    assert CLI.run(client, %{cfg | fail_on: "p0"}) == 1

    posts = gather_posts()
    assert posts.summary["body"] =~ "⛔ блокирует merge"
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
    assert (body |> IO.iodata_to_binary() |> Jason.decode!())["body"] =~ "Замечаний нет"

    # пустой список комментов → POST на /pulls/.../reviews не отправляется
    refute_received {:posted, _other, _b}
  end
end
