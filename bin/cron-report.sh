#!/usr/bin/env bash
# cron-report.sh - wrap any cron command: run it, time it, report failures.
#
# Usage: cron-report.sh <job-name> <command...>
#
# The command's own stdout/stderr is re-emitted unchanged, so existing log
# redirects and cron mail keep working. The wrapper's exit code is always the
# wrapped command's exit code.
#   - failure          -> notify error (output tail + one-line summary)
#   - success after a failure -> notify resolved (state kept per job)
#   - success          -> silent, or info if CRON_REPORT_SUCCESS=1
#   - slow run         -> notify warn if CRON_MAX_SECONDS is set and exceeded
#   - CRON_HEARTBEAT_URL (optional) is GET-pinged on success, for
#     healthchecks-style "no ping = cron died" services
# One-line summary, in priority order: a "SUMMARY: <text>" line the job printed,
# a compact rendering of JSON the job printed (needs jq), the last output line.
#
# Env:
#   HOST_ID               host label in alerts (default: first line of
#                         /etc/ops-kit-host-id, else `hostname`)
#   CRON_REPORT_SUCCESS   1 = also report successes (info)
#   CRON_MAX_SECONDS      warn when a run takes longer than this
#   CRON_HEARTBEAT_URL    URL to ping on success
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1                 run the command, but print alerts instead of sending
# If the alert itself cannot be delivered it is appended to
# $STATE_DIR/cron-report-failed.log (best effort) and printed to stderr.
#
# Example /etc/cron.d line:
#   15 3 * * * root /usr/local/bin/cron-report.sh nightly-backup /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="cron-report"

JOB="${1:-}"
if [ -z "$JOB" ] || [ $# -lt 2 ]; then echo "usage: cron-report.sh <job> <cmd...>" >&2; exit 2; fi
shift

HOST_ID="${HOST_ID:-$(head -1 /etc/ops-kit-host-id 2>/dev/null)}"
[ -n "$HOST_ID" ] || HOST_ID="$(hostname)"

START=$(date +%s)
OUT=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/cron-report.$$")
"$@" > "$OUT" 2>&1; CODE=$?
DUR=$(( $(date +%s) - START ))
cat "$OUT"   # preserve the command's original output

SUMMARY=$(grep '^SUMMARY:' "$OUT" 2>/dev/null | tail -1 | sed 's/^SUMMARY:[[:space:]]*//')
if [ -z "$SUMMARY" ] && command -v jq >/dev/null 2>&1; then
  JSON=$(grep -oE '\{.*\}' "$OUT" 2>/dev/null | tail -1)
  [ -n "$JSON" ] && SUMMARY=$(printf '%s' "$JSON" | jq -rc '
    def kv: to_entries|map("\(.key) \(.value|tostring)")|join(" / ");
    if type=="object" then
      if (has("summary") and (.summary|type=="string")) then .summary
      elif (has("result") and (.result|type=="object")) then (.result|kv)
      elif (has("result") and (.result|type=="string")) then .result
      elif (has("message") and (.message|type=="string")) then .message
      else (del(.success,.ok) | if (.|length)>0 then kv else "ok" end)
      end
    else tostring end' 2>/dev/null)
fi
[ -z "$SUMMARY" ] && SUMMARY=$(grep -vE '^[[:space:]]*$' "$OUT" 2>/dev/null | tail -1)
SUMMARY=$(printf '%s' "$SUMMARY" | tr '\n\r\t' '   ' | sed 's/[[:space:]]\{1,\}/ /g' | cut -c1-250)
TAIL=$(tail -n 15 "$OUT" 2>/dev/null)
rm -f "$OUT"

report_failed() { # reason
  echo "cron-report: FAILED to report $JOB ($1)" >&2
  { echo "$(now_iso) $HOST_ID $JOB exit=$CODE $1" >> "$STATE_DIR/cron-report-failed.log"; } 2>/dev/null || true
}
send() { notify "$1" "$2" "$3" "cron:$HOST_ID:$JOB" || report_failed "notify exit $?"; }

need_dir "$STATE_DIR/cron-report"
FLAG="$STATE_DIR/cron-report/$JOB.failed"
HEAD="$JOB on $HOST_ID: exit $CODE after ${DUR}s"

if [ "$CODE" -ne 0 ]; then
  send error "cron failed: $JOB ($HOST_ID)" "$HEAD
${SUMMARY:+summary: $SUMMARY
}--- last output ---
$TAIL"
  [ "$DRY" = "1" ] || touch "$FLAG" 2>/dev/null || true
else
  if [ -f "$FLAG" ]; then
    send resolved "cron recovered: $JOB ($HOST_ID)" "$HEAD"
    [ "$DRY" = "1" ] || rm -f "$FLAG"
  elif [ "${CRON_REPORT_SUCCESS:-0}" = "1" ]; then
    send info "cron ok: $JOB ($HOST_ID)" "$HEAD${SUMMARY:+
summary: $SUMMARY}"
  fi
  if [ -n "${CRON_MAX_SECONDS:-}" ] && [[ "$CRON_MAX_SECONDS" =~ ^[0-9]+$ ]] && [ "$DUR" -gt "$CRON_MAX_SECONDS" ]; then
    send warn "cron slow: $JOB ($HOST_ID)" "$HEAD (limit ${CRON_MAX_SECONDS}s)"
  fi
  if [ -n "${CRON_HEARTBEAT_URL:-}" ] && [ "$DRY" != "1" ]; then
    curl -fsS -m 8 -o /dev/null "$CRON_HEARTBEAT_URL" 2>/dev/null || report_failed "heartbeat ping"
  fi
fi
exit "$CODE"
