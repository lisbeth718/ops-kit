#!/usr/bin/env bash
# crash-loop-watch.sh - flag a container that is actively crash-looping.
#
# Triggers when docker is restarting a container right now, or its RestartCount
# climbed by >= RESTART_DELTA since the previous check. An uptime probe sees
# "down", but a container restarting every 30s flaps under a probe interval, and
# an OOM / bad-config loop otherwise stays silent. Delta-based (counts persist in
# STATE) so a container that looped once weeks ago and stabilized does not keep
# alarming. The first sighting only sets a baseline.
#
# Env:
#   HOSTS           hosts to check (default: local), see lib.sh
#   RESTART_DELTA   new restarts since last run that count as looping (default 3)
#   STATE           state dir (default $STATE_DIR/crash-loop)
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1           print findings, send nothing, do not advance the baseline
#
# Example /etc/cron.d line (every 5 minutes):
#   */5 * * * * root /usr/local/bin/cron-report.sh crash-loop /usr/local/bin/crash-loop-watch.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="crash-loop"
RESTART_DELTA="${RESTART_DELTA:-3}"
STATE="${STATE:-$STATE_DIR/crash-loop}"
need_dir "$STATE"; PREV="$STATE/counts.txt"; touch "$PREV" 2>/dev/null || true

# container|restartcount|state for every container that restarted at least once
# or is restarting now (count 0 and running cannot be looping)
read -r -d '' REMOTE <<'RSCRIPT' || true
docker ps -a --format '{{.Names}}|{{.RestartCount}}|{{.State}}' 2>/dev/null | awk -F'|' '$2+0 > 0 || $3 == "restarting"'
RSCRIPT

NEW=$(mktemp); expected=0; probed=0; hot_total=0; MISSED=""
prevcount() { awk -F'|' -v k="$1" '$1==k {print $2; exit}' "$PREV" 2>/dev/null; }

parse_hosts
for i in "${!HOST_NAMES[@]}"; do
  sid="${HOST_NAMES[$i]}"; target="${HOST_TARGETS[$i]}"
  expected=$((expected+1))
  if ! out=$(probe_host "$target" "$REMOTE"); then MISSED="${MISSED:+$MISSED, }$sid"; continue; fi
  probed=$((probed+1))
  hot=""
  while IFS='|' read -r name count state; do
    [ -z "$name" ] && continue
    key="${sid}:${name}"
    echo "${key}|${count}" >> "$NEW"        # persist current count for next run's delta
    if [ "$state" = "restarting" ]; then
      hot="${hot}
  - ${name}: docker is RESTARTING it now (count ${count})"; hot_total=$((hot_total+1)); continue
    fi
    pc=$(prevcount "$key"); [ -z "$pc" ] && continue          # first sighting: baseline only
    delta=$(( count - pc ))
    if [ "$delta" -ge "$RESTART_DELTA" ] 2>/dev/null; then
      hot="${hot}
  - ${name}: ${delta} restarts since last check (count ${count})"; hot_total=$((hot_total+1))
    fi
  done <<< "$out"
  [ -z "$hot" ] && continue
  echo "== $sid crash-looping =="; printf '%s\n' "$hot"
  notify error "container crash-looping on $sid" \
    "Container(s) crash-looping on $sid (restarting repeatedly: OOM / bad config / failing dependency):$hot" \
    "crash-loop:$sid" || echo "notify failed for $sid"
done

[ "$DRY" = "1" ] || { [ -s "$NEW" ] && mv "$NEW" "$PREV"; }
rm -f "$NEW" 2>/dev/null
coverage_check "$expected" "$probed" "$MISSED"
echo "$(now_iso) crash-loop-watch: $hot_total looping container(s), covered $probed/$expected hosts"
exit 0
