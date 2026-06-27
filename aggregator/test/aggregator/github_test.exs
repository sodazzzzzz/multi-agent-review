defmodule Aggregator.GithubTest do
  use ExUnit.Case, async: true

  alias Aggregator.Github

  # Клиент с подменённым адаптером — никакой сети.
  defp client(adapter, extra \\ []) do
    Github.new(
      owner: "o",
      repo: "r",
      pr: 7,
      token: "secret",
      req_options: [adapter: adapter] ++ extra
    )
  end

  # Адаптер: пересылает запрос тест-процессу и отвечает заданным статусом/телом.
  defp stub(status, body) do
    test = self()

    fn request ->
      send(test, {:req, request})
      {request, Req.Response.new(status: status, body: body)}
    end
  end

  defp decode(body), do: body |> IO.iodata_to_binary() |> Jason.decode!()

  describe "review_payload/1 (чистая)" do
    test "оборачивает комменты в COMMENT-review с side RIGHT" do
      payload = Github.review_payload([%{path: "lib/a.ex", line: 10, body: "тело"}])
      assert payload.event == "COMMENT"
      assert [%{path: "lib/a.ex", line: 10, side: "RIGHT", body: "тело"}] = payload.comments
    end

    test "пустой список → пустые comments" do
      assert Github.review_payload([]) == %{event: "COMMENT", comments: []}
    end
  end

  describe "post_review/2" do
    test "POST на pulls/{n}/reviews с корректным payload и авторизацией" do
      c = client(stub(200, %{"id" => 1}))

      assert {:ok, %{"id" => 1}} =
               Github.post_review(c, [%{path: "lib/a.ex", line: 10, body: "x"}])

      assert_received {:req, req}
      assert req.method == :post
      assert to_string(req.url) == "https://api.github.com/repos/o/r/pulls/7/reviews"
      assert req.headers["authorization"] == ["Bearer secret"]

      payload = decode(req.body)
      assert payload["event"] == "COMMENT"
      assert [%{"path" => "lib/a.ex", "line" => 10, "side" => "RIGHT"}] = payload["comments"]
    end

    test "пустой список комментов → {:ok, :no_comments}, запрос не уходит" do
      c = client(stub(200, %{}))
      assert Github.post_review(c, []) == {:ok, :no_comments}
      refute_received {:req, _}
    end

    test "422 (строка вне диффа) → {:error, {:http, 422, body}}" do
      c = client(stub(422, %{"message" => "line must be part of the diff"}))

      assert {:error, {:http, 422, %{"message" => _}}} =
               Github.post_review(c, [%{path: "lib/a.ex", line: 9, body: "x"}])
    end
  end

  describe "post_summary/2" do
    test "POST на issues/{n}/comments, возвращает html_url" do
      url = "https://github.com/o/r/pull/7#issuecomment-1"
      c = client(stub(201, %{"html_url" => url}))

      assert {:ok, ^url} = Github.post_summary(c, "сводка")

      assert_received {:req, req}
      assert to_string(req.url) == "https://api.github.com/repos/o/r/issues/7/comments"
      assert decode(req.body) == %{"body" => "сводка"}
    end

    test "сетевой сбой → {:error, exception}" do
      adapter = fn request -> {request, %RuntimeError{message: "boom"}} end
      c = client(adapter)
      assert {:error, %RuntimeError{message: "boom"}} = Github.post_summary(c, "x")
    end

    test "2xx с не-map телом не роняет извлечение (html_url → nil)" do
      c = client(stub(200, "<html>ok</html>"))
      assert {:ok, nil} = Github.post_summary(c, "x")
    end
  end

  describe "идемпотентность" do
    test "POST не ретраится: адаптер вызывается один раз даже на 500" do
      test = self()

      adapter = fn request ->
        send(test, :called)
        {request, Req.Response.new(status: 500, body: %{"message" => "boom"})}
      end

      c = client(adapter)
      assert {:error, {:http, 500, _}} = Github.post_summary(c, "x")
      assert_received :called

      # ретрая нет → второго вызова быть не должно (иначе дубль коммента в PR)
      refute_received :called
    end
  end

  test "new/1 требует обязательные ключи" do
    assert_raise KeyError, fn -> Github.new(owner: "o", repo: "r", pr: 7) end
  end
end
