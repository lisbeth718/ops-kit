#!/usr/bin/env bash
# notify.sh - the one notifier every ops-kit script reports through.
#
# Usage:  notify.sh <severity> <title> [body]     (body "-" reads stdin)
#   severity: info | warn | error | resolved
#
# POSTs JSON to $ALERT_WEBHOOK_URL:
#   {"source":"...","severity":"...","title":"...","body":"...","fingerprint":"..."}
# With no URL configured (or if the POST fails twice) the alert is printed to
# stdout instead (jq is required to build the payload), so cron mail / log files still capture it. A failed POST exits 1.
#
# Env:
#   ALERT_WEBHOOK_URL     webhook endpoint (unset = stdout only)
#   ALERT_WEBHOOK_TOKEN   optional bearer token
#   NOTIFY_SOURCE         "source" field (default: ops-kit)
#   NOTIFY_FINGERPRINT    dedup key for the receiver (default: <source>:<title>)
#   NOTIFY_MAX_BODY       truncate body to this many chars (default 3500)
#   DRY=1                 print what would be sent, send nothing
#
# Example: ALERT_WEBHOOK_URL=https://hooks.example.com/ops notify.sh warn "disk 91%" "web1 /"
set -uo pipefail

sev="${1:-info}"; title="${2:-}"
[ -n "$title" ] || { echo "usage: notify.sh <severity> <title> [body|-]" >&2; exit 2; }
body="${3:-}"
if [ "$body" = "-" ]; then body=$(cat); fi

source_name="${NOTIFY_SOURCE:-ops-kit}"
fingerprint="${NOTIFY_FINGERPRINT:-$source_name:$title}"
max="${NOTIFY_MAX_BODY:-3500}"
[ "${#body}" -gt "$max" ] && body="${body:0:$max}..."

payload=$(jq -nc --arg source "$source_name" --arg severity "$sev" --arg title "$title" \
  --arg body "$body" --arg fingerprint "$fingerprint" \
  '{source:$source,severity:$severity,title:$title,body:$body,fingerprint:$fingerprint}')

to_stdout() {
  printf '[%s] %s: %s\n' "$sev" "$source_name" "$title"
  [ -n "$body" ] && printf '%s\n' "$body"
  return 0
}

if [ "${DRY:-0}" = "1" ]; then
  printf '[dry] '; to_stdout
  exit 0
fi

url="${ALERT_WEBHOOK_URL:-}"
if [ -z "$url" ]; then to_stdout; exit 0; fi

post() {
  if [ -n "${ALERT_WEBHOOK_TOKEN:-}" ]; then
    # header via fd, not argv, so the token never shows up in `ps`
    curl -fsS -m 10 -o /dev/null -X POST "$url" -H "Content-Type: application/json" \
      -H @<(printf 'Authorization: Bearer %s\n' "$ALERT_WEBHOOK_TOKEN") -d "$payload" 2>&1
  else
    curl -fsS -m 10 -o /dev/null -X POST "$url" -H "Content-Type: application/json" -d "$payload" 2>&1
  fi
}

if err=$(post) || { sleep 2; err=$(post); }; then
  exit 0
fi
echo "notify.sh: webhook POST failed: ${err:0:200}" >&2
to_stdout
exit 1
