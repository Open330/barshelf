#!/bin/bash
# hello — minimal output=viewtree widget: prints a UINode JSON tree to stdout.
set -euo pipefail

NOW="$(date '+%H:%M:%S')"
SECONDS_INTO_MINUTE=$((10#$(date '+%S')))
MINUTE_PROGRESS="$(printf '0.%02d' "$SECONDS_INTO_MINUTE" 2>/dev/null || echo '0.0')"

# Fixed text in the language BarShelf passes as LANG; English otherwise.
# None of it may contain a double quote or backslash (it goes into JSON as is).
case "${LANG:-}" in
  ko*)
    TITLE="BarShelf에서 보내는 인사"
    RENDERED="${NOW}에 그림"
    MINUTE="분"
    COPY_TITLE="인사말 복사"
    GREETING="${NOW}, BarShelf에서 보내는 인사"
    COPIED="복사했습니다!"
    CAPTION="이 트리는 hello.sh가 만들었습니다 (output=viewtree)"
    ;;
  *)
    TITLE="Hello from BarShelf"
    RENDERED="Rendered at ${NOW}"
    MINUTE="Minute"
    COPY_TITLE="Copy greeting"
    GREETING="Hello from BarShelf at ${NOW}"
    COPIED="Copied!"
    CAPTION="This tree came from hello.sh (output=viewtree)"
    ;;
esac

cat <<EOF
{
  "id": "hello-root",
  "type": "vstack",
  "spacing": 8,
  "children": [
    { "id": "hello-title", "type": "text", "text": "${TITLE}", "role": "title" },
    { "id": "hello-time", "type": "text", "text": "${RENDERED}", "role": "body", "monospacedDigit": true },
    {
      "id": "hello-progress",
      "type": "progress",
      "label": "${MINUTE}",
      "value": ${MINUTE_PROGRESS},
      "tint": "accent"
    },
    {
      "id": "hello-copy",
      "type": "button",
      "title": "${COPY_TITLE}",
      "icon": "doc.on.doc",
      "action": { "type": "copyText", "value": "${GREETING}", "toast": "${COPIED}" }
    },
    { "id": "hello-caption", "type": "text", "text": "${CAPTION}", "role": "caption" }
  ]
}
EOF
