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

  # Фейк-«claude»: по тексту промпта различает polish (массив правок) и walkthrough
  # (JSON-объект обзора); оба обёрнуты в result-конверт claude.
  defp fake_claude(dir) do
    polish = result_envelope(Jason.encode!([%{"id" => 1, "message" => "причёсано P0"}]))

    walk =
      result_envelope(
        Jason.encode!(%{
          "tldr" => "PR adds a guard.",
          "groups" => [
            %{
              "title" => "Demo",
              "summary" => "planted issues",
              "files" => [%{"path" => "lib/a.ex", "change" => "guard zero"}]
            }
          ],
          "mermaid" => ""
        })
      )

    pf = Path.join(dir, "polish_out.json")
    wf = Path.join(dir, "walk_out.json")
    File.write!(pf, polish)
    File.write!(wf, walk)
    bin = Path.join(dir, "fake_claude.sh")

    # claude зовётся как `claude -p <prompt> ...` → $2 = промпт. Walkthrough-преамбула
    # содержит «summarizing a pull request»; остальное — polish. Пути в кавычках: tmp_dir
    # включает имя теста (бывают скобки/пробелы).
    File.write!(bin, """
    #!/bin/sh
    case "$2" in
      *"summarizing a pull request"*) cat '#{wf}' ;;
      *) cat '#{pf}' ;;
    esac
    """)

    File.chmod!(bin, 0o755)
    bin
  end

  defp result_envelope(inner), do: Jason.encode!(%{"type" => "result", "result" => inner})

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

  # Собрать ВСЕ посты прогона (review к /pulls/.../reviews + summary к /issues/.../comments).
  defp gather_posts, do: collect([])

  defp collect(acc) do
    receive do
      {:posted, url, body} ->
        collect([%{url: url, json: body |> IO.iodata_to_binary() |> Jason.decode!()} | acc])
    after
      0 -> acc
    end
  end

  defp find_post(posts, frag), do: Enum.find(posts, &String.contains?(&1.url, frag))

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
      github_output: out_path,
      rerun: false
    }

    %{cfg: cfg, out_path: out_path, client: capturing_client()}
  end

  test "end-to-end: инлайн-коммент (на строке в хунке) + обзор с причёсанным текстом, advisory → exit 0",
       %{cfg: cfg, out_path: out_path, client: client} do
    assert CLI.run(client, cfg) == 0

    posts = gather_posts()

    # Инлайн-ревью: один коммент на строку 10 (claude@10 и codex@11 в одном кластере, line=10).
    review = find_post(posts, "/pulls/")
    assert [comment] = review.json["comments"]
    assert comment["path"] == "lib/a.ex"
    assert comment["line"] == 10
    assert comment["side"] == "RIGHT"

    # тело инлайна: причёсанный заголовок, found-by, однокликовый suggestion, промпт
    assert comment["body"] =~ "причёсано P0"
    assert comment["body"] =~ "found by: claude, codex"
    assert comment["body"] =~ "```suggestion\nx = 1\n```"
    assert comment["body"] =~ "Prompt for AI agent"

    # Обзор-коммент: индекс с причёсанным текстом, панель 2/3, упавший агент, консенсус.
    summary = find_post(posts, "/issues/").json["body"]
    assert summary =~ "причёсано P0"
    assert summary =~ "panel 2/3"
    assert summary =~ "Did not complete: deepseek"
    assert summary =~ "🟡 2/3"

    # Walkthrough-секция (LLM-обзор) с TL;DR и когортой — второй best-effort вызов claude
    assert summary =~ "📝 Walkthrough"
    assert summary =~ "PR adds a guard."
    assert summary =~ "**Demo** — planted issues"

    # GITHUB_OUTPUT
    output = File.read!(out_path)
    assert output =~ "clusters=1"
    assert output =~ "blocking=false"
    assert output =~ "summary_url=HTML_URL"
  end

  test "fail_on=p0 + P0-кластер → exit 1 и статус «blocks merge»",
       %{cfg: cfg, client: client} do
    assert CLI.run(client, %{cfg | fail_on: "p0"}) == 1

    summary = find_post(gather_posts(), "/issues/").json["body"]
    assert summary =~ "⛔ blocks merge"
  end

  test "нет diff_path → нет инлайнов (находки в «outside diff»), постится только обзор",
       %{cfg: cfg, client: client} do
    assert CLI.run(client, %{cfg | diff_path: nil}) == 0

    posts = gather_posts()

    # ни одной строки в диффе → review-POST не уходит, только обзор
    assert find_post(posts, "/pulls/") == nil
    summary = find_post(posts, "/issues/").json["body"]
    assert summary =~ "Comments outside the diff"
    assert summary =~ "lib/a.ex:10"
  end

  test "пустые артефакты → «No issues found», exit 0, только обзор (review-POST не уходит)",
       %{cfg: cfg, client: client} do
    empty = Path.join(Path.dirname(cfg.reviews_dir), "empty_reviews")
    File.mkdir_p!(empty)

    assert CLI.run(client, %{cfg | reviews_dir: empty}) == 0

    posts = gather_posts()
    assert find_post(posts, "/pulls/") == nil
    assert find_post(posts, "/issues/").json["body"] =~ "No issues found"
  end
end
