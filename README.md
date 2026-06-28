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
- [x] **Codex как третий агент** (`scripts/codex_auth.sh` + `scripts/review_codex.sh` +
      codex-джоб + `codex-warmup.yml`): ChatGPT-план, round-trip auth (restore→`codex exec`→
      persist обновлённого `auth.json`) + warmup-крон. Opt-in по переменной `ENABLE_CODEX`.

## Архитектура

```
on: pull_request [opened]  +  issue_comment "/rerun-review"   (reusable workflow)
        ├── job: claude    (ubuntu-latest)          ──► review-claude.json   (artifact)
        ├── job: deepseek  (ubuntu-latest)          ──► review-deepseek.json (artifact)
        ├── job: codex     (hosted, round-trip auth, opt-in) ──► review-codex.json (artifact)
        └── job: aggregate (needs: все три, if: always())  ── ЭТОТ Docker action
                 ├─ schema-валидация артефактов (упавший агент → помечаем, не валим прогон)
                 ├─ детерминированный кластеринг + консенсус + severity   (заморожено)
                 ├─ Claude причёсывает прозу внутри кластеров            (факты не трогает)
                 ├─ summary-комментарий + PR-review с line-anchored suggestions
                 └─ exit 1 ТОЛЬКО если сработал `fail-on` (по умолчанию advisory)
```

«Мозг» (`aggregate`) — Elixir-release в Docker action (этот репозиторий). Оркестровка
fan-out/fan-in — workflow `.github/workflows/review.yml` (Claude + DeepSeek + опционально Codex).

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

### Codex (опциональный 3-й агент, ChatGPT-план)

Codex подключается **подпиской** (ChatGPT Plus/Pro), а не отдельным API-биллингом. Сложность
в том, что у ChatGPT-плана **refresh-токен одноразовый (ротируется)**: `codex exec` сам
рефрешит и переписывает `auth.json` во время прогона, а на эфемерном раннере обновлённый файл
надо **сохранить назад** — иначе после первой ротации Codex отвалится. Поэтому round-trip:
restore из секрета → `codex exec` → persist обновлённого `auth.json` в тот же секрет.

1. **Сгенерировать `auth.json`** на доверенной машине: установить Codex (`npm install -g
   @openai/codex`), выполнить `codex login` (вход через ChatGPT), затем взять содержимое
   `~/.codex/auth.json` (должно быть `"auth_mode": "chatgpt"` с `tokens.refresh_token`).
2. **Variables**: `ENABLE_CODEX` = `true`; опц. `CODEX_MODEL` (если не задан — берётся модель
   аккаунта по умолчанию; id моделей Codex меняются, поэтому жёстко не зашит).
3. **Secrets**:
   - `CODEX_AUTH_JSON` — содержимое `auth.json` целиком.
   - `CODEX_SECRETS_PAT` — fine-grained PAT с правом **Secrets: write** на этот репо (нужен,
     чтобы записать обновлённый токен назад: `GITHUB_TOKEN` секреты писать не может).
4. **Warmup**: `.github/workflows/codex-warmup.yml` дважды в неделю гоняет тривиальный
   `codex exec`, чтобы refresh-токен не протух между ревью (неактивная сессия живёт ~8 дней).

Без `ENABLE_CODEX=true` codex-джоб дремлет, панель остаётся 2-агентной (без вечного «codex не
отработал»). ⚠ Использование ChatGPT-плана в CI — на твой риск по ToS OpenAI; альтернатива —
указать в `DEEPSEEK_*`/обёртке OpenAI-совместимый API-ключ. ⚠ Параллельные рефреши одного
токена сериализованы (`concurrency: codex-auth`, без отмены); если Codex всё же отвалится
(`refresh token already used`) — перевыпусти `CODEX_AUTH_JSON` шагами 1–3.

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
