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

RUN apk add --no-cache libstdc++ openssl ncurses libgcc

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/aggregator ./

# Без USER: GitHub монтирует GITHUB_WORKSPACE от root, экшену нужен доступ к артефактам.
# eval-режим: приложения поднимает сам main/0 (Application.ensure_all_started).
ENTRYPOINT ["/app/bin/aggregator", "eval", "Aggregator.CLI.main()"]
