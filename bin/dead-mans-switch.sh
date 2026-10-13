#!/usr/bin/env bash
# dead-mans-switch.sh - external watchdog for the alarm system itself.
#
# Run it on a DIFFERENT box than your monitoring (a small separate VPS), with no
# dependency on anything that lives on the monitored side. Its whole job is to
# notice when the alarm system is dark: if the monitoring box dies, it takes every
# site, the uptime prober and the alert pipeline down with it, silently.
# Wrap it in cron-report.sh so your own digest counts this cron too (the watcher
# and the watched then watch each other).
#
# Two probe tiers (each domain is probed up to 3x; any 2xx-4xx answer = up):
#   CORE_DOMAINS      the alarm system's own hosts; page on the FIRST failed run
#   CRITICAL_FILE     static file of critical apps (one per line); page after
#                     MIN_FAILS consecutive failed runs (default 2), so a deploy
#                     container swap does not false-page. Static file by design: it
#                     must not depend on a database that lives on the monitored side.
# A down domain is NOT a cron failure: it pages via notify and still exits 0, so
# cron-report does not double-alert. Non-zero exit means the watchdog ITSELF is
# broken (no webhook configured, or a page that could not be sent).
# Pages repeat at most every DEBOUNCE seconds; a recovery notice is sent once.
#
# Env:
#   ALERT_WEBHOOK_URL   REQUIRED (a mute watchdog is no watchdog); see notify.sh
#   ALERT_WEBHOOK_TOKEN optional bearer token
#   CORE_DOMAINS        space separated hostnames (default: none)
#   CRITICAL_FILE       file of critical hostnames (default /etc/ops-kit/critical-domains.txt)
#   MIN_FAILS           consecutive failures before paging the critical tier (default 2)
#   DEBOUNCE            seconds between repeat pages (default 1800)
#   STATE               state dir (default $RUN_DIR/dead-mans-switch)
#   LOG                 log file (default $STATE/dead-mans-switch.log)
#   DRY=1               print status only, no alerts
#
# Example /etc/cron.d line (every 5 minutes, on the separate box):
#   */5 * * * * root /usr/local/bin/cron-report.sh dead-mans-switch /usr/local/bin/dead-mans-switch.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="dead-mans-switch"
STATE="${STATE:-$RUN_DIR/dead-mans-switch}"
LOG="${LOG:-$STATE/dead-mans-switch.log}"
CORE_DOMAINS="${CORE_DOMAINS:-}"
CRITICAL_FILE="${CRITICAL_FILE:-/etc/ops-kit/critical-domains.txt}"
MIN_FAILS="${MIN_FAILS:-2}"
DEBOUNCE="${DEBOUNCE:-1800}"
CRITICAL_DOMAINS=""
[ -f "$CRITICAL_FILE" ] && CRITICAL_DOMAINS=$(grep -vE '^[[:space:]]*(#|$)' "$CRITICAL_FILE" | tr '\n' ' ')
need_dir "$STATE"
exec 9>"$STATE/.lock"
flock -n 9 || { echo "previous run still going, skipping"; exit 0; }
now=$(date +%s)

if [ -z "${ALERT_WEBHOOK_URL:-}" ] && [ "$DRY" != "1" ]; then
  echo "FATAL: no ALERT_WEBHOOK_URL, a mute watchdog is no watchdog" >&2
  exit 1
fi
if [ -z "${CORE_DOMAINS// /}" ] && [ -z "${CRITICAL_DOMAINS// /}" ]; then
  echo "FATAL: nothing to probe (set CORE_DOMAINS or CRITICAL_FILE)" >&2
  exit 1
fi

# Callers only record "alerted" state after a successful send: a failed page
# must retry on the next run, not sit out the debounce.
rc=0
page() { # severity title body fingerprint
  notify "$@" && return 0
  echo "SEND FAILED: $2" >&2
  rc=1; return 1
}

# probe a host up to 3x; reachable (2xx-4xx) on ANY attempt => up
up_code() {
  local h="$1" c=000 a
  for a in 1 2 3; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -L "https://$h/" 2>/dev/null)
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" != "000" ] && [ "$c" -lt 500 ]; then echo "$c"; return 0; fi
    [ "$a" -lt 3 ] && sleep 3
  done
  echo "$c"; return 1
}

probe_list() { # $1=list  $2=down-message-suffix  $3=consecutive down-runs needed to page
  local suffix="$2" minfails="${3:-1}" host sf cf code fails last
  for host in $1; do
    sf="$STATE/$host"        # alert-debounce timestamp
    cf="$STATE/$host.fails"  # consecutive down-run counter
    if code=$(up_code "$host"); then
      echo "up $host ($code)"
      [ "$DRY" != "1" ] && rm -f "$cf"
      if [ -f "$sf" ] && [ "$DRY" != "1" ]; then
        if page resolved "$host recovered (HTTP $code)" "External watchdog: $host answers again." "dms:$host"; then
          rm -f "$sf"; echo "$(date -Is) UP $host $code" >> "$LOG"
        fi
      fi
    else
      echo "DOWN $host ($code)"
      [ "$DRY" = "1" ] && continue
      fails=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$fails" > "$cf"
      if [ "$fails" -lt "$minfails" ]; then
        echo "  ($host down ${fails}/${minfails} runs, holding, likely a deploy swap)"
        continue
      fi
      last=$(cat "$sf" 2>/dev/null || echo 0)
      if [ $((now - last)) -ge "$DEBOUNCE" ]; then
        if page error "$host is DOWN (HTTP $code, ${fails} runs)" "External watchdog.$suffix" "dms:$host"; then
          echo "$now" > "$sf"; echo "$(date -Is) DOWN $host $code" >> "$LOG"
        fi
      fi
    fi
  done
}

probe_list "$CORE_DOMAINS" " This host serves the alarm system: quiet channels are unverified until it recovers." 1
probe_list "$CRITICAL_DOMAINS" " (critical-app probe, fires even if the main monitoring box is dark.)" "$MIN_FAILS"
exit "$rc"
