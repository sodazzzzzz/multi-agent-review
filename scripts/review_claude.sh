#!/usr/bin/env bash
# Ревьюер Claude: гоняет `claude -p` (подписка через CLAUDE_CODE_OAUTH_TOKEN из env),
# нормализует вывод в review-claude.json. Тонкая обёртка — логика общая в lib.sh.
#
#   review_claude.sh <diff_file> <out_file>
#
# Env: CLAUDE_CODE_OAUTH_TOKEN (обяз., читает сам claude CLI), CLAUDE_MODEL (опц.).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

diff_file="${1:?usage: review_claude.sh <diff_file> <out_file>}"
out="${2:?out file required}"
model="${CLAUDE_MODEL:-claude-opus-4-8}"

call_claude() {
  # Инструкция-контракт — аргументом (мал, фикс.), большой diff — на stdin: так PR не
  # упирается в лимит длины одного argv (MAX_ARG_STRLEN). stderr НЕ глушим — если claude
  # упал, причина видна в логе джоба (пустой вывод → ретрай → агент «упал»).
  # --output-format json печатает {"result":"<текст>",...}; берём .result.
  claude -p "$(review_instruction)" \
    --model "$model" \
    --output-format json \
    --max-turns 1 \
    <"$diff_file" \
    | jq -r '.result // empty'
}

run_review claude "$out" call_claude
