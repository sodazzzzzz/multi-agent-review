# multi-agent-review relay

Тонкое реле: превращает события GitHub App и клики по реран-ссылке в
`repository_dispatch` на репозитории бота. Логики ревью нет — только триггер Actions.
Падение реле не влияет на крон/секреты (они в Actions).

```
App webhook (pull_request: opened)   ─┐
клик по «🔄 Re-run this review»       ─┴─▶  relay  ──▶  repository_dispatch
                                                         └─▶ app-review.yml (Actions)
```

Эндпоинты: `POST /webhook`, `GET /rerun`, `GET /healthz`.

## Переменные окружения

| Env | Обязателен | Значение |
|---|---|---|
| `WEBHOOK_SECRET` | да | Секрет App-вебхука. Тот же, что впишешь в настройках GitHub App. |
| `RERUN_SECRET` | да | Ключ подписи реран-ссылок. Тот же положим в секрет репо `RERUN_SECRET` (аггрегатор им подписывает ссылки). |
| `GITHUB_DISPATCH_TOKEN` | да | Fine-grained PAT с доступом к репо бота (см. ниже). |
| `DISPATCH_REPO` | нет | Репо бота. По умолчанию `sodazzzzzz/multi-agent-review`. |
| `PORT` | нет | Порт (по умолчанию `8080`). |

Сгенерировать секреты:
```
openssl rand -hex 32   # для WEBHOOK_SECRET
openssl rand -hex 32   # для RERUN_SECRET
```

## Шаг 1. Fine-grained PAT для dispatch

GitHub → Settings → Developer settings → **Fine-grained tokens → Generate new token**:
- **Resource owner:** твой аккаунт; **Repository access → Only select repositories → `multi-agent-review`**.
- **Permissions → Repository → Contents: Read and write** (нужно для `repository_dispatch`).
- Скопируй токен → это `GITHUB_DISPATCH_TOKEN`.

## Шаг 2. Деплой в Dokploy

Dokploy сам даёт HTTPS (Traefik + Let's Encrypt) и домен — отдельный reverse-proxy не нужен.

1. **Create → Application.** Source — GitHub, репо `multi-agent-review`, ветка `main`.
2. **Build Type: Dockerfile.** **Build Path / Context:** `relay` (Dockerfile внутри неё).
3. **Environment** — впиши `WEBHOOK_SECRET`, `RERUN_SECRET`, `GITHUB_DISPATCH_TOKEN` (и при желании `DISPATCH_REPO`).
4. **Domains** — добавь домен, напр. `mar-relay.твой-домен`, контейнерный порт **8080**. Dokploy выпустит сертификат.
5. **Deploy.** Проверка: `https://mar-relay.твой-домен/healthz` → `ok`.

## Шаг 3. Вебхук в GitHub App

GitHub App (`multi-agent-review`) → **Edit**:
1. **Webhook → поставить Active** (мы его выключали для крон-модели).
2. **Webhook URL:** `https://mar-relay.твой-домен/webhook`
3. **Secret:** значение `WEBHOOK_SECRET`.
4. **Permissions & events → Subscribe to events → Pull requests** (Contents/Checks R&W уже есть).
5. Save.

GitHub пришлёт `ping` — в логах реле будет `204`, это норма.

## Шаг 4. Секрет репо для ссылок

В репо `multi-agent-review` → Secrets and variables → Actions:
- секрет **`RERUN_SECRET`** = то же значение, что в реле (аггрегатор подписывает им реран-ссылки);
- переменная **`RELAY_URL`** = `https://mar-relay.твой-домен` (база для реран-ссылок).

> Шаги 3–4 заработают после того, как в репо приедет воркфлоу-часть (`repository_dispatch` +
> рендер реран-ссылки). До этого реле можно деплоить и проверять `/healthz`.

## Локально

```
go run .            # нужны env-переменные
go build -o relay . # статический бинарь
```
