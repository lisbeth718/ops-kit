#!/usr/bin/env bash
# exposed-port-watch.sh - flag datastore/admin services bound to a PUBLIC interface.
#
# Postgres, redis, mongo, mysql, elastic, rabbitmq, memcached etc. must only ever
# listen on localhost or a private network. A container publishing 5432 to
# all interfaces puts the whole database one firewall rule away from the internet.
# App HTTP ports (80/443/3000...) are ignored; only the datastore/admin ports in
# PORTS are checked, and only when bound to the wildcard address (all interfaces).
#
# Env:
#   HOSTS        hosts to check (default: local), see lib.sh
#   PORTS        pipe-separated ports that must never be public (default: common
#                datastore and admin ports, see below)
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1        print findings, send nothing
#
# Example /etc/cron.d line (hourly):
#   7 * * * * root /usr/local/bin/cron-report.sh exposed-port /usr/local/bin/exposed-port-watch.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="exposed-port"
PORTS="${PORTS:-5432|6379|3306|33060|27017|27018|9200|9300|5672|15672|11211|5984|8086|9000|9092|2379|6380}"

read -r -d '' BODY <<'RSCRIPT' || true
# listening TCP sockets bound to all interfaces on a dangerous port
ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E "^(0\.0\.0\.0|\[::\]|\*):(${PORTS})\$" | sort -u | while read -r bind; do
  port=${bind##*:}
  proc=$(ss -tlnpH "sport = :$port" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -1 | sed 's/.*"\(.*\)/\1/')
  echo "${bind}|${proc:-?}"
done
RSCRIPT
REMOTE="$(rvars PORTS)
$BODY"

parse_hosts
expected=0; probed=0; hot_total=0; MISSED=""
for i in "${!HOST_NAMES[@]}"; do
  sid="${HOST_NAMES[$i]}"; target="${HOST_TARGETS[$i]}"
  expected=$((expected+1))
  if ! out=$(probe_host "$target" "$REMOTE"); then MISSED="${MISSED:+$MISSED, }$sid"; continue; fi
  probed=$((probed+1))
  hot=""
  while IFS='|' read -r bind proc; do
    [ -z "$bind" ] && continue
    hot="${hot}
  - ${bind} (${proc})"; hot_total=$((hot_total+1))
  done <<< "$out"
  [ -z "$hot" ] && continue
  printf '== %s PUBLIC datastore ports ==%s\n' "$sid" "$hot"
  notify error "PUBLIC datastore port on $sid" \
    "A datastore/admin port is bound to a PUBLIC interface on $sid. It must be localhost/private only (verify the firewall and the compose port publish):$hot" \
    "exposed-port:$sid" || echo "notify failed for $sid"
done
coverage_check "$expected" "$probed" "$MISSED"
echo "$(now_iso) exposed-port-watch: $hot_total public datastore port(s), covered $probed/$expected hosts"
exit 0
