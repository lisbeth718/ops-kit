#!/usr/bin/env bash
# disk-headroom-watch.sh - warn before a filesystem (or its inodes) fills up.
#
# A host filling its root or docker filesystem takes every app on it down:
# builds fail, databases cannot write, containers wedge. Build-cache churn, a
# runaway log, a dump or an upload dir can all creep up. Checks real mounts
# (not tmpfs/overlay/squashfs) for both block usage and inode usage; inodes can
# hit 100% with space to spare (lots of small files) and writes still fail.
#
# Env:
#   HOSTS        hosts to check (default: local), see lib.sh
#   PCT          warn at/above this use% on any real mount (default 85)
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1        print findings, send nothing
#
# Example /etc/cron.d line (every 30 minutes):
#   */30 * * * * root /usr/local/bin/cron-report.sh disk-headroom /usr/local/bin/disk-headroom-watch.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="disk-headroom"
PCT="${PCT:-85}"

read -r -d '' BODY <<'RSCRIPT' || true
# mounts at/over PCT: mount|use%|availKB|sizeKB   (df -P = portable columns)
df -P -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk -v pct="$PCT" 'NR>1 {
  gsub(/%/,"",$5);
  if ($5+0 >= pct) printf "%s|%s|%s|%s\n", $6, $5, $4, $2
}'
# inodes: IUse% is $5, mount $6, IFree $4. Marker "INODE".
df -iP -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk -v pct="$PCT" 'NR>1 {
  gsub(/%/,"",$5);
  if ($5 ~ /^[0-9]+$/ && $5+0 >= pct) printf "%s|%s|INODE|%s\n", $6, $5, $4
}'
RSCRIPT
REMOTE="$(rvars PCT)
$BODY"

parse_hosts
hot_total=0; expected=0; probed=0; MISSED=""
for i in "${!HOST_NAMES[@]}"; do
  sid="${HOST_NAMES[$i]}"; target="${HOST_TARGETS[$i]}"
  expected=$((expected+1))
  if ! out=$(probe_host "$target" "$REMOTE"); then MISSED="${MISSED:+$MISSED, }$sid"; continue; fi
  probed=$((probed+1))
  [ -z "$out" ] && continue
  hot=""
  while IFS='|' read -r mount pct avail size; do
    [ -z "$mount" ] && continue
    if [ "$avail" = "INODE" ]; then
      hot="${hot}
  - ${mount}: ${pct}% INODES used (${size} free), writes fail even with disk space"
    else
      hot="${hot}
  - ${mount}: ${pct}% used (${avail}KB free of ${size}KB)"
    fi
    hot_total=$((hot_total+1))
  done <<< "$out"
  [ -z "$hot" ] && continue
  echo "== $sid =="; printf '%s\n' "$hot"
  notify warn "disk filling on $sid" \
    "Disk filling on $sid (an app-killer: builds, databases and uploads fail at 100%):$hot" \
    "disk-headroom:$sid" || echo "notify failed for $sid"
done
coverage_check "$expected" "$probed" "$MISSED"
echo "$(now_iso) disk-headroom-watch: $hot_total mount(s) >= ${PCT}%, covered $probed/$expected hosts"
exit 0
