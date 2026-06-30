# Подключение репозиториев к multi-agent-review (центральный GitHub App)

Бот живёт целиком в **этом** репо: тут лежат все секреты (Claude/DeepSeek/Codex + приватный
ключ App'а), тут же по расписанию выполняется пайплайн. Он **снаружи** ревьюит открытые PR в
сторонних репозиториях из списка `REPO_ALLOWLIST` и постит обзор от лица бота (`multi-agent-
review[bot]`) плюс нативный Check Run. **В целевые репо ничего не кладётся** — ни файлы, ни
секреты. Хостинг-сервер не нужен: токен App'а выпускается прямо в GitHub Actions.

> Латентность: опрос раз в ~15 минут (cron) + кнопка ручного запуска. Мгновенная реакция
> (webhooks) — возможный апгрейд позже, без переделки пайплайна.

---

## Шаг 1. Зарегистрировать GitHub App

GitHub → Settings → Developer settings → **GitHub Apps → New GitHub App**.

- **Name:** `multi-agent-review` (имя бота в комментах; переименуемо позже — App ID и ключ не
  меняются).
- **Homepage URL:** URL репо (любой валидный).
- **Webhook → снять галку «Active»** (cron-модель webhook не использует).
- **Repository permissions** (минимум):
  | Permission | Доступ | Зачем |
  |---|---|---|
  | **Pull requests** | **Read & write** | список открытых PR, чтение метаданных, постинг обзора и инлайнов |
  | **Contents** | **Read-only** | чтение диффа (и clone-fallback для огромных PR) |
  | **Checks** | **Read & write** | создать/закрыть Check Run; читать существующие для дедупа |
  | **Metadata** | **Read-only** | базовый (выставляется сам) |

  Всё остальное — **No access**.
- **Subscribe to events:** ничего.
- **Where can this App be installed: «Any account»** (среди целей есть чужие репо — их владелец
  должен мочь поставить App). Ограничение «только нужные репо» обеспечивает `REPO_ALLOWLIST`
  (Шаг 5), а не настройка установки.
- Создать App.

## Шаг 2. App ID и приватный ключ

- Скопировать числовой **App ID**.
- **Generate a private key** → скачается `.pem`. Это креденшел — пойдёт в секрет (Шаг 4).

## Шаг 3. Установить App на целевые репо

App page → **Install App** → выбрать аккаунт → **Only select repositories** → выбрать репо.

- **Свои репо** — ставишь сам.
- **Чужие репо** — App ставит **админ того репо** (одна кнопка по install-ссылке; никаких
  секретов туда класть не надо — в этом плюс перед старой моделью).

## Шаг 4. Секреты в ЭТОМ репо

Settings → Secrets and variables → Actions → **Secrets**:

| Секрет | Значение |
|---|---|
| `APP_ID` | App ID из Шага 2 |
| `APP_PRIVATE_KEY` | полное содержимое `.pem` (включая строки BEGIN/END) |
| `CLAUDE_CODE_OAUTH_TOKEN` | OAuth-токен Claude |
| `DEEPSEEK_API_KEY` | ключ DeepSeek (или OpenAI-совместимого API) |
| `CODEX_AUTH_JSON` | `auth.json` ChatGPT-плана (только если включаешь Codex) |
| `CODEX_SECRETS_PAT` | PAT с `secrets: write` на ЭТОТ репо — для persist ротированного Codex-токена |

## Шаг 5. Переменные в ЭТОМ репо

Settings → Secrets and variables → Actions → **Variables**:

| Переменная | Значение | Назначение |
|---|---|---|
| `ENABLE_APP_REVIEW` | `true` | Главный рубильник центрального бота. Без него `app-review.yml` спит. |
| `REPO_ALLOWLIST` | `owner/repo, owner2/repo2` | **Какие репо ревьюим** (через запятую). Жёсткий фильтр. Пусто → ничего. |
| `ENABLE_CODEX` | `true` / не ставить | 3-й агент (Codex). Выкл → панель 2/3 (Claude+DeepSeek). |
| `FAIL_ON` | `none`/`p0`/`consensus-p0` | Строгость Check Run (`consensus-p0` → крестик при P0 от ≥2 моделей). |
| опц. | `CLAUDE_MODEL`, `DEEPSEEK_MODEL`, `DEEPSEEK_BASE_URL`, `CODEX_MODEL` | модели/эндпоинты |

> `ENABLE_REVIEW` (без `_APP_`) — это отдельный рубильник **само-ревью этого репо** (событийный
> `review.yml`), к центральному боту отношения не имеет.

## Шаг 6. Доступ к образу

`aggregate` тянет `ghcr.io/sodazzzzzz/multi-agent-review` в НАШЕМ прогоне (тот же владелец) —
доступ уже есть, грант целевым репо не нужен. Если пакет приватный и runner не тянет — сделать
пакет public (в образе только скомпилированный аггрегатор, секретов нет).

---

## Как это работает

`app-review.yml` (этот репо):

1. **cron каждые ~15 мин** (или кнопка **Actions → app-review → Run workflow**, опц. с конкретным
   `repo`/`pr`).
2. **discover** — выпускает токен App'а, обходит репо из `REPO_ALLOWLIST`, берёт открытые PR,
   пропускает уже отревьюенные (по нашему Check Run на head-коммите), заводит Check Run
   `in_progress`.
3. **review_stateless** — Claude + DeepSeek по каждому PR (параллельно).
4. **review_codex** — Codex по всем PR по очереди (один общий одноразовый токен; только при
   `ENABLE_CODEX=true`).
5. **aggregate** — сводит находки, постит обзор + инлайны в целевой PR от лица бота, закрывает
   Check Run (`success`/`neutral`/`failure`).

**Дедуп:** один прогон на каждый head-коммит. Новый пуш в PR → новый head → новое ревью.

## Добавить / убрать репо

- **Добавить:** Install App на репо (Шаг 3) + внести `owner/repo` в `REPO_ALLOWLIST`.
- **Убрать:** вынуть из `REPO_ALLOWLIST` (и при желании Uninstall).

## Codex при нескольких репо

Codex использует **один общий одноразовый refresh-токен**. Поэтому codex-шаг по всем PR идёт
**последовательно** (один job, restore/persist по разу за прогон) — параллельно нельзя, иначе
`refresh token already used`. Claude/DeepSeek при этом работают параллельно. Если Codex не нужен
— не ставь `ENABLE_CODEX` (панель 2/3). ⚠ Использование ChatGPT-плана в CI — на твой риск по ToS
OpenAI.

## Траблшутинг

- **Бот молчит** — не выставлен `ENABLE_APP_REVIEW=true`, или репо нет в `REPO_ALLOWLIST`, или App
  не установлен на него (в логе discover — `::warning:: App не установлен на …`).
- **discover падает на JWT** — кривой `APP_PRIVATE_KEY` (нужен весь `.pem` с переводами строк) или
  `APP_ID`.
- **Нет Check Run / коммента** — у App'а не выставлены права Checks / Pull requests (Шаг 1).
- **`codex` падает `refresh token already used`** — параллельный прогон Codex; убедись, что
  `app-review` и `codex-warmup` в одной concurrency-группе `codex-auth` (так и есть по умолчанию).
- **Большой PR** — дифф тянется clone-fallback'ом автоматически; качество агентов на гигантских
  диффах может падать, но пайплайн не падает (упавший агент помечается, остальные постятся).
