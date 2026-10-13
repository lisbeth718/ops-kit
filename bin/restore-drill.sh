#!/usr/bin/env bash
# restore-drill.sh - monthly proof that a Postgres backup actually restores.
#
# A backup that has never been restored is a hope, not a backup: the file
# format, the passphrase, and the object's integrity are all unproven until
# something reads the dump back into a real postgres. This picks one app per
# month (deterministic rotation), takes its latest dump, verifies the recorded
# sha256 (if a sidecar file exists), decrypts + gunzips + restores it into a
# scratch pgvector container, and sanity-checks table and row counts.
#
# Backup layout expected under BACKUP_DIR:
#   <BACKUP_DIR>/<app>/<file>        newest file per <app> directory is the candidate
#   file kinds:  *.sql   *.sql.gz   *.sql.enc  (enc = gzip, then
#                openssl enc -aes-256-cbc -pbkdf2, passphrase in PASSPHRASE_FILE)
#   optional:    <file>.sha256       first field = expected sha256 of <file>
# Fetch remote backups (S3, rclone, rsync, ...) into BACKUP_DIR beforehand.
#
# Reporting: success sends an info notice; any failure sends a warn and exits 1
# (so a cron-report wrapper also flags it). Dumps larger than MAX_GB are skipped
# (logged) and the rotation advances, so the drill never silently no-ops.
# Restore errors for missing ROLES (ownership/GRANT lines naming the app's own DB
# roles, absent from the scratch DB) are benign and counted separately; any other
# SQL error means part of the dump did not restore and fails the drill.
#
# Pass an app name to override the rotation:  restore-drill.sh <app>
#
# Env:
#   BACKUP_DIR        root of the dumps (default /var/backups/db)
#   PASSPHRASE_FILE   file holding the openssl passphrase (needed for *.sql.enc)
#   MAX_GB            skip dumps bigger than this (default 5)
#   SCRATCH_IMG       scratch postgres image (default pgvector/pgvector:pg17, which
#                     restores plain-pg and pgvector dumps)
#   SCRATCH_NAME      scratch container name (default ops-restore-drill)
#   WORK              scratch dir on disk (default /var/tmp/restore-drill)
#   ALERT_WEBHOOK_URL / ALERT_WEBHOOK_TOKEN   see notify.sh
#   DRY=1             print what would be reported (the drill itself still runs)
#
# Example /etc/cron.d line (monthly, 3rd at 04:30):
#   30 4 3 * * root /usr/local/bin/cron-report.sh restore-drill /usr/local/bin/restore-drill.sh
set -uo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SOURCE="restore-drill"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/db}"
PASSPHRASE_FILE="${PASSPHRASE_FILE:-}"
MAX_GB="${MAX_GB:-5}"
SCRATCH_IMG="${SCRATCH_IMG:-pgvector/pgvector:pg17}"
SCRATCH_NAME="${SCRATCH_NAME:-ops-restore-drill}"
WORK="${WORK:-/var/tmp/restore-drill}"
FP="restore-drill:$(date +%Y%m)"

cleanup() {
  docker rm -f "$SCRATCH_NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { # message
  echo "FAIL: $1"
  notify warn "restore drill FAILED: ${APP:-<no candidate>}" "$1" "$FP" || true
  exit 1
}

[ -d "$BACKUP_DIR" ] || fail "BACKUP_DIR $BACKUP_DIR does not exist"

# ── candidates: newest dump per app directory ──
CANDIDATES=""
for dir in "$BACKUP_DIR"/*/; do
  [ -d "$dir" ] || continue
  app=$(basename "$dir")
  # newest by mtime; ls -t is fine for dump files (no newlines in names)
  # shellcheck disable=SC2012
  f=$(ls -t "$dir"*.sql "$dir"*.sql.gz "$dir"*.sql.enc 2>/dev/null | head -1)
  [ -n "$f" ] || continue
  CANDIDATES="${CANDIDATES}${app}|${f}|$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")
"
done
CANDIDATES=$(printf '%s' "$CANDIDATES" | sort)
[ -n "$CANDIDATES" ] || fail "no drillable dumps found under $BACKUP_DIR"

if [ -n "${1:-}" ]; then
  PICKED=$(printf '%s\n' "$CANDIDATES" | awk -F'|' -v a="$1" '$1==a')
  [ -n "$PICKED" ] || fail "no dump found for requested app '$1'"
else
  # Deterministic monthly rotation, skipping too-big dumps (logged).
  N=$(printf '%s\n' "$CANDIDATES" | wc -l | tr -d ' ')
  IDX=$(( (10#$(date +%Y%m)) % N ))
  PICKED=""
  for i in $(seq 0 $((N-1))); do
    ROW=$(printf '%s\n' "$CANDIDATES" | sed -n "$(( (IDX+i) % N + 1 ))p")
    SZ=$(printf '%s' "$ROW" | cut -d'|' -f3)
    if [ -n "$SZ" ] && [ "$SZ" -gt $((MAX_GB*1024*1024*1024)) ]; then
      echo "skip (>${MAX_GB}GB): $(printf '%s' "$ROW" | cut -d'|' -f1) ($((SZ/1024/1024/1024))GB)"
      continue
    fi
    PICKED="$ROW"; break
  done
  [ -n "$PICKED" ] || fail "every candidate exceeded the ${MAX_GB}GB cap"
fi

APP=$(printf '%s' "$PICKED" | cut -d'|' -f1)
FILE=$(printf '%s' "$PICKED" | cut -d'|' -f2)
SZ=$(printf '%s' "$PICKED" | cut -d'|' -f3)
echo "-- drilling: $APP (${SZ:+$((SZ/1024/1024))MB}, file=$FILE) --"

# Disk guard: the scratch DB grows inside docker's volume.
mkdir -p "$WORK" && chmod 700 "$WORK"
FREE_KB=$(df -Pk "$WORK" | awk 'NR==2{print $4}')
NEED_KB=$(( ${SZ:-0}/1024 * 2 + 2097152 ))
[ "$FREE_KB" -gt "$NEED_KB" ] || fail "not enough disk for drill: need ~$((NEED_KB/1024))MB, have $((FREE_KB/1024))MB"

# ── integrity: sidecar sha256 must match ──
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
if [ -f "$FILE.sha256" ]; then
  WANT=$(awk '{print $1; exit}' "$FILE.sha256")
  GOT=$(sha "$FILE")
  [ "$GOT" = "$WANT" ] || fail "sha256 MISMATCH for $FILE: recorded=$WANT got=$GOT (corrupt file or wrong sidecar)"
  echo "sha256 verified"
  SHA_STATE="sha256 verified"
else
  echo "no $FILE.sha256 sidecar, skipping integrity check"
  SHA_STATE="no sha256 sidecar (integrity unchecked)"
fi

# ── scratch postgres ──
docker rm -f "$SCRATCH_NAME" >/dev/null 2>&1 || true
docker run -d --name "$SCRATCH_NAME" -e POSTGRES_PASSWORD=drill -e POSTGRES_DB=drill \
  --memory=1g "$SCRATCH_IMG" >/dev/null || fail "could not start scratch postgres"
for i in $(seq 1 30); do
  docker exec "$SCRATCH_NAME" pg_isready -U postgres >/dev/null 2>&1 && break
  [ "$i" = "30" ] && fail "scratch postgres never became ready"
  sleep 2
done

# ── decode -> restore (streamed; plaintext never hits disk) ──
case "$FILE" in
  *.sql.enc)
    [ -r "$PASSPHRASE_FILE" ] || fail "$FILE is encrypted but PASSPHRASE_FILE is unset/unreadable"
    DECODE=(openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$PASSPHRASE_FILE" -in "$FILE")
    GUNZIP=(gunzip) ;;
  *.sql.gz) DECODE=(cat "$FILE"); GUNZIP=(gunzip) ;;
  *)        DECODE=(cat "$FILE"); GUNZIP=(cat) ;;
esac
if ! "${DECODE[@]}" 2>"$WORK/dec.err" \
    | "${GUNZIP[@]}" 2>"$WORK/gz.err" \
    | docker exec -i "$SCRATCH_NAME" psql -q -U postgres -d drill >"$WORK/restore.log" 2>&1; then
  fail "decode/restore pipeline failed: dec=$(head -c 120 "$WORK/dec.err") gz=$(head -c 120 "$WORK/gz.err") psql=$(tail -c 200 "$WORK/restore.log")"
fi
PSQL_ERRS=$(grep -c '^ERROR' "$WORK/restore.log" 2>/dev/null || true)
ROLE_ERRS=$(grep -cE '^ERROR:  role ".*" does not exist' "$WORK/restore.log" 2>/dev/null || true)
REAL_ERRS=$(( ${PSQL_ERRS:-0} - ${ROLE_ERRS:-0} ))
[ "$REAL_ERRS" -lt 0 ] && REAL_ERRS=0
ERR_STATE="psql errors: $REAL_ERRS"
[ "${ROLE_ERRS:-0}" -gt 0 ] && ERR_STATE="$ERR_STATE (+$ROLE_ERRS benign: grants for roles absent from the scratch DB)"

if [ "$REAL_ERRS" -gt 0 ]; then
  FIRST=$(grep '^ERROR' "$WORK/restore.log" | grep -vE '^ERROR:  role ".*" does not exist' | head -3 | cut -c1-160 | tr '\n' ' ')
  fail "restore hit $REAL_ERRS real SQL error(s): $FIRST"
fi

# ── verify: the restored DB must actually contain the app's data ──
TABLES=$(docker exec "$SCRATCH_NAME" psql -U postgres -d drill -tA -c \
  "select count(*) from information_schema.tables where table_schema='public'")
[ -n "$TABLES" ] && [ "$TABLES" -gt 0 ] || fail "restore produced 0 tables"
# Fresh restore = no planner stats; without ANALYZE reltuples is 0/-1 everywhere
# and "largest table" is arbitrary.
docker exec "$SCRATCH_NAME" psql -q -U postgres -d drill -c "analyze" >/dev/null 2>&1 || true
TOPTBL=$(docker exec "$SCRATCH_NAME" psql -U postgres -d drill -tA -c \
  "select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind='r' order by c.reltuples desc limit 1")
ROWS=$(docker exec "$SCRATCH_NAME" psql -U postgres -d drill -tA -c \
  "select count(*) from \"${TOPTBL}\"" 2>/dev/null || echo "?")
case "$ROWS" in
  ''|'?'|0) fail "restored DB's largest table (${TOPTBL:-none}) has ${ROWS:-no} rows, the data did not come back" ;;
esac

MSG="$APP: $TABLES tables restored; largest ($TOPTBL) has $ROWS rows; $ERR_STATE; $SHA_STATE"
echo "-- DRILL OK: $MSG --"
echo "SUMMARY: $MSG"
# The drill passed, but an unreported pass is invisible: fail the run so a
# cron-report wrapper surfaces the reporting break.
notify info "restore drill OK: $APP" "$MSG" "$FP" || exit 1
exit 0
