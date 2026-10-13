#!/usr/bin/env bash
# rogue-container-watch.sh - daily drift check for unexpected containers.
#
# Every running container on every host must be either on your expected list or
# match a known-infra pattern. A container nobody registered is either a forgotten
# hand-start (drift) or someone else's process (much worse): both deserve a ping.
#
# A container is NOT rogue if any of these hold:
#   - its name is in the expected list (KNOWN_CONTAINERS and/or KNOWN_FILE; a file
#     line is "container" for any host or "host-name:container" for one host)
#   - its name matches ALLOW_RE (infra patterns)
#   - it is a compose sidecar: its compose PROJECT label equals an expected
#     container's name (compose services share the app's project; a hand
#     `docker run` has no label, so this cannot launder a real rogue)
#   - it is a preview container named "<expected-name>-<suffix>"
# An unreachable host is reported too: a blind spot is not a pass.
#
# Env:
#   HOSTS             hosts to check (default: local), see lib.sh
#   KNOWN_CONTAINERS  space separated expected container names
#   KNOWN_FILE        file of expected containers (default /etc/ops-kit/known-containers.txt)
#   ALLOW_RE          regex of always-allowed names (default: common infra). Matched
#                     against the whole name, so anchor it: the default allows "redis"
#                     and "redis-1" but NOT "redis-whatever"
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1             print findings, send nothing
#
# Example /etc/cron.d line (daily):
#   10 6 * * * root /usr/local/bin/cron-report.sh rogue-container /usr/local/bin/rogue-container-watch.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="rogue-container"
KNOWN_CONTAINERS="${KNOWN_CONTAINERS:-}"
KNOWN_FILE="${KNOWN_FILE:-/etc/ops-kit/known-containers.txt}"
ALLOW_RE="${ALLOW_RE:-^(postgres|redis|traefik|nginx|caddy|watchtower)(-[0-9]+)?\$|(-postgres|-db|-redis|-nginx)(-[0-9]+)?\$|^docker-|_default\$}"

PS_CMD='docker ps --format "{{.Names}}|{{.Label \"com.docker.compose.project\"}}"'

known_for() { # $1 = host name -> expected container names, one per line
  # shellcheck disable=SC2086
  printf '%s\n' $KNOWN_CONTAINERS
  [ -r "$KNOWN_FILE" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$KNOWN_FILE" | awk -v h="$1" '{
    if (index($1, ":")) { split($1, p, ":"); if (p[1] == h) print p[2] } else print $1 }'
}

parse_hosts
rogues=0 hosts=0 unreachable=""
for i in "${!HOST_NAMES[@]}"; do
  sid="${HOST_NAMES[$i]}"; target="${HOST_TARGETS[$i]}"
  if ! running=$(run_on "$target" "$PS_CMD" 2>/dev/null) || [ -z "$running" ]; then
    # empty output with a live docker is a legit "no containers"; verify it
    if ! run_on "$target" "docker ps -q >/dev/null 2>&1" 2>/dev/null; then
      unreachable="$unreachable $sid"
      notify warn "rogue-container-watch could not reach $sid" \
        "Drift on $sid is currently unwatched (ssh or docker unavailable)." "rogue-unreachable:$sid" || true
      continue
    fi
  fi
  hosts=$((hosts+1))
  known=$(known_for "$sid")
  while IFS='|' read -r c proj; do
    [ -z "$c" ] && continue
    printf '%s\n' "$known" | grep -qxF "$c" && continue
    printf '%s' "$c" | grep -qE "$ALLOW_RE" && continue
    if [ -n "$proj" ] && printf '%s\n' "$known" | grep -qxF "$proj"; then continue; fi
    parent_match=0
    while IFS= read -r k; do
      [ -n "$k" ] && case "$c" in "$k"-*) parent_match=1; break ;; esac
    done <<< "$known"
    [ "$parent_match" = "1" ] && continue
    rogues=$((rogues+1))
    echo "ROGUE on $sid: $c"
    notify warn "unregistered container on $sid: $c" \
      "Container $c is running on $sid but is not on the expected list or a known infra pattern. Forgotten hand-start, or not yours." \
      "rogue-container:$sid:$c" || echo "notify failed for $c"
  done <<< "$running"
done

echo "$(now_iso) rogue-container-watch: $hosts host(s) checked, $rogues rogue(s)${unreachable:+, UNREACHABLE:$unreachable}"
# Always exit 0: rogues and unreachable hosts are reported through notify, which
# is the script WORKING. A non-zero exit would make a cron-report wrapper raise a
# second, redundant "cron failed" alert every run.
exit 0
