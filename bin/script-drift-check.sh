#!/usr/bin/env bash
# script-drift-check.sh - are the hand-installed ops scripts the ones in git?
#
# Scripts get copied to servers by hand (by design: they must keep working when
# your tooling is down). The cost is drift: months-old copies nobody notices.
# A manifest pins, per installed copy, the sha256 of the repo version; this
# compares every listed host against it.
#
#   script-drift-check.sh                check every host (drift is reported via notify; exit 0
#                                        so cron-report does not double-alert; exit 1 only if broken)
#   script-drift-check.sh --regen        (in the repo) rewrite manifest shas from the
#                                        scripts next to it; run after editing a script,
#                                        commit, then install
#   script-drift-check.sh --verify-repo  (in the repo) exit 1 if a manifest sha no
#                                        longer matches its repo file (forgot --regen);
#                                        wire this into CI or a pre-commit hook
#
# Manifest line: <script> <sha256> <host-name>[,<host-name>...] <installed path>
# Host names are the names from HOSTS (see lib.sh). See scripts.manifest.example.
#
# Env:
#   MANIFEST     manifest path (default: scripts.manifest next to this script, else
#                /usr/local/share/ops-kit/scripts.manifest)
#   REPO_DIR     directory holding the repo copies of the scripts (default: this dir)
#   HOSTS        hosts to check, e.g. "web1=web1.example.com local"
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1        print findings, send nothing
# Prints "SUMMARY: ..." as its last line (picked up by cron-report.sh).
#
# Example /etc/cron.d line (daily, wrapped):
#   30 6 * * * root /usr/local/bin/cron-report.sh script-drift /usr/local/bin/script-drift-check.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="script-drift"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR="${REPO_DIR:-$HERE}"
MANIFEST="${MANIFEST:-}"
if [ -z "$MANIFEST" ]; then
  if [ -f "$HERE/scripts.manifest" ]; then MANIFEST="$HERE/scripts.manifest"
  else MANIFEST=/usr/local/share/ops-kit/scripts.manifest; fi
fi
if [ ! -f "$MANIFEST" ]; then
  msg="no manifest at $MANIFEST. Create one: cp scripts.manifest.example bin/scripts.manifest, run script-drift-check.sh --regen, then install it to /usr/local/share/ops-kit/scripts.manifest (see README)."
  echo "FAIL: $msg"
  [ "${1:-}" = "--regen" ] || [ "${1:-}" = "--verify-repo" ] || notify error "script-drift-check cannot run" "$msg" "script-drift:nomanifest" || true
  exit 1
fi

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

case "${1:-}" in
  --regen)
    tmp=$(mktemp)
    while read -r script oldsha boxes path; do
      case "$script" in ''|\#*) printf '%s %s %s %s\n' "$script" "$oldsha" "$boxes" "$path" | sed 's/ *$//' >> "$tmp"; continue ;; esac
      [ -f "$REPO_DIR/$script" ] || { echo "FAIL: $script listed but not in $REPO_DIR"; rm -f "$tmp"; exit 1; }
      printf '%s %s %s %s\n' "$script" "$(sha "$REPO_DIR/$script")" "$boxes" "$path" >> "$tmp"
    done < "$MANIFEST"
    mv "$tmp" "$MANIFEST"; echo "regenerated $MANIFEST"; exit 0 ;;
  --verify-repo)
    bad=0
    while read -r script want _boxes _path; do
      case "$script" in ''|\#*) continue ;; esac
      got=$(sha "$REPO_DIR/$script" 2>/dev/null)
      [ "$got" = "$want" ] || { echo "STALE MANIFEST: $script (repo $got != manifest $want), run --regen"; bad=1; }
    done < "$MANIFEST"
    [ "$bad" = 0 ] && echo "manifest matches repo"; exit "$bad" ;;
esac

parse_hosts
target_of() { local i; for i in "${!HOST_NAMES[@]}"; do [ "${HOST_NAMES[$i]}" = "$1" ] && { echo "${HOST_TARGETS[$i]}"; return; }; done; }

# Build one remote sha256sum call per host.
declare -A PATHS
while read -r script _want boxes path; do
  case "$script" in ''|\#*) continue ;; esac
  for b in ${boxes//,/ }; do PATHS[$b]="${PATHS[$b]:-} $path"; done
done < "$MANIFEST"

drift=0; checked=0; FINDINGS=""
finding() { echo "$1"; FINDINGS="${FINDINGS}  - $1
"; drift=$((drift+1)); }

for box in "${!PATHS[@]}"; do
  target=$(target_of "$box")
  [ -n "$target" ] || { finding "DRIFT: host '$box' is in the manifest but not in HOSTS"; continue; }
  cmd="for f in ${PATHS[$box]}; do if [ -f \"\$f\" ]; then sha256sum \"\$f\"; else echo \"MISSING \$f\"; fi; done"
  out=$(run_on "$target" "$cmd" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { finding "UNREACHABLE: $box ($target) rc=$rc: ${out:0:160}"; continue; }
  while read -r script want boxes path; do
    case "$script" in ''|\#*) continue ;; esac
    case ",$boxes," in *",$box,"*) ;; *) continue ;; esac
    checked=$((checked+1))
    got=$(printf '%s\n' "$out" | awk -v p="$path" '$2==p { print $1 }')
    if printf '%s\n' "$out" | grep -qxF "MISSING $path"; then
      finding "DRIFT: $box:$path is MISSING (expected $script)"
    elif [ "$got" != "$want" ]; then
      finding "DRIFT: $box:$path differs from repo $script (host ${got:0:12}, repo ${want:0:12}), reinstall from the repo"
    fi
  done < "$MANIFEST"
done

echo "SUMMARY: checked $checked installed script(s) across ${#PATHS[@]} host(s), drift=$drift"
if [ "$drift" -ne 0 ]; then
  notify warn "script drift: $drift finding(s)" "$FINDINGS" "script-drift" || true
  # exit 0: the finding is already reported via notify; non-zero would make
  # cron-report.sh send a second "cron failed" alert.
  exit 0
fi
exit 0
