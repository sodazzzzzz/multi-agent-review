#!/usr/bin/env bash
# Построить unified diff пулл-реквеста: изменения head относительно базы (three-dot,
# т.е. только то, что добавил PR от точки ветвления). Печатает число строк.
#
#   get_diff.sh <base_sha> <head_sha> <out_patch> [<out_files>]
#
# Требует, чтобы оба коммита были в локальном репозитории (workflow делает
# fetch-depth: 0 на базу + fetch head_sha). Скрипт берётся из base-ref (доверенный),
# а diff — это ДАННЫЕ PR (их не исполняем).
set -euo pipefail

base="${1:?usage: get_diff.sh <base_sha> <head_sha> <out_patch> [<out_files>]}"
head="${2:?head sha required}"
out="${3:?out patch path required}"
files="${4:-}"

git diff "${base}...${head}" >"$out"

if [ -n "$files" ]; then
  git diff --name-only "${base}...${head}" >"$files"
fi

echo "get_diff: $(wc -l <"$out") строк diff → $out"
