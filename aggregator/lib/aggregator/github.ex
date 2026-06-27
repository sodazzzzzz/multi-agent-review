defmodule Aggregator.Github do
  @moduledoc """
  Постинг результатов ревью в GitHub REST API (через `Req`).

  Два эффекта, оба — НОВЫЕ объекты на каждый прогон (никакого edit-in-place,
  перезапуск редкий и явный по `/rerun-review`):

    * `post_summary/2` — issue-комментарий со сводкой (`Aggregator.Render` → `:summary`).
    * `post_review/2` — pull-request review с массивом `comments[]` (однокликовые
      suggestion'ы). `event: "COMMENT"` — продукт advisory, поэтому не `REQUEST_CHANGES`.

  Сетевой слой намеренно тонкий: сборка payload — чистая (`review_payload/1`,
  тестируется без сети), а HTTP идёт через `Req` с возможностью подменить адаптер
  в тестах (опция `:req_options`). Комментарии-suggestion'ы привязываются к
  `side: "RIGHT"` — это новая версия файла; вызывающий обязан передавать только
  строки, реально попадающие в дифф (см. `Aggregator.Render`/`Aggregator.Diff`),
  иначе GitHub вернёт 422.
  """

  @api_version "2022-11-28"
  @default_base "https://api.github.com"

  @type t :: %__MODULE__{
          owner: String.t(),
          repo: String.t(),
          pr: pos_integer(),
          req: Req.Request.t()
        }

  @enforce_keys [:owner, :repo, :pr, :req]
  defstruct [:owner, :repo, :pr, :req]

  @type comment :: %{path: String.t(), line: pos_integer(), body: String.t()}

  @doc """
  Собрать клиент: координаты PR + преднастроенный `Req`-запрос.

  Обязательны `:owner`, `:repo`, `:pr`, `:token`. `:base_url` переопределяется (по
  умолчанию `https://api.github.com`). `:req_options` подмешиваются в `Req` —
  через них тесты инжектят `:adapter`, не выходя в сеть.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    req =
      [
        base_url: Keyword.get(opts, :base_url, @default_base),
        auth: {:bearer, Keyword.fetch!(opts, :token)},
        headers: [
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", @api_version}
        ],
        # Идемпотентный POST коммента/ревью + транзиентные сетевые сбои — безопасно ретраить.
        retry: :transient,
        max_retries: 3
      ]
      |> Req.new()
      |> Req.merge(Keyword.get(opts, :req_options, []))

    %__MODULE__{
      owner: Keyword.fetch!(opts, :owner),
      repo: Keyword.fetch!(opts, :repo),
      pr: Keyword.fetch!(opts, :pr),
      req: req
    }
  end

  @doc """
  Запостить сводный комментарий. Возвращает `{:ok, html_url}` либо `{:error, reason}`.
  """
  @spec post_summary(t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def post_summary(%__MODULE__{} = c, body) when is_binary(body) do
    c.req
    |> Req.post(url: issues_path(c), json: %{body: body})
    |> handle(fn resp_body -> resp_body["html_url"] end)
  end

  @doc """
  Запостить PR-review с однокликовыми suggestion'ами.

  Пустой список комментариев → ничего не шлём (`{:ok, :no_comments}`): пустой
  review GitHub отверг бы. Возвращает `{:ok, body}` либо `{:error, reason}`;
  частый случай ошибки — `422` (строка вне диффа), вызывающий решает, продолжать ли.
  """
  @spec post_review(t(), [comment()]) :: {:ok, term()} | {:error, term()}
  def post_review(%__MODULE__{}, []), do: {:ok, :no_comments}

  def post_review(%__MODULE__{} = c, comments) when is_list(comments) do
    c.req
    |> Req.post(url: reviews_path(c), json: review_payload(comments))
    |> handle(& &1)
  end

  @doc """
  Чистая сборка payload PR-review из списка комментариев `Aggregator.Render`.

  Выделено для юнит-тестов без сети.
  """
  @spec review_payload([comment()]) :: map()
  def review_payload(comments) do
    %{
      event: "COMMENT",
      comments:
        Enum.map(comments, fn %{path: path, line: line, body: body} ->
          %{path: path, line: line, side: "RIGHT", body: body}
        end)
    }
  end

  # --- внутреннее ---

  defp issues_path(%__MODULE__{owner: o, repo: r, pr: n}),
    do: "/repos/#{o}/#{r}/issues/#{n}/comments"

  defp reviews_path(%__MODULE__{owner: o, repo: r, pr: n}),
    do: "/repos/#{o}/#{r}/pulls/#{n}/reviews"

  # 2xx → {:ok, extract(body)}; иной статус → {:error, {:http, status, body}};
  # сетевой сбой → {:error, reason}. Так CLI отличает «не приняли» от «не доехало».
  defp handle({:ok, %Req.Response{status: status, body: body}}, extract)
       when status in 200..299 do
    {:ok, extract.(body)}
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}, _extract) do
    {:error, {:http, status, body}}
  end

  defp handle({:error, reason}, _extract), do: {:error, reason}
end
