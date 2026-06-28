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
  # --output-format json печатает {"result":"<текст>",...}; берём .result.
  claude -p "$(build_prompt "$diff_file")" \
    --model "$model" \
    --output-format json \
    --max-turns 1 2>/dev/null \
    | jq -r '.result // empty'
}

run_review claude "$out" call_claude
