# multi-agent-review

Мульти-агентный ревью-бот для GitHub Pull Request. На каждый PR несколько ИИ-агентов
(**Claude**, **Codex/OpenAI**, **DeepSeek**) независимо и параллельно ревьюят diff;
детерминированный **Elixir-аггрегатор** кластеризует их находки, считает консенсус и
severity (заморожено кодом), Claude причёсывает только прозу, и итог постится **одним**
summary-комментарием + PR-review с однокликовыми suggestion-правками. Архитектура —
классический **fan-out / fan-in (map-reduce)** поверх GitHub Actions.

По умолчанию бот **только советует** (advisory) и merge не блокирует; блокировка —
opt-in через `fail-on`.

## Статус

- [x] **Аггрегатор целиком** (`aggregator/`, 128 тестов, `mix check` зелёный):
      кластеризация по окну строк, консенсус по числу разных агентов, severity = max,
      JSON-Schema валидация (`Schema`), gating (`Gate`), pre-flight по диффу (`Diff`),
      постинг в GitHub (`Github`, Req), причёсывание (`Polish` + `Claude`, best-effort,
      факты заморожены), отрисовка (`Render`), CLI-оркестратор (`CLI`).
- [x] **Упаковка**: Docker container action (`Dockerfile` + `action.yml`), GHCR release.
- [ ] Тонкие bash-обёртки агентов (`scripts/`) — get_diff / review_{claude,deepseek,codex}.
- [ ] Reference reusable workflow (`.github/workflows/review.yml`) с триггером `/rerun-review`.

## Архитектура

```
on: pull_request [opened]  +  issue_comment "/rerun-review"   (reusable workflow)
        ├── job: claude    (ubuntu-latest)          ──► review-claude.json   (artifact)
        ├── job: deepseek  (ubuntu-latest)          ──► review-deepseek.json (artifact)
        ├── job: codex     (self-hosted, env-gated) ──► review-codex.json    (artifact)
        └── job: aggregate (needs: все три, if: always())  ── ЭТОТ Docker action
                 ├─ schema-валидация артефактов (упавший агент → помечаем, не валим прогон)
                 ├─ детерминированный кластеринг + консенсус + severity   (заморожено)
                 ├─ Claude причёсывает прозу внутри кластеров            (факты не трогает)
                 ├─ summary-комментарий + PR-review с line-anchored suggestions
                 └─ exit 1 ТОЛЬКО если сработал `fail-on` (по умолчанию advisory)
```

«Мозг» (`aggregate`) — Elixir-release в Docker action (этот репозиторий). Оркестровка
fan-out/fan-in — reusable workflow (в работе), который адоптер подключает у себя.

## Использование (шаг `aggregate`)

Аггрегатор ожидает уже готовые артефакты агентов (`review-*.json`) и, опционально,
unified diff PR для однокликовых правок:

```yaml
- uses: sodazzzzzz/multi-agent-review@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    pr-number: ${{ github.event.pull_request.number }}
    reviews-dir: reviews        # где лежат review-*.json (рекурсивно)
    diff-path: diff.patch       # unified diff PR (для suggestion); пусто → только summary
    fail-on: none               # none | p0 | consensus-p0
```

| Input | Default | Назначение |
|---|---|---|
| `github-token` | — | токен с `pull-requests: write` |
| `pr-number` | — | номер PR |
| `reviews-dir` | `reviews` | директория с `review-*.json` |
| `diff-path` | `""` | unified diff PR (для inline-suggestion) |
| `fail-on` | `none` | `none` \| `p0` \| `consensus-p0` |
| `cluster-window` | `3` | окно строк для слияния находок |
| `polish-model` | `claude-opus-4-8` | модель причёсывания (best-effort) |
| `claude-bin` | `claude` | бинарь claude; если недоступен — текст детерминированный |

Outputs: `clusters`, `blocking`, `summary_url`.

### Контракт findings

Каждый агент отдаёт строго такой JSON (и ничего кроме):

```json
{
  "agent": "claude",
  "findings": [
    {
      "file": "lib/eden/chat.ex",
      "line": 42,
      "severity": "P0",
      "category": "bug",
      "message": "Описание проблемы в 1–3 предложениях.",
      "suggestion": "GenServer.call(pid, :state)"
    }
  ]
}
```

- `severity` ∈ `{P0, P1, P2}`. `P0` блокирует merge **только** при `fail-on: p0`/`consensus-p0`.
- `category` ∈ `{bug, security, performance, style, design, test}`.
- `line` — номер строки в новой версии файла (RIGHT side диффа) либо `null`.
- `suggestion` — готовый код на замену строки/диапазона либо `null`.

## Разработка

```bash
cd aggregator
mix deps.get
mix check    # format + warnings-as-errors + credo --strict + deps.audit + dialyzer + test
```

Чистый слой (`Finding`, `Cluster`, `Consensus`, `Schema`, `Diff`, `Gate`, `Render`,
`Polish`) тестируется без сети и процессов; эффект-слой (`Github`, `Claude`, `CLI`) —
с инъекцией фейкового Req-адаптера и фейк-бинаря, тоже без сети.
