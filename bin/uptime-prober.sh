#!/usr/bin/env bash
# uptime-prober.sh - probe every watched domain, alert on down and on unhealthy.
#
# Each domain is fetched up to 3x (15s timeout each); any 2xx-4xx answer on any
# attempt = up, only three failures in a row = DOWN. That kills transient false
# positives (one IPv6/edge/DNS blip no longer pages).
# Deep health: liveness ("/ renders") misses "app is up but its DB or deps are
# broken". If an app serves HEALTH_PATH (default /api/health) returning JSON with
# a `status` field, it is checked: unhealthy when status/db/a deps entry holds an
# explicit failure value (false, error, down, fail, timeout, degraded, ...) or a
# stale/fresh flag says stale. Apps without the endpoint (HTML/404, no `status`)
# are skipped, so this is additive and never a false down. Needs jq.
#
# Debounce: the first DOWN page and the recovery notice go out immediately; a host
# that stays down re-pages every DOWN_DEBOUNCE seconds. Degraded alerts repeat
# every DEBOUNCE seconds. State is written only after a successful send, so a
# failed page retries on the next run. One run at a time (flock): a dead host costs
# ~51s, so a bad night could otherwise overlap runs and double-page.
#
# Env:
#   DOMAINS / DOMAINS_FILE   hostnames to probe, see lib.sh
#   EXCLUDE_FILE   hostnames to skip, one per line (default /etc/ops-kit/uptime-exclude.txt)
#   HEALTH_PATH    deep-health path, empty string disables (default /api/health)
#   DOWN_DEBOUNCE  seconds between repeat DOWN pages (default 7200)
#   DEBOUNCE       seconds between repeat degraded pages (default 1800)
#   STATE          state dir (default $RUN_DIR/uptime-prober)
#   LOG            log file (default $STATE/uptime-prober.log)
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1          list only, no alerts
#
# Example /etc/cron.d line (every 5 minutes):
#   */5 * * * * root /usr/local/bin/cron-report.sh uptime-prober /usr/local/bin/uptime-prober.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="uptime-prober"
STATE="${STATE:-$RUN_DIR/uptime-prober}"
LOG="${LOG:-$STATE/uptime-prober.log}"
EXCLUDE_FILE="${EXCLUDE_FILE:-/etc/ops-kit/uptime-exclude.txt}"
HEALTH_PATH="${HEALTH_PATH-/api/health}"
DEBOUNCE="${DEBOUNCE:-1800}"
DOWN_DEBOUNCE="${DOWN_DEBOUNCE:-7200}"
need_dir "$STATE"
exec 9>"$STATE/.lock"
flock -n 9 || { echo "previous run still going, skipping"; exit 0; }
now=$(date +%s)
SEND_FAILS=0

if [ -z "${ALERT_WEBHOOK_URL:-}" ] && [ "$DRY" != "1" ]; then
  echo "FATAL: no ALERT_WEBHOOK_URL, a mute prober is no prober" >&2
  exit 1
fi

page() { # severity title body fingerprint; non-zero if the webhook did not take it
  notify "$@" && return 0
  echo "SEND FAILED: $2" >&2
  SEND_FAILS=$((SEND_FAILS+1)); return 1
}

# An empty domain list means config broke (renamed file, bad path), NOT that
# everything is up. Hard failure: alert (debounced) and exit non-zero.
DOMAIN_LIST=$(load_domains)
if [ -z "$DOMAIN_LIST" ]; then
  echo "$(date -Is) FATAL empty domain list" >> "$LOG" 2>/dev/null
  sf="$STATE/_empty-list"
  last=$(cat "$sf" 2>/dev/null || echo 0)
  if [ $((now - last)) -ge "$DEBOUNCE" ] && [ "$DRY" != "1" ]; then
    page error "uptime-prober has an EMPTY domain list" \
      "Probing nothing. Check DOMAINS / DOMAINS_FILE on $(hostname)." "uptime-prober:empty" \
      && echo "$now" > "$sf"
  fi
  echo "FATAL: empty domain list" >&2
  exit 1
fi
rm -f "$STATE/_empty-list"

up_code() { # probe up to 3x
  local h="$1" c=000 a
  for a in 1 2 3; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -L "https://$h/" 2>/dev/null)
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" != "000" ] && [ "$c" -lt 500 ]; then echo "$c"; return 0; fi
    [ "$a" -lt 3 ] && sleep 3
  done
  echo "$c"; return 1
}

# Returns: 0 healthy / 1 unhealthy (prints reasons) / 2 no health endpoint.
# Conservative: only EXPLICIT failure signals alert. States like "not_configured",
# "disabled", "n/a" are not failures.
health_probe() {
  local h="$1" body bad
  body=$(curl -s --max-time 10 -L "https://$h$HEALTH_PATH" 2>/dev/null)
  echo "$body" | jq -e 'type=="object" and has("status")' >/dev/null 2>&1 || return 2
  bad=$(echo "$body" | jq -rc '
    def broken(v): (v|tostring|ascii_downcase) as $s
      | ($s=="false" or ($s|test("error|down|fail|unreach|disconnect|refus|timeout|dead|unhealthy|degraded|critical|offline|not_?ready")));
    [ (if (.status? and broken(.status)) then "status="+(.status|tostring) else empty end),
      (if (.db? and broken(.db)) then "db="+(.db|tostring) else empty end),
      ((.deps? // {}) | (if type=="object" then to_entries[] else empty end)
         | select(.value | broken(.)) | "dep."+.key+"="+(.value|tostring)),
      (if (.stale==true or .fresh==false) then "data=stale" else empty end)
    ] | join(", ")' 2>/dev/null)
  [ -n "$bad" ] && { echo "$bad"; return 1; }
  return 0
}

down_list=""
for host in $DOMAIN_LIST; do
  grep -qxF "$host" "$EXCLUDE_FILE" 2>/dev/null && continue
  if code=$(up_code "$host"); then
    sf="$STATE/$host"
    if [ -f "$sf" ] && [ "$DRY" != "1" ]; then
      if page resolved "$host recovered (HTTP $code)" "$host is answering again." "uptime:$host"; then
        rm -f "$sf"; echo "$(date -Is) UP $host $code" >> "$LOG"
      fi
    fi
    [ -n "$HEALTH_PATH" ] || continue
    hbad=$(health_probe "$host"); hrc=$?
    hsf="$STATE/health-$host"
    if [ "$hrc" = "1" ]; then
      echo "$(date -Is) DEGRADED $host $hbad" >> "$LOG"
      if [ "$DRY" = "1" ]; then
        echo "DEGRADED: $host - $hbad"
      else
        hlast=$(cat "$hsf" 2>/dev/null || echo 0)
        if [ $((now - hlast)) -ge "$DEBOUNCE" ]; then
          page warn "$host is UP but UNHEALTHY" "$hbad" "uptime-health:$host" && echo "$now" > "$hsf"
        fi
      fi
    elif [ "$hrc" = "0" ] && [ -f "$hsf" ] && [ "$DRY" != "1" ]; then
      page resolved "$host health recovered" "$HEALTH_PATH reports healthy again." "uptime-health:$host" && rm -f "$hsf"
    fi
  else
    down_list="$down_list  $host -> $code (3x fail)
"
    sf="$STATE/$host"
    [ "$DRY" = "1" ] && continue
    last=$(cat "$sf" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge "$DOWN_DEBOUNCE" ]; then
      if page error "$host is DOWN (HTTP $code, 3 consecutive fails)" "Probed from $(hostname)." "uptime:$host"; then
        echo "$now" > "$sf"; echo "$(date -Is) DOWN $host $code" >> "$LOG"
      fi
    fi
  fi
done

if [ -n "$down_list" ]; then printf 'DOWN:\n%s' "$down_list"; else echo "all up"; fi
if [ "$SEND_FAILS" -gt 0 ]; then echo "FAIL: $SEND_FAILS alert send(s) failed" >&2; exit 1; fi
exit 0
