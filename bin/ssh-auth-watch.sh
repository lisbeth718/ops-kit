#!/usr/bin/env bash
# ssh-auth-watch.sh - alert on successful SSH logins from never-seen IPs.
#
# Run it ON each server (it reads that server's sshd logs). It compares the
# source IP of each recent successful login against a persistent known-IPs set:
#   - new IP -> notify (warn) once, IP added to the set
#   - known  -> silent
# The first run (empty state) SEEDS the set from 30 days of history without
# alerting, so your normal IPs never false-fire. Reads the systemd journal
# (sshd, and sshd-session on OpenSSH 9.8+); falls back to AUTH_LOG when journalctl is unavailable.
#
# Env:
#   HOST_ID      label for this server in alerts (default: first line of
#                /etc/ops-kit-host-id, else `hostname`)
#   WINDOW       how far back each run looks (default "-15 minutes"; keep it
#                longer than the cron interval)
#   AUTH_LOG     fallback log file (default /var/log/auth.log; no window filter,
#                relies on the known-IP set, so keep seeding in mind)
#   STATE        state dir (default $STATE_DIR/ssh-auth-watch)
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1        print findings, send nothing, do not record IPs
#
# Example /etc/cron.d line (every 10 minutes):
#   */10 * * * * root /usr/local/bin/cron-report.sh ssh-auth /usr/local/bin/ssh-auth-watch.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="ssh-auth"
STATE="${STATE:-$STATE_DIR/ssh-auth-watch}"
KNOWN="$STATE/known-ips"
SEEDED="$STATE/seeded"   # sentinel: an empty seed (no logins yet) must not reseed forever
WINDOW="${WINDOW:--15 minutes}"
AUTH_LOG="${AUTH_LOG:-/var/log/auth.log}"
HOST_ID="${HOST_ID:-$(head -1 /etc/ops-kit-host-id 2>/dev/null)}"
HOST_ID="${HOST_ID:-$(hostname)}"
need_dir "$STATE"

auth_lines() { # $1 = journal window; prints "Accepted ..." and "Failed ..." lines
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -t sshd -t sshd-session --since "$1" -o cat 2>/dev/null
  elif [ -r "$AUTH_LOG" ]; then
    sed -E 's/^.*sshd(-session)?\[[0-9]+\]: //' "$AUTH_LOG"
  fi
}
logins() { auth_lines "$1" | grep -E "^Accepted " | awk '{print $4 "|" $6}' | sort -u; }

[ -f "$SEEDED" ] || { [ -s "$KNOWN" ] && touch "$SEEDED"; }   # upgrade: existing state counts as seeded
if [ ! -f "$SEEDED" ]; then
  if [ "$DRY" = "1" ]; then echo "[dry] would seed known IPs from 30d of history"; exit 0; fi
  logins "-30 days" | cut -d'|' -f2 | sort -u > "$KNOWN"
  touch "$SEEDED"
  echo "seeded $(wc -l < "$KNOWN") known IP(s) from 30d of history, no alerts on seed run"
  exit 0
fi

new=0
while IFS='|' read -r user ip; do
  [ -z "${ip:-}" ] && continue
  grep -qxF "$ip" "$KNOWN" && continue
  [ "$DRY" = "1" ] || echo "$ip" >> "$KNOWN"
  new=$((new+1))
  failed=$(auth_lines "-24 hours" | grep -cE "^Failed " || true)
  notify warn "SSH login from NEW IP $ip on $HOST_ID" \
    "user: $user
ip: $ip
failed attempts (24h): $failed
If this is you from a new location, no action: the IP is now known. If not: rotate keys, check authorized_keys, review the auth log." \
    "ssh-auth:$HOST_ID:$ip" || echo "notify failed for $ip"
  echo "$(now_iso) NEW-IP $user@$ip"
done < <(logins "$WINDOW")

echo "checked: $new new IP(s)"
exit 0
