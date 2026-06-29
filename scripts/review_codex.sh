#!/usr/bin/env bash
# Ревьюер Codex (ChatGPT-план через `codex exec`), нормализует вывод в review-codex.json.
# Тонкая обёртка — общая логика в lib.sh; аутентификация отдельно в codex_auth.sh.
#
#   review_codex.sh <diff_file> <out_file>
#
# Env: CODEX_HOME (обяз., там auth.json от codex_auth.sh restore), CODEX_MODEL (опц.).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

diff_file="${1:?usage: review_codex.sh <diff_file> <out_file>}"
out="${2:?out file required}"

call_codex() {
  local msg rc
  msg="$(mktemp)"
  # -s read-only: ревью НЕ правит файлы; codex exec неинтерактивен и в read-only не спрашивает
  # аппрув (флаг -a/--ask-for-approval — только у интерактивного codex, в exec он ошибка). Инструкция —
  # аргументом (мал), большой diff — на stdin как доп. контекст (мимо argv-лимита). -o
  # пишет ТОЛЬКО финальное сообщение модели в файл (stdout у codex — шумный формат, гасим).
  # stderr НЕ глушим — причина падения видна в логе джоба.
  local args=(exec -s read-only --skip-git-repo-check --ephemeral -o "$msg")
  [ -n "${CODEX_MODEL:-}" ] && args+=(--model "$CODEX_MODEL")
  args+=("$(review_instruction)")

  if codex "${args[@]}" <"$diff_file" >/dev/null; then
    cat "$msg"
    rc=0
  else
    rc=1
  fi
  rm -f "$msg"
  return "$rc"
}

run_review codex "$out" call_codex
