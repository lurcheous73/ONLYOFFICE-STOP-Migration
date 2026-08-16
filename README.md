# ONLYOFFICE STOP Migration

Emergency recovery tool for an ONLYOFFICE Workspace / Community Server tenant left stuck in **`Migrating`** state after a storage migration is aborted or fails.

This repository exists for one deliberately narrow job: **stop the Community Server migration worker, preserve the current storage configuration and file data, reset the stuck tenant state from `Migrating` to `Active`, and verify that migration does not resume.**

> [!CAUTION]
> This is a recovery tool, not a general migration manager. Read the safety conditions below before using it. It intentionally refuses to act unless it sees the expected failure state.

## What problem does this solve?

ONLYOFFICE Community Server marks the tenant as `Migrating` while a storage migration is running. In the Community Server source, the relevant tenant status values are:

- `Active = 0`
- `Migrating = 5`

If a storage migration is interrupted or fails, the portal can remain stuck at status `5` even when the desired recovery is simply to keep using the original storage.

The recovery procedure proven on **16 August 2026** was:

1. Stop `onlyoffice-community-server` so the migration worker cannot continue.
2. Confirm exactly one tenant is still `status = 5`.
3. Back up the tenant row.
4. Change only that tenant's status from `5` to `0`, refreshing its timestamps.
5. Restart Community Server.
6. Confirm the tenant remains `Active` and no storage-migration process is running.

## Why stopping Community Server first matters

ONLYOFFICE's `StorageUploader` runs migration work as a long-running task. The public `Stop()` method calls `CancellationTokenSource.Cancel()`, but the migration copy loop itself does not visibly test that token while iterating files.

For emergency recovery, stopping the Community Server container first is therefore the conservative option: it removes the running migration process before changing the SQL status flag.

The current upstream implementation also shows that migration copies files from the old storage into the new storage, then only after the copy loop completes calls `settings.Save()` and returns the tenant to `Active`.

Upstream references used when building this recovery method:

- [ONLYOFFICE CommunityServer — StorageUploader.cs](https://github.com/ONLYOFFICE/CommunityServer/blob/fe1fa7babd093969e939ba6ff45a9fee1299dc93/common/ASC.Data.Storage/StorageUploader.cs)
- [ONLYOFFICE CommunityServer — TenantStatus.cs](https://github.com/ONLYOFFICE/CommunityServer/blob/fe1fa7babd093969e939ba6ff45a9fee1299dc93/common/ASC.Core.Common/Tenants/TenantStatus.cs)
- [ONLYOFFICE CommunityServer — SettingsApi.cs](https://github.com/ONLYOFFICE/CommunityServer/blob/fe1fa7babd093969e939ba6ff45a9fee1299dc93/module/ASC.Api/ASC.Api.Settings/SettingsApi.cs)

## What the script changes

`STOP-Migration.sh` changes only the stuck tenant row in `tenants_tenants`:

```sql
UPDATE tenants_tenants
SET status = 0,
    statuschanged = UTC_TIMESTAMP(),
    last_modified = UTC_TIMESTAMP()
WHERE id = <stuck tenant id>
  AND status = 5;
```

Before doing so it saves the tenant row to a timestamped TSV file under `/root` by default.

## What the script does **not** change

It does **not**:

- alter ONLYOFFICE storage settings;
- alter S3/S3-compatible credentials;
- create or delete buckets;
- delete the old/original file store;
- delete a partial destination copy;
- restore or rebuild MySQL;
- modify Document Server, Mail Server or Elasticsearch data;
- attempt to complete the failed migration.

That narrow scope is intentional.

## Requirements

Default/tested container names:

```text
onlyoffice-community-server
onlyoffice-mysql-server
```

Default database:

```text
onlyoffice
```

The MySQL container must expose the normal `MYSQL_ROOT_PASSWORD` environment variable internally. The script connects to MySQL over `127.0.0.1:3306` inside the MySQL container rather than depending on its Unix socket.

Tested recovery environment on 16 August 2026:

- ONLYOFFICE Community Server `12.8.0.1971`
- MySQL `8.4.0`
- Docker deployment
- single tenant, ID `1`, alias `localhost`

The script does **not** hard-code tenant ID `1`; it discovers the single tenant in status `5`.

## Use

Clone the repository on the ONLYOFFICE Docker host:

```bash
git clone https://github.com/lurcheous73/ONLYOFFICE-STOP-Migration.git
cd ONLYOFFICE-STOP-Migration
chmod 700 STOP-Migration.sh
```

Then run as root:

```bash
./STOP-Migration.sh
```

The script will stop rather than make a SQL change if:

- Docker is unavailable;
- either required container is missing;
- MySQL is not running or cannot be reached;
- there is not **exactly one** tenant in status `5`;
- Community Server cannot be stopped;
- the tenant leaves status `5` during shutdown;
- the SQL update affects anything other than exactly one row;
- the tenant does not remain `Active` after restart;
- a migration process still appears to be running afterward.

## Environment overrides

If your deployment uses different names:

```bash
COMMUNITY_C=my-community-container \
MYSQL_C=my-mysql-container \
DB_NAME=onlyoffice \
BACKUP_DIR=/root \
./STOP-Migration.sh
```

## Manual verification

Before recovery, the expected failure signature is similar to:

```text
id  alias      status
1   localhost  5
```

After recovery:

```text
id  alias      status
1   localhost  0
```

To check manually:

```bash
docker exec onlyoffice-mysql-server sh -lc '
MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
  -h 127.0.0.1 -P 3306 \
  -uroot onlyoffice -e "
SELECT id,alias,status,statuschanged,last_modified
FROM tenants_tenants
ORDER BY id;
"
'
```

And to check for an active migration process:

```bash
docker exec onlyoffice-community-server sh -lc '
pgrep -af "svcStorageMigrate|ASC.Data.Storage.Migration" || \
  echo "PASS: no storage migration process"
'
```

## Important boundary condition

This procedure is intended for the case where the migration is being **aborted before successful cut-over** and the original storage is to remain authoritative.

If the migration completed far enough for the new storage configuration to have been committed (`settings.Save()`), simply changing tenant status is **not** a complete rollback. Storage configuration must then be inspected and recovered separately.

Do not delete either old or destination data until you have independently established which store is authoritative.

## Documentation

- [`docs/TECHNICAL-NOTES.md`](docs/TECHNICAL-NOTES.md) — why this works and the upstream-code basis.
- [`docs/RECOVERY-TEST-2026-08-16.md`](docs/RECOVERY-TEST-2026-08-16.md) — the real recovery sequence that proved the method.

---

This project is intentionally small. In an emergency, boring and predictable beats clever.