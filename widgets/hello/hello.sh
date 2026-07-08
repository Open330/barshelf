#!/bin/bash
# hello — minimal output=viewtree widget: prints a UINode JSON tree to stdout.
set -euo pipefail

NOW="$(date '+%H:%M:%S')"
SECONDS_INTO_MINUTE=$((10#$(date '+%S')))
MINUTE_PROGRESS="$(printf '0.%02d' "$SECONDS_INTO_MINUTE" 2>/dev/null || echo '0.0')"

cat <<EOF
{
  "id": "hello-root",
  "type": "vstack",
  "spacing": 8,
  "children": [
    { "id": "hello-title", "type": "text", "text": "Hello from menubucket", "role": "title" },
    { "id": "hello-time", "type": "text", "text": "Rendered at ${NOW}", "role": "body", "monospacedDigit": true },
    {
      "id": "hello-progress",
      "type": "progress",
      "label": "Minute",
      "value": ${MINUTE_PROGRESS},
      "tint": "accent"
    },
    {
      "id": "hello-copy",
      "type": "button",
      "title": "Copy greeting",
      "icon": "doc.on.doc",
      "action": { "type": "copyText", "value": "Hello from menubucket at ${NOW}", "toast": "Copied!" }
    },
    { "id": "hello-caption", "type": "text", "text": "This tree came from hello.sh (output=viewtree)", "role": "caption" }
  ]
}
EOF
