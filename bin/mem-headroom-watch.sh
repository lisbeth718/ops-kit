#!/usr/bin/env bash
# mem-headroom-watch.sh - warn when a container runs near its RAM cap.
#
# Flags containers at >= THRESHOLD% of their --memory limit: an early signal of a
# leak / imminent OOM kill, before docker's 137 shows up. Only containers WITH a
# memory limit are considered. The measure is the cgroup working set
# (usage minus file/page cache = anon+shmem), NOT docker's MemUsage, which only
# subtracts inactive_file and makes busy page cache look like a leak.
#
# Caveat: point-in-time proxy; a true leak trend needs history. A container
# steady-high and one climbing both trip it. Tune THRESHOLD if noisy.
#
# Env:
#   HOSTS        hosts to check (default: local), see lib.sh
#   THRESHOLD    warn at/above this % of limit (default 90)
#   SKIP_RE      regex of container names to ignore (default: common datastores
#                and proxies, plus names ending -db/-postgres/-redis/-kv)
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1        print findings, send nothing
#
# Example /etc/cron.d line (every 15 minutes):
#   */15 * * * * root /usr/local/bin/cron-report.sh mem-headroom /usr/local/bin/mem-headroom-watch.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="mem-headroom"
THRESHOLD="${THRESHOLD:-90}"
SKIP_RE="${SKIP_RE:-^(postgres|redis|traefik|nginx|caddy|watchtower)$|(-db|-postgres|-redis|-kv)$}"

# Emits name|pct|usedMiB|limitMiB per limited container, computed on the target
# host from its cgroup (v2, with a v1 fallback).
read -r -d '' PROBE <<'PROBEEOF' || true
for id in $(docker ps -q --no-trunc); do
  name=$(docker inspect -f '{{.Name}}' "$id" | tr -d /)
  lim=$(docker inspect -f '{{.HostConfig.Memory}}' "$id")
  [ "${lim:-0}" -gt 0 ] || continue
  cg=""
  for d in /sys/fs/cgroup/system.slice/docker-$id.scope /sys/fs/cgroup/docker/$id; do [ -r "$d/memory.stat" ] && cg=$d && break; done
  if [ -n "$cg" ]; then
    cur=$(cat "$cg/memory.current"); file=$(awk '$1=="file"{print $2}' "$cg/memory.stat")
    ws=$((cur - ${file:-0}))
  else
    d=/sys/fs/cgroup/memory/docker/$id; [ -r "$d/memory.stat" ] || continue
    cur=$(cat "$d/memory.usage_in_bytes"); file=$(awk '$1=="total_cache"{print $2}' "$d/memory.stat")
    ws=$((cur - ${file:-0}))
  fi
  [ "$ws" -lt 0 ] && ws=0
  echo "$name|$((ws * 100 / lim))|$((ws / 1048576))|$((lim / 1048576))"
done
PROBEEOF

parse_hosts
hot_total=0; expected=0; probed=0; MISSED=""
for i in "${!HOST_NAMES[@]}"; do
  sid="${HOST_NAMES[$i]}"; target="${HOST_TARGETS[$i]}"
  expected=$((expected+1))
  if ! stats=$(probe_host "$target" "$PROBE"); then MISSED="${MISSED:+$MISSED, }$sid"; continue; fi
  probed=$((probed+1))
  hot=""
  while IFS='|' read -r name perc used lim; do
    [ -z "$name" ] && continue
    printf '%s' "$name" | grep -qE "$SKIP_RE" && continue
    [[ "$perc" =~ ^[0-9]+$ ]] || continue
    if [ "$perc" -ge "$THRESHOLD" ]; then
      hot="${hot}
  - ${name}: ${perc}% (${used}MiB/${lim}MiB working set)"
      hot_total=$((hot_total+1))
    fi
  done <<< "$stats"
  [ -z "$hot" ] && continue
  echo "== $sid =="; printf '%s\n' "$hot"
  notify warn "RAM headroom low on $sid" \
    "Container(s) near their RAM cap on $sid (>=${THRESHOLD}% of limit, leak or imminent OOM):$hot" \
    "mem-headroom:$sid" || echo "notify failed for $sid"
done
coverage_check "$expected" "$probed" "$MISSED"
echo "$(now_iso) mem-headroom-watch: $hot_total container(s) >=${THRESHOLD}%, covered $probed/$expected hosts"
exit 0
