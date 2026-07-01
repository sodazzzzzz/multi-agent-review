#!/usr/bin/env bash
# Общие хелперы тонких обёрток-ревьюеров. Источается: `. "$(dirname "$0")/lib.sh"`.
#
# Контракт прост: модель отдаёт ТОЛЬКО JSON-массив находок; скрипт оборачивает его в
# конверт {agent, findings} с ПРАВИЛЬНЫМ именем агента (модель его не выбирает) и пишет
# review-<agent>.json. Строгую валидацию по схеме делает аггрегатор (битый артефакт →
# агент помечается «не отработал»), поэтому здесь — только лёгкая проверка формы + 1 ретрай.

# review_instruction — печатает промпт-контракт БЕЗ диффа (его прикладываем отдельно:
# для Claude — на stdin, для DeepSeek — в JSON-теле). Так большой PR не упирается в
# лимит длины ОДНОГО argv-аргумента (Linux MAX_ARG_STRLEN ≈ 128К): дифф идёт мимо argv.
review_instruction() {
  cat <<'PROMPT'
You are a strict code reviewer. You are given a unified diff of a pull request. Find REAL
problems (bug, security, performance, design, test, style) in the INTRODUCED changes.

Reply STRICTLY with a JSON array and NOTHING else (no markdown, no explanations):
[{"file":"path","line":<RIGHT-side line number or null>,"severity":"P0|P1|P2",
  "category":"bug|security|performance|style|design|test","message":"1-3 sentences in English",
  "suggestion":"replacement code for the line or null"}]

Rules:
- line — the number in the NEW version of the file (right side of the diff), or null if it can't be anchored.
- severity: P0 — blocking error, P1 — important, P2 — minor.
- suggestion — code only, without markdown fences, or null.
- Do not invent problems. If there are none, return [].
- Write every "message" in English.
PROMPT

  # Проектная рубрика ревьюимого репо (бот тянет её .github/STANDARDS.md в REPO_STANDARDS_FILE).
  # Задана и непуста → дописываем в конец промпта. Контракт вывода (P0|P1|P2, только JSON) выше
  # ГЛАВНЕЕ: если рубрика вводит свои метки серьёзности, модель маппит их на P0/P1/P2.
  if [ -n "${REPO_STANDARDS_FILE:-}" ] && [ -s "${REPO_STANDARDS_FILE}" ]; then
    printf '\n\n---\nProject-specific review standards for the repository under review. Apply them. When they use their own severity vocabulary, map it onto the P0/P1/P2 JSON contract above.\n\n'
    cat "${REPO_STANDARDS_FILE}"
  fi
}

# extract_array <raw> — печатает JSON-массив находок (иначе пусто). Снимает
# ```json/```-заборы. Принимает И голый массив, И конверт-объект {…, "findings":[…]}:
# модели часто заворачивают ответ в объект, даже когда просили массив, — без этого
# рабочий агент ложно «падал». Лишние ключи конверта тут же отсекаются (берём массив).
extract_array() {
  local raw="$1" cleaned
  cleaned=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*```json[[:space:]]*$//' -e 's/^[[:space:]]*```[[:space:]]*$//')
  printf '%s' "$cleaned" | jq -ec '
    if type == "array" then .
    elif type == "object" and (.findings | type == "array") then .findings
    else empty end' 2>/dev/null
}

# finalize <agent> <raw> <out_file> — извлечь массив, обернуть в конверт, записать.
# Возвращает 0 при успехе; 1 — если валидного массива нет (файл НЕ создаётся).
finalize() {
  local agent="$1" raw="$2" out="$3" findings
  findings=$(extract_array "$raw")
  [ -n "$findings" ] || return 1
  jq -n --arg agent "$agent" --argjson findings "$findings" \
    '{agent: $agent, findings: $findings}' >"$out"
}

# run_review <agent> <out_file> <call_fn> — общий цикл: 2 попытки получить валидный JSON.
# call_fn — имя функции, печатающей сырой текст модели в stdout.
run_review() {
  local agent="$1" out="$2" call_fn="$3" attempt content
  for attempt in 1 2; do
    [ "$attempt" -gt 1 ] && sleep 3 # короткий бэкофф: 2-я попытка против транзиентных сбоев
    content="$("$call_fn" || true)"
    if finalize "$agent" "$content" "$out"; then
      echo "review_${agent}: ok (попытка $attempt) → $out"
      return 0
    fi
    echo "review_${agent}: невалидный вывод, попытка $attempt" >&2
  done
  echo "review_${agent}: не удалось получить валидный JSON — агент будет помечен как упавший" >&2
  return 1
}
