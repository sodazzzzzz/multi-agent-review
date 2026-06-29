# syntax=docker/dockerfile:1

# --- builder: компилируем prod-release аггрегатора ---
FROM hexpm/elixir:1.20.2-erlang-28.5.0.2-alpine-3.21.7 AS builder

RUN apk add --no-cache build-base git

ENV MIX_ENV=prod
# Запас по таймауту/ретраям к hex.pm — реестр иногда отвечает медленно.
ENV HEX_HTTP_TIMEOUT=120
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Зависимости — отдельным слоем, чтобы кэшировались между сборками.
COPY aggregator/mix.exs aggregator/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

# Исходники + схема (priv) → компиляция → self-contained release.
COPY aggregator/lib ./lib
COPY aggregator/priv ./priv
RUN mix compile && mix release

# --- runtime: минимальный alpine + BEAM-зависимости ---
FROM alpine:3.21.7 AS runtime

# ca-certificates обязателен: HTTPS к api.github.com через Req/Finch/Mint проверяет
# сертификат по OS-trust-store (Mint 1.9 verify_peer + public_key:cacerts_get), а
# castore у нас не подключён. Без него TLS-верификация ненадёжна.
RUN apk add --no-cache libstdc++ openssl ncurses libgcc ca-certificates

# claude CLI — для Polish (best-effort причёсывание прозы внутри контейнера). Ставится
# через node+npm (проверено на alpine/musl: claude 2.1.195 поднимается, читает
# CLAUDE_CODE_OAUTH_TOKEN из env, отдаёт {"type":"result","result":...}). При отсутствии
# токена/любом сбое Aggregator.Claude молча деградирует к детерминированному тексту —
# Polish никогда не роняет прогон.
# Версия запинена ради воспроизводимости сборки (образ билдится на каждый прогон, пока не
# перешли на пред-собранный GHCR-образ). Бамп — поднять номер здесь.
RUN apk add --no-cache nodejs npm \
  && npm install -g @anthropic-ai/claude-code@2.1.195 \
  && npm cache clean --force

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/aggregator ./

# Без USER: GitHub монтирует GITHUB_WORKSPACE от root, экшену нужен доступ к артефактам.
# eval-режим: приложения поднимает сам main/0 (Application.ensure_all_started).
ENTRYPOINT ["/app/bin/aggregator", "eval", "Aggregator.CLI.main()"]
