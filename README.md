# multi-agent-review

Мульти-агентный ревью-бот для GitHub Pull Request. На каждый PR три ИИ-агента
(**Claude**, **Codex/OpenAI**, **DeepSeek**) независимо и параллельно ревьюят diff;
их замечания сводятся в **один** комментарий с однокликовыми suggestion-правками
и метками консенсуса. Архитектура — классический **fan-out / fan-in (map-reduce)**
поверх GitHub Actions.

## Статус

🚧 В разработке. Готово:

- [x] Чистое детерминированное ядро аггрегатора (`aggregator/`): кластеризация
      findings по окну строк, консенсус по числу разных агентов, severity = max,
      с покрытием ExUnit.
- [ ] Валидация findings по JSON Schema (`Aggregator.Schema`)
- [ ] Claude-причёсывание прозы (findings заморожены) (`Aggregator.Polish`)
- [ ] Постинг в GitHub Pulls API + summary-комментарий (`Aggregator.GitHub`)
- [ ] CLI-entrypoint и Docker action (`action.yml` + `Dockerfile`)
- [ ] Тонкие bash-обёртки агентов (`scripts/`)
- [ ] Reference reusable workflow (`.github/workflows/review.yml`)

## Архитектура

```
on: pull_request [opened, synchronize]
        ├── job: claude    (ubuntu-latest)   ──► review-claude.json   (artifact)
        ├── job: codex     (self-hosted)     ──► review-codex.json     (artifact)
        ├── job: deepseek  (ubuntu-latest)   ──► review-deepseek.json  (artifact)
        └── job: aggregate (needs: все три, if: always())
                 ├─ детерминированный кластеринг + консенсус + severity  (Elixir, заморожено)
                 ├─ Claude причёсывает прозу внутри кластеров            (факты не трогает)
                 ├─ summary-комментарий + PR-review с line-anchored suggestions
                 └─ exit 1, если есть P0  (блокирует merge)
```

«Мозг» (`aggregate`) — Elixir-release в Docker action, публикуется в Marketplace.
Оркестровка fan-out/fan-in — reference reusable workflow, который адоптер
подключает у себя.

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

- `severity` ∈ `{P0, P1, P2}` — `P0` блокирует merge.
- `category` ∈ `{bug, security, performance, style, design, test}`.
- `line` — номер строки в новой версии файла (RIGHT side диффа) либо `null`.
- `suggestion` — готовый код на замену строки/диапазона либо `null`.

## Разработка

```bash
cd aggregator
mix deps.get
mix test
mix format --check-formatted
```

Чистый слой (`Finding`, `Cluster`, `Consensus`) тестируется без сети и процессов.
