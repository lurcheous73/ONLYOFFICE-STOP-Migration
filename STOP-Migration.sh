#!/usr/bin/env bash
set -euo pipefail

# STOP-Migration.sh
# Emergency ONLYOFFICE Workspace recovery for a tenant stuck in Migrating state.
#
# SAFE SCOPE:
# - Stops Community Server first.
# - Requires exactly one tenant with status=5 (Migrating).
# - Backs up that tenant row before changing anything.
# - Changes ONLY tenants_tenants status 5 -> 0 (Active), plus timestamps.
# - Does NOT alter storage settings, S3 settings, credentials, buckets or files.
# - Restarts Community Server and verifies final state.

COMMUNITY_C="${COMMUNITY_C:-onlyoffice-community-server}"
MYSQL_C="${MYSQL_C:-onlyoffice-mysql-server}"
DB_NAME="${DB_NAME:-onlyoffice}"
BACKUP_DIR="${BACKUP_DIR:-/root}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="${BACKUP_DIR}/tenant-before-stop-migration-${STAMP}.tsv"

say() { printf '%s\n' "$*"; }
die() { say; say "STOP: $*" >&2; exit 1; }

mysqlq() {
  docker exec "$MYSQL_C" sh -lc \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h 127.0.0.1 -P 3306 --connect-timeout=5 --batch --raw -N -uroot '"$DB_NAME" \
    <<<"$1"
}

mysql_table() {
  docker exec "$MYSQL_C" sh -lc \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h 127.0.0.1 -P 3306 --connect-timeout=5 --batch --raw -uroot '"$DB_NAME" \
    <<<"$1"
}

say "============================================================"
say " ONLYOFFICE — STOP MIGRATION"
say "============================================================"
say
say "Emergency recovery for a portal stuck at TenantStatus.Migrating (5)."
say "Storage settings and file data are NOT modified."
say

command -v docker >/dev/null 2>&1 || die "docker is not available."
docker inspect "$COMMUNITY_C" >/dev/null 2>&1 || die "Community container '$COMMUNITY_C' not found."
docker inspect "$MYSQL_C" >/dev/null 2>&1 || die "MySQL container '$MYSQL_C' not found."
[ "$(docker inspect -f '{{.State.Running}}' "$MYSQL_C")" = "true" ] || die "MySQL container is not running."

say "=== MYSQL CONNECTIVITY ==="
mysqlq 'SELECT 1;' >/dev/null || die "Cannot connect to MySQL on 127.0.0.1:3306."
say "PASS: MySQL reachable"
say

say "=== CURRENT TENANTS ==="
mysql_table '
SELECT id,alias,status,statuschanged,last_modified
FROM tenants_tenants
ORDER BY id;
'
say

COUNT="$(mysqlq 'SELECT COUNT(*) FROM tenants_tenants WHERE status=5;')"
say "Tenants in Migrating state: $COUNT"
[ "$COUNT" = "1" ] || die "expected exactly one Migrating tenant. No change made."

TENANT_ID="$(mysqlq 'SELECT id FROM tenants_tenants WHERE status=5 LIMIT 1;')"
TENANT_ALIAS="$(mysqlq "SELECT alias FROM tenants_tenants WHERE id=${TENANT_ID};")"
say "Tenant ID   : $TENANT_ID"
say "Tenant alias: $TENANT_ALIAS"
say

say "=== STOP COMMUNITY SERVER ==="
docker stop "$COMMUNITY_C" >/dev/null
[ "$(docker inspect -f '{{.State.Running}}' "$COMMUNITY_C")" = "false" ] || die "Community Server did not stop. No SQL change made."
say "PASS: Community Server stopped"
say

say "=== BACKUP TENANT ROW ==="
mkdir -p "$BACKUP_DIR"
mysql_table "
SELECT id,alias,mappeddomain,status,statuschanged,last_modified
FROM tenants_tenants
WHERE id=${TENANT_ID};
" >"$BACKUP"
chmod 600 "$BACKUP"
say "Backup: $BACKUP"
cat "$BACKUP"
say

# Re-check after Community has stopped, in case migration completed during shutdown.
STATUS_NOW="$(mysqlq "SELECT status FROM tenants_tenants WHERE id=${TENANT_ID};")"
if [ "$STATUS_NOW" != "5" ]; then
  say "Tenant is no longer status 5; current status is $STATUS_NOW."
  say "No SQL change made. Restarting Community Server."
  docker start "$COMMUNITY_C" >/dev/null || true
  exit 1
fi

say "=== RESET MIGRATING -> ACTIVE ==="
ROWS="$(mysqlq "
UPDATE tenants_tenants
SET status=0,
    statuschanged=UTC_TIMESTAMP(),
    last_modified=UTC_TIMESTAMP()
WHERE id=${TENANT_ID}
  AND status=5;
SELECT ROW_COUNT();
")"

if [ "$ROWS" != "1" ]; then
  say "Unexpected rows changed: '$ROWS'"
  say "Community Server remains stopped for manual inspection."
  die "SQL update was not exactly one row."
fi

say "PASS: changed exactly one tenant row"
say

say "=== VERIFY BEFORE START ==="
FINAL_BEFORE="$(mysqlq "SELECT status FROM tenants_tenants WHERE id=${TENANT_ID};")"
[ "$FINAL_BEFORE" = "0" ] || die "tenant did not become Active. Community remains stopped."
mysql_table "
SELECT id,alias,status,statuschanged,last_modified
FROM tenants_tenants
WHERE id=${TENANT_ID};
"
say

say "=== START COMMUNITY SERVER ==="
docker start "$COMMUNITY_C" >/dev/null
say "PASS: Community Server start requested"
say

say "=== WAIT FOR CONTAINER ==="
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Running}}' "$COMMUNITY_C")" = "true" ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Running}}' "$COMMUNITY_C")" = "true" ] || die "Community Server did not remain running."
say "PASS: Community Server running"
say

say "=== FINAL TENANT STATUS ==="
FINAL="$(mysqlq "SELECT status FROM tenants_tenants WHERE id=${TENANT_ID};")"
mysql_table "
SELECT id,alias,status,statuschanged,last_modified
FROM tenants_tenants
WHERE id=${TENANT_ID};
"
[ "$FINAL" = "0" ] || die "tenant is not Active after restart."
say

say "=== MIGRATION PROCESS CHECK ==="
TMP="/tmp/stop-migration-processes.$$"
if docker exec "$COMMUNITY_C" sh -lc \
  'pgrep -af "svcStorageMigrate|ASC.Data.Storage.Migration" | grep -v "pgrep -af"' \
  >"$TMP" 2>/dev/null; then
  cat "$TMP"
  rm -f "$TMP"
  die "a storage migration process still appears to be running."
else
  rm -f "$TMP"
  say "PASS: no storage migration process detected"
fi

say
say "============================================================"
say " RECOVERY COMPLETE"
say "============================================================"
say "Tenant ${TENANT_ID} (${TENANT_ALIAS}) is Active."
say "Tenant-row backup: $BACKUP"
say "No storage settings or file data were changed by this script."
