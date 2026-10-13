#!/usr/bin/env bash
# domain-expiry-watch.sh - daily check that no domain REGISTRATION lapses.
#
# TLS expiry is a different thing (see cert-expiry-watch.sh); a lapsed domain is
# a dead site plus a ransom negotiation with a squatter. Reduces the watched
# hostnames to registrable domains (last two labels; set REGISTRABLE_LABELS=3 for
# suffixes like co.uk), fetches expiry via RDAP (rdap.org, follows redirects) with
# a whois fallback ("Registry Expiry Date", and the "expires....: D.M.YYYY" form).
# Unparseable domains are listed in the run log, never alerted.
#
# Alerting: escalating buckets 30/14/7/3/expired. 30d and 14d alert once per
# bucket; 7d, 3d and expired re-alert on every run (daily cron = daily nag).
# When a domain is renewed, a "resolved" notice is sent. State in STATE.
# Needs GNU date (Linux), curl, jq; whois optional (fallback).
#
# Env:
#   DOMAINS / DOMAINS_FILE   hostnames to watch, see lib.sh
#   DOMAIN_WARN_DAYS      start alerting below this many days (default 30)
#   REGISTRABLE_LABELS    labels kept when reducing hostnames (default 2)
#   STATE                 state dir (default $STATE_DIR/domain-expiry)
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1                 print findings, send nothing, keep no state
#
# Example /etc/cron.d line (daily):
#   40 5 * * * root /usr/local/bin/cron-report.sh domain-expiry /usr/local/bin/domain-expiry-watch.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="domain-expiry"
DOMAIN_WARN_DAYS="${DOMAIN_WARN_DAYS:-30}"
LABELS="${REGISTRABLE_LABELS:-2}"
STATE="${STATE:-$STATE_DIR/domain-expiry}"
need_dir "$STATE"
now=$(date +%s)

domains=$(load_domains | awk -F. -v n="$LABELS" 'NF>=n { out=$(NF-n+1); for (i=NF-n+2;i<=NF;i++) out=out "." $i; print out }' | sort -u)
[ -n "$domains" ] || { echo "FATAL: empty domain list (set DOMAINS or DOMAINS_FILE)"; exit 1; }

expiry_for() { # $1=domain -> ISO date or ""
  local d="$1" exp w fi
  exp=$(curl -sL --max-time 20 "https://rdap.org/domain/$d" 2>/dev/null \
    | jq -r '.events[]? | select(.eventAction=="expiration") | .eventDate' 2>/dev/null | head -1)
  if [ -z "$exp" ] || [ "$exp" = "null" ]; then
    w=$(whois "$d" 2>/dev/null)
    # Extract the ISO date TOKEN, never a greedy `sed 's/.*: *//'`: that eats the
    # colons inside the time ("2027-05-02T17:50:18Z" -> "18Z"), which GNU date then
    # parses as TODAY, giving a false "expires in 0d" alert on every run.
    exp=$(printf '%s' "$w" | grep -iE "^ *Registry Expiry Date:" | head -1 \
      | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:.]+Z?)?' | head -1)
    if [ -z "$exp" ]; then
      # "expires............: 25.11.2026 19:16:35" -> D.M.YYYY
      fi=$(printf '%s' "$w" | grep -iE "^expires" | head -1 | grep -oE '[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{4}')
      [ -n "$fi" ] && exp=$(echo "$fi" | awk -F. '{printf "%04d-%02d-%02d", $3, $2, $1}')
    fi
  fi
  # Sanity gate: must carry a 4-digit year or it goes to the UNPARSEABLE list
  # (logged, never alerted). Garbage in must not become "renew NOW" alerts out.
  case "$exp" in
    *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
    *) exp="" ;;
  esac
  printf '%s' "$exp"
}

checked=0 warned=0 unknown=""
for d in $domains; do
  exp=$(expiry_for "$d")
  if [ -z "$exp" ]; then unknown="$unknown $d"; sleep 2; continue; fi
  exp_epoch=$(date -d "$exp" +%s 2>/dev/null) || { unknown="$unknown $d"; sleep 2; continue; }
  days=$(( (exp_epoch - now) / 86400 ))
  checked=$((checked+1))
  prev=$(cat "$STATE/$d" 2>/dev/null || true)
  if [ "$days" -ge "$DOMAIN_WARN_DAYS" ]; then
    if [ -n "$prev" ]; then   # renewed (or never close): close the alert we opened
      notify resolved "$d renewed" "$d renewed, now ${days}d to expiry" "domain-expiry:$d" \
        && { [ "$DRY" = "1" ] || rm -f "$STATE/$d"; } && echo "RESOLVED $d (${days}d)"
    fi
    sleep 2; continue
  fi
  if   [ "$exp_epoch" -lt "$now" ]; then bucket=expired sev=error repeat=1
  elif [ "$days" -le 3 ];  then bucket=3d  sev=error repeat=1
  elif [ "$days" -le 7 ];  then bucket=7d  sev=error repeat=1
  elif [ "$days" -le 14 ]; then bucket=14d sev=warn  repeat=0
  else                          bucket=30d sev=warn  repeat=0
  fi
  if [ "$bucket" = expired ]; then
    title="$d registration EXPIRED on ${exp%%T*}, renew now (grace period, then anyone can take it)"
  else
    title="$d registration expires in ${days}d, renew at the registrar"
  fi
  warned=$((warned+1))
  echo "WARN $d ${bucket} (${days}d, $exp)"
  if [ "$prev" != "$bucket" ] || [ "$repeat" = 1 ]; then
    notify "$sev" "$title" "expires $exp (whois/RDAP, domain-expiry-watch)" "domain-expiry:$d:$bucket" \
      && { [ "$DRY" = "1" ] || echo "$bucket" > "$STATE/$d"; } \
      || echo "notify failed for $d"
  fi
  sleep 2
done
echo "$(now_iso) checked $checked domain(s), $warned expiring <${DOMAIN_WARN_DAYS}d${unknown:+, UNPARSEABLE:$unknown}"
exit 0
