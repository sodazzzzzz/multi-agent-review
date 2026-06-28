#!/usr/bin/env bash
# Ревьюер DeepSeek: POST в OpenAI-совместимый chat/completions, нормализует в
# review-deepseek.json. Тонкая обёртка — логика общая в lib.sh.
#
#   review_deepseek.sh <diff_file> <out_file>
#
# Env: DEEPSEEK_API_KEY (обяз.), DEEPSEEK_BASE_URL (опц., дефолт api.deepseek.com),
#      DEEPSEEK_MODEL (опц.).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

diff_file="${1:?usage: review_deepseek.sh <diff_file> <out_file>}"
out="${2:?out file required}"
base_url="${DEEPSEEK_BASE_URL:-https://api.deepseek.com}"
model="${DEEPSEEK_MODEL:-deepseek-v4-pro}"
: "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY required}"

call_deepseek() {
  local body resp
  body=$(jq -n --arg model "$model" --arg content "$(build_prompt "$diff_file")" \
    '{model: $model, stream: false, messages: [{role: "user", content: $content}]}')
  resp=$(curl -sS --fail-with-body --max-time 180 \
    -X POST "${base_url%/}/chat/completions" \
    -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body") || return 1
  printf '%s' "$resp" | jq -r '.choices[0].message.content // empty'
}

run_review deepseek "$out" call_deepseek
