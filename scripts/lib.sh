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
Ты — строгий код-ревьюер. Тебе дан unified diff пулл-реквеста. Найди РЕАЛЬНЫЕ проблемы
(bug, security, performance, design, test, style) во ВНЕСЁННЫХ изменениях.

Ответь СТРОГО JSON-массивом и НИЧЕМ больше (без markdown, без пояснений):
[{"file":"путь","line":<число RIGHT-строки или null>,"severity":"P0|P1|P2",
  "category":"bug|security|performance|style|design|test","message":"1–3 предложения",
  "suggestion":"код на замену строки или null"}]

Правила:
- line — номер в НОВОЙ версии файла (правая сторона диффа) или null, если не привязать.
- severity: P0 — блокирующая ошибка, P1 — важная, P2 — мелкая.
- suggestion — только код без markdown-обрамления, либо null.
- Не выдумывай проблемы. Если их нет — верни [].
PROMPT
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
