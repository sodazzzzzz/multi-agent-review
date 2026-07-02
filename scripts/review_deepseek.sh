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
  # --rawfile читает diff из файла (минуя argv-лимит), --arg — короткую инструкцию;
  # склеиваем в один user-месседж.
  body=$(jq -n --arg model "$model" --arg instr "$(review_instruction)" \
    --rawfile diff "$diff_file" \
    '{model: $model, stream: false,
      messages: [{role: "user", content: ($instr + "\n\n=== DIFF ===\n" + $diff)}]}')
  # body с диффом шлём через stdin (--data-binary @-), а не аргументом: большой JSON
  # не влезает в MAX_ARG_STRLEN (~128 КБ) и curl падает «Argument list too long» ещё
  # до сети. Ровно этот же лимит на входе обходит --rawfile выше.
  resp=$(printf '%s' "$body" | curl -sS --fail-with-body --max-time 180 \
    -X POST "${base_url%/}/chat/completions" \
    -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
    -H "Content-Type: application/json" \
    --data-binary @-) || return 1
  printf '%s' "$resp" | jq -r '.choices[0].message.content // empty'
}

run_review deepseek "$out" call_deepseek
