#!/usr/bin/env bash
# Round-trip аутентификации Codex (ChatGPT-план) на эфемерных hosted-раннерах.
#
#   codex_auth.sh restore   — положить auth.json из секрета CODEX_AUTH_JSON в $CODEX_HOME
#   codex_auth.sh persist   — записать ОБНОВЛЁННЫЙ Codex'ом auth.json назад в секрет
#
# Зачем так: refresh-токен ChatGPT-плана ОДНОРАЗОВЫЙ (ротируется). `codex exec` сам рефрешит
# и переписывает auth.json во время прогона (если last_refresh старше ~8 дней или на 401);
# на эфемерном раннере обновлённый файл надо сохранить НАЗАД, иначе после первой ротации
# сломается («refresh token already used»). Источник: developers.openai.com/codex/auth/ci-cd-auth.
# persist требует PAT с правом secrets:write (env GH_TOKEN) — GITHUB_TOKEN секреты писать не может.
#
# Env: CODEX_HOME (обяз.); restore: CODEX_AUTH_JSON; persist: GITHUB_REPOSITORY + GH_TOKEN.
set -euo pipefail

cmd="${1:?usage: codex_auth.sh <restore|persist>}"
auth="${CODEX_HOME:?CODEX_HOME required}/auth.json"

# valid_auth <file> — это chatgpt-auth.json с непустым refresh-токеном?
valid_auth() {
  jq -e '.auth_mode == "chatgpt" and (.tokens.refresh_token | type == "string" and length > 0)' \
    "$1" >/dev/null 2>&1
}

case "$cmd" in
  restore)
    : "${CODEX_AUTH_JSON:?CODEX_AUTH_JSON required}"
    mkdir -p "$(dirname "$auth")"
    printf '%s' "$CODEX_AUTH_JSON" >"$auth"
    chmod 600 "$auth"
    if ! valid_auth "$auth"; then
      echo "codex_auth: CODEX_AUTH_JSON — не chatgpt-auth.json с refresh_token" >&2
      exit 1
    fi
    echo "codex_auth: auth.json восстановлен → $auth"
    ;;

  persist)
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    : "${GH_TOKEN:?GH_TOKEN (PAT с secrets:write) required}"
    if [ ! -f "$auth" ] || ! valid_auth "$auth"; then
      echo "codex_auth: валидного auth.json после прогона нет — write-back пропущен" >&2
      exit 0
    fi
    # Пишем назад ТОЛЬКО если Codex реально обновил файл (иначе лишний secret-write).
    if [ -n "${CODEX_AUTH_JSON:-}" ] \
       && [ "$(printf '%s' "$CODEX_AUTH_JSON" | sha256sum)" = "$(sha256sum <"$auth")" ]; then
      echo "codex_auth: auth.json не изменился — токен не ротировался, write-back не нужен"
      exit 0
    fi
    # С ретраями: транзиентный сбой gh/API не должен осиротить ОДНОРАЗОВЫЙ токен
    # (codex уже израсходовал его при рефреше — без write-back назад он потерян).
    for attempt in 1 2 3; do
      if gh secret set CODEX_AUTH_JSON --repo "$GITHUB_REPOSITORY" <"$auth"; then
        echo "codex_auth: обновлённый auth.json записан в секрет CODEX_AUTH_JSON"
        exit 0
      fi
      echo "codex_auth: gh secret set не удался (попытка $attempt/3) — повтор" >&2
      sleep 5
    done
    echo "codex_auth: НЕ удалось записать токен — секрет CODEX_AUTH_JSON надо перевыпустить вручную" >&2
    exit 1
    ;;

  *)
    echo "codex_auth: неизвестная команда '$cmd' (ожидается restore|persist)" >&2
    exit 2
    ;;
esac
