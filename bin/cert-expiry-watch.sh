#!/usr/bin/env bash
# cert-expiry-watch.sh - alert before a served TLS certificate lapses.
#
# Auto-renewing proxies (Caddy, certbot, ...) do their job until a renewal
# silently fails (rate limit, DNS hiccup, a domain dropped from the cert); then
# the cert expires and the site dies with no warning. This connects to every
# watched domain on :443 with SNI, reads the served leaf cert's notAfter, and
# alerts when fewer than WARN_DAYS remain (error below CRIT_DAYS). Hosts that do
# not answer TLS are skipped: that is an uptime probe's job.
# Needs GNU date (Linux) and openssl.
#
# Env:
#   DOMAINS / DOMAINS_FILE   what to check, see lib.sh
#   WARN_DAYS    warn below this many days left (default 14)
#   CRIT_DAYS    error below this many days left (default 3)
#   PARALLEL     concurrent checks (default 12)
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1        print findings, send nothing
#
# Example /etc/cron.d line (daily):
#   20 5 * * * root /usr/local/bin/cron-report.sh cert-expiry /usr/local/bin/cert-expiry-watch.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="cert-expiry"
WARN_DAYS="${WARN_DAYS:-14}"
CRIT_DAYS="${CRIT_DAYS:-3}"
PARALLEL="${PARALLEL:-12}"

HOSTS_TO_CHECK=$(load_domains)
[ -n "$HOSTS_TO_CHECK" ] || { echo "no domains configured (set DOMAINS or DOMAINS_FILE)"; exit 1; }

TMP=$(mktemp)
now=$(date +%s)
check_one() {
  local h="$1" end e days
  # served leaf cert's notAfter, via SNI. 8s cap so a dead host cannot stall.
  end=$(echo | timeout 8 openssl s_client -servername "$h" -connect "$h:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  [ -z "$end" ] && return
  e=$(date -d "$end" +%s 2>/dev/null) || return
  days=$(( (e - now) / 86400 ))
  [ "$days" -lt "$WARN_DAYS" ] && echo "$h|$days" >> "$TMP"
}

i=0
for h in $HOSTS_TO_CHECK; do
  check_one "$h" &
  i=$((i+1)); [ $((i % PARALLEL)) -eq 0 ] && wait
done
wait

EXPIRING=$(sort -t'|' -k2 -n "$TMP"); rm -f "$TMP"
if [ -z "$EXPIRING" ]; then
  echo "$(now_iso) cert-expiry-watch: all $(echo "$HOSTS_TO_CHECK" | grep -c .) certs > ${WARN_DAYS}d"
  exit 0
fi

sev="warn"
while IFS='|' read -r _h d; do [ "${d:-99}" -lt "$CRIT_DAYS" ] && sev="error"; done <<< "$EXPIRING"
LIST=$(printf '%s\n' "$EXPIRING" | awk -F'|' '{printf "  - %s: %s day(s) left%s\n", $1, $2, ($2<0?" (EXPIRED)":"")}')
echo "== certs expiring =="; printf '%s\n' "$LIST"

notify "$sev" "TLS cert(s) expiring soon" \
  "TLS certs about to lapse (a failed auto-renewal means a silent outage). Check renewal on the serving host:
$LIST" "cert-expiry" || echo "notify failed"
echo "$(now_iso) cert-expiry-watch: reported ($sev)"
exit 0
