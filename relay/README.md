# multi-agent-review relay — подробная инструкция

Тонкое реле: превращает события GitHub App и клики по реран-ссылке в
`repository_dispatch` на репозитории бота. Логики ревью нет — только триггер Actions.
Падение реле не влияет на крон/секреты (они в GitHub Actions).

```
App webhook (pull_request: opened)   ─┐
клик по «🔄 Re-run this review»       ─┴─▶  relay  ──▶  repository_dispatch
                                                         └─▶ app-review.yml (Actions)
```

Эндпоинты: `POST /webhook`, `GET /rerun`, `GET /healthz`. Образ — distroless (~3 МБ),
слушает порт **8080**.

> **Воркфлоу-часть уже в `main` (релиз v0.3.0)** — реле дёргает `repository_dispatch`, а
> `app-review.yml` его обрабатывает. Поэтому части A–E проходятся подряд. Если секреты (A) и PAT (B)
> уже сделаны — начинай с **Части C** (деплой в Dokploy), затем D–E.

---

## Часть A. Сгенерировать два секрета

В любом терминале:

```bash
openssl rand -hex 32   # → сохрани как WEBHOOK_SECRET
openssl rand -hex 32   # → сохрани как RERUN_SECRET
```

- **`WEBHOOK_SECRET`** — общий секрет App-вебхука (реле ↔ GitHub App).
- **`RERUN_SECRET`** — ключ подписи реран-ссылок (реле ↔ аггрегатор в Actions).

Запиши оба в надёжное место — понадобятся в Dokploy (Часть C) и в GitHub (Части D–E).

---

## Часть B. Fine-grained PAT для dispatch

Реле дёргает `POST /repos/sodazzzzzz/multi-agent-review/dispatches` — для этого нужен токен
с правом писать в этот репо.

1. GitHub → аватар → **Settings** → внизу слева **Developer settings**.
2. **Personal access tokens → Fine-grained tokens** → **Generate new token**.
3. Заполни:
   - **Token name:** `mar-relay-dispatch`
   - **Expiration:** на твой вкус (напр. 1 год; потом обновить).
   - **Resource owner:** твой аккаунт (`sodazzzzzz`).
   - **Repository access:** **Only select repositories** → выбери **`multi-agent-review`**.
   - **Permissions → Repository permissions → Contents:** поставь **Read and write**
     (этого достаточно для `repository_dispatch`; Metadata: Read проставится сам).
4. **Generate token** → **скопируй** значение (`github_pat_…`). Это `GITHUB_DISPATCH_TOKEN`.
   Больше GitHub его не покажет.

---

## Часть C. Деплой реле в Dokploy

Репо **публичный**, поэтому подключать GitHub-аккаунт к Dokploy не обязательно — можно тянуть по
HTTPS-URL. Названия полей могут чуть отличаться по версии Dokploy — ориентируйся по смыслу.

### C1. Создать приложение
1. Dokploy → **Projects** → выбери проект или **Create Project** (напр. `bots`).
2. Внутри проекта → **Create Service → Application**. Имя: `mar-relay`.

### C2. Источник (Git)
1. Вкладка **Provider / Source** → тип **Git** (generic).
2. **Repository URL:** `https://github.com/sodazzzzzz/multi-agent-review.git`
3. **Branch:** `main` (реле в `main` начиная с релиза v0.3.0).
4. SSH-ключ не нужен (репо публичный).

### C3. Сборка (Dockerfile)
1. **Build Type:** **Dockerfile**.
2. **Docker File / Dockerfile Path:** `relay/Dockerfile`
3. **Build Context / Build Path:** оставь по умолчанию (корень репо, `.`).
   Dockerfile уже написан от корня (`COPY relay/…`), так что менять контекст не надо.

### C4. Переменные окружения
Вкладка **Environment** → добавь:
```
WEBHOOK_SECRET=<из Части A>
RERUN_SECRET=<из Части A>
GITHUB_DISPATCH_TOKEN=<PAT из Части B>
```
(`DISPATCH_REPO` и `PORT` не нужны — дефолты `sodazzzzzz/multi-agent-review` и `8080`.)

### C5. Домен и порт
Вкладка **Domains** → **Add Domain**:
- **Host:** напр. `mar-relay.твой-домен` (поддомен, который направлен на сервер Dokploy).
- **Container Port:** **8080**.
- **HTTPS:** включить (Let's Encrypt) — Dokploy выпустит сертификат сам.

> DNS: у поддомена должна быть A/CNAME-запись на IP сервера Dokploy — иначе сертификат не выпустится.

### C6. Задеплоить и проверить
1. Нажми **Deploy**. В логах сборки увидишь `Successfully built …`, затем старт:
   `multi-agent-review relay на :8080 → dispatch sodazzzzzz/multi-agent-review`.
2. Проверка живости:
   ```bash
   curl https://mar-relay.твой-домен/healthz     # → ok
   ```
   Если `ok` — реле поднято. 🎉

**На этом Часть «сейчас» закончена.** Дай знать `/healthz: ok` — я доведу воркфлоу-часть, и продолжим с D–E.

---

## Часть D. Вебхук в GitHub App

GitHub → Settings → Developer settings → **GitHub Apps** → `multi-agent-review` → **Edit**:
1. **Webhook → поставить галку Active** (мы её снимали для крон-модели).
2. **Webhook URL:** `https://mar-relay.твой-домен/webhook`
3. **Webhook secret:** значение `WEBHOOK_SECRET` (из Части A).
4. **Content type:** `application/json` (обычно по умолчанию).
5. Слева **Permissions & events → Subscribe to events** → отметь **Pull requests**.
   (Права Pull requests / Contents / Checks уже стоят с этапа 4.)
6. **Save changes.**

GitHub сразу пошлёт `ping` — в логах реле будет строка и ответ `204`, это норма.

---

## Часть E. Секрет и переменная в репо бота

Репо `multi-agent-review` → **Settings → Secrets and variables → Actions**:
- **Secrets → New:** `RERUN_SECRET` = **то же** значение, что в реле (аггрегатор подписывает им реран-ссылки — подписи должны совпасть).
- **Variables → New:** `RELAY_URL` = `https://mar-relay.твой-домен` (база для реран-ссылок в обзоре).

---

## Проверка end-to-end *(когда всё включено)*
1. Открой новый PR в подключённом репо (напр. eden) → в течение секунд появится ревью (webhook, а не 15-мин крон).
2. В обзоре — ссылка **🔄 Re-run this review**. Клик → редирект обратно в PR → через минуту-две новый обзор.

## Траблшутинг
- **`/healthz` не отвечает** — приложение не стартовало: проверь логи Dokploy. Частое: не заданы `WEBHOOK_SECRET`/`RERUN_SECRET`/`GITHUB_DISPATCH_TOKEN` (реле падает на старте с сообщением об этом).
- **Сертификат не выпускается** — DNS поддомена не указывает на сервер Dokploy, либо порт 80/443 занят/закрыт.
- **Сборка падает `go.mod not found`** — Build Context не корень репо. Верни контекст в `.` (Dockerfile тянет `relay/…` сам).
- **Webhook в GitHub App показывает красный/`401`** (вкладка Advanced) — не совпадает `WEBHOOK_SECRET` в реле и в App.
- **Реран-ссылка → `bad signature`** — `RERUN_SECRET` в реле и в секрете репо различаются.
- **Dispatch не запускает воркфлоу** — PAT (`GITHUB_DISPATCH_TOKEN`) без `Contents: write`, либо истёк.

## Локально
```bash
cd relay
WEBHOOK_SECRET=x RERUN_SECRET=y GITHUB_DISPATCH_TOKEN=z go run .
curl localhost:8080/healthz   # ok
```
