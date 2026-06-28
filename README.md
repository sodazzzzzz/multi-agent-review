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
- [x] **Pipeline Claude + DeepSeek** (`scripts/` + `.github/workflows/review.yml`):
      get_diff + обёртки-ревьюеры, триггеры `pull_request[opened]` и `/rerun-review`.
- [ ] Codex как третий агент (ChatGPT-план, round-trip auth + weekly warmup).

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
fan-out/fan-in — workflow `.github/workflows/review.yml` (пока Claude + DeepSeek; Codex — следующим).

## Включение пайплайна (в этом репо)

Workflow дремлет, пока не выставлена переменная-переключатель — чтобы не шуметь, пока
секреты не готовы. Чтобы включить ревью:

1. **Variables** (Settings → Secrets and variables → Actions → Variables):
   - `ENABLE_REVIEW` = `true` (главный переключатель).
   - опц.: `CLAUDE_MODEL`, `DEEPSEEK_MODEL`, `DEEPSEEK_BASE_URL`, `FAIL_ON`.
2. **Secrets**:
   - `CLAUDE_CODE_OAUTH_TOKEN` — токен подписки Claude (статичный, `claude setup-token`).
   - `DEEPSEEK_API_KEY` — ключ DeepSeek (или OpenAI-совместимого прокси).
   - `GITHUB_TOKEN` — автоматический, ничего настраивать не нужно.

Дальше: **открытие PR** → авто-ревью; **коммент `/rerun-review`** (от OWNER/MEMBER/COLLABORATOR)
→ повторный прогон новым комментом. Упавший агент не валит прогон — помечается в сводке.
Скрипты-обёртки исполняются из base-ветки (PR-дифф — это данные), секреты доступны только
на same-repo PR (форки ревью не получают — это by design).

## Использование как отдельный action (шаг `aggregate`)

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
