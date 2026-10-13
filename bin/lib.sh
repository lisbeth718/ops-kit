#!/usr/bin/env bash
# lib.sh - shared helpers for ops-kit scripts. Source it, do not run it.
#
# Provides: config loading, notify(), host list parsing (HOSTS / HOSTS_FILE),
# run_on / probe_host (local or over ssh, with one retry), coverage_check,
# load_domains (DOMAINS / DOMAINS_FILE), rvars (pass vars into remote scripts).
#
# Env:
#   OPS_KIT_CONFIG   config file of KEY=VALUE lines (default /etc/ops-kit.env).
#                    Real environment variables always win over the file.
#   HOSTS            space separated "name=target" entries; "local" runs on this
#                    machine (default: local). Example: "web1=web1.example.com local"
#   HOSTS_FILE       optional file, one "name target" per line (# comments ok)
#   SSH_USER         ssh user for remote targets (default root)
#   SSH_OPTS         extra ssh options (default: BatchMode, 15s timeout)
#   DOMAINS          space separated domains/hostnames to watch
#   DOMAINS_FILE     optional file, one domain per line (# comments ok)
#   STATE_DIR        persistent state root (default /var/lib/ops-kit)
#   RUN_DIR          volatile state root (default /run/ops-kit)

OPS_KIT_DIR="${OPS_KIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export OPS_KIT_DIR

load_config() { # only sets variables that are not already in the environment
  local f="$1" line k v
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    v="${v#"${v%%[![:space:]]*}"}"   # trim leading whitespace
    case "$v" in
      \"*\"*) v=${v#\"}; v=${v%%\"*}   ;;                 # double-quoted: keep as is
      \'*\'*) v=${v#\'}; v=${v%%\'*}   ;;                 # single-quoted: keep as is
      *) v=${v%%[[:space:]]#*}                           # strip trailing " # comment"
         v="${v%"${v##*[![:space:]]}"}" ;;                # trim trailing whitespace
    esac
    [ -n "${!k+x}" ] || export "$k=$v"
  done < "$f"
}
load_config "${OPS_KIT_CONFIG:-/etc/ops-kit.env}"

DRY="${DRY:-0}"
SSH_USER="${SSH_USER:-root}"
SSH_OPTS="${SSH_OPTS:--o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"
STATE_DIR="${STATE_DIR:-/var/lib/ops-kit}"
RUN_DIR="${RUN_DIR:-/run/ops-kit}"
NOTIFY="${NOTIFY:-$OPS_KIT_DIR/notify.sh}"
[ -x "$NOTIFY" ] || NOTIFY=$(command -v notify.sh || echo "$OPS_KIT_DIR/notify.sh")

now_iso() { date -u +%FT%TZ; }

# notify <severity> <title> [body] [fingerprint]   ($SOURCE names the script)
notify() {
  NOTIFY_SOURCE="${SOURCE:-ops-kit}" NOTIFY_FINGERPRINT="${4:-}" "$NOTIFY" "$1" "$2" "${3:-}"
}

# need_dir <path>: create a state dir; fatal unless DRY=1
need_dir() {
  mkdir -p "$1" 2>/dev/null && return 0
  [ "$DRY" = "1" ] && return 0
  echo "FATAL: cannot create $1 (set STATE_DIR / RUN_DIR to a writable path)" >&2
  exit 1
}

HOST_NAMES=(); HOST_TARGETS=()
parse_hosts() {
  local spec="${HOSTS:-}" e
  if [ -n "${HOSTS_FILE:-}" ] && [ -r "$HOSTS_FILE" ]; then
    spec="$spec $(awk '!/^[[:space:]]*(#|$)/ {print $1 "=" ($2 ? $2 : $1)}' "$HOSTS_FILE" | tr '\n' ' ')"
  fi
  [ -n "${spec// /}" ] || spec="local"
  HOST_NAMES=(); HOST_TARGETS=()
  for e in $spec; do
    case "$e" in
      *=*) HOST_NAMES+=("${e%%=*}"); HOST_TARGETS+=("${e#*=}") ;;
      *)   HOST_NAMES+=("$e");       HOST_TARGETS+=("$e") ;;
    esac
  done
}

# run_on <target> <script>: run a bash script locally or over ssh
run_on() {
  if [ "$1" = "local" ]; then
    bash -c "$2"
  else
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@$1" bash -s <<< "$2"
  fi
}

# probe_host <target> <script>: like run_on, but proves the probe actually ran by
# checking a sentinel, and retries a remote host once (a lone ssh reset must not
# drop a host from coverage). Prints the script output without the sentinel.
# Returns 1 if the probe never ran.
probe_host() {
  local out try
  for try in 1 2; do
    out=$(run_on "$1" "echo __probed__
$2" 2>/dev/null)
    case "$out" in
      *__probed__*) printf '%s\n' "$out" | grep -v '^__probed__$'; return 0 ;;
    esac
    [ "$1" = "local" ] && break
    [ "$try" = 1 ] && sleep 3
  done
  return 1
}

# rvars VAR...: emit shell assignments so a remote script can see local vars
rvars() { local v; for v in "$@"; do printf '%s=%q\n' "$v" "${!v-}"; done; }

# coverage_check <expected> <probed> <missed-names>
# A fleet watch that silently probes fewer hosts than exist reports "all clear"
# while blind. Say so loudly.
coverage_check() {
  if [ "$1" -gt 0 ] && [ "$2" -lt "$1" ]; then
    echo "COVERAGE DEGRADED: probed $2/$1 hosts"
    notify error "${SOURCE:-watch} is BLIND to some hosts" \
      "Only probed $2/$1 hosts. Unreachable after 1 retry: ${3:-?}. Persistent means that host's sshd or network; a transient scanner flood survives the retry." \
      "${SOURCE:-watch}:coverage"
  fi
  return 0
}

# load_domains: one domain per line from DOMAINS and DOMAINS_FILE (sorted, unique)
load_domains() {
  {
    # shellcheck disable=SC2086
    printf '%s\n' ${DOMAINS:-}
    if [ -n "${DOMAINS_FILE:-}" ] && [ -r "$DOMAINS_FILE" ]; then
      grep -vE '^[[:space:]]*(#|$)' "$DOMAINS_FILE"
    fi
  } | awk 'NF {print $1}' | sort -u
}
