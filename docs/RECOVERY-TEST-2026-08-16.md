# Recovery Test — 16 August 2026

This is the real recovery event that led to the standalone `ONLYOFFICE-STOP-Migration` tool.

It is recorded here so future users can distinguish a procedure that was actually exercised from one that merely looked plausible on paper.

## Environment

```text
ONLYOFFICE Community Server: 12.8.0.1971
MySQL:                       8.4.0
Community container:         onlyoffice-community-server
MySQL container:             onlyoffice-mysql-server
Database:                    onlyoffice
Tenant ID:                   1
Tenant alias:                localhost
```

## Initial condition

A storage migration had been started and needed to be abandoned.

Community Server was stopped first:

```bash
docker stop onlyoffice-community-server
```

The tenant was then queried directly from MySQL over TCP:

```sql
SELECT id,alias,status,statuschanged,last_modified
FROM tenants_tenants
WHERE id=1;
```

Observed state:

```text
id  alias      status  statuschanged         last_modified
1   localhost  5       2026-08-16 09:26:50   2026-08-16 09:26:50
```

This confirmed the expected stuck state:

```text
TenantStatus.Migrating = 5
```

## Tenant-row backup

Before changing SQL, the full recovery-relevant row was exported:

```sql
SELECT id,alias,mappeddomain,status,statuschanged,last_modified
FROM tenants_tenants
WHERE id=1;
```

Observed backup content:

```text
id  alias      mappeddomain  status  statuschanged         last_modified
1   localhost  NULL          5       2026-08-16 09:26:50   2026-08-16 09:26:50
```

The backup was stored as a timestamped TSV under `/root` with mode `0600`.

## Recovery SQL

With Community Server stopped, the following guarded update was executed:

```sql
UPDATE tenants_tenants
SET status = 0,
    statuschanged = UTC_TIMESTAMP(),
    last_modified = UTC_TIMESTAMP()
WHERE id = 1
  AND status = 5;

SELECT ROW_COUNT() AS rows_changed;
```

Observed result:

```text
rows_changed
1
```

Immediate verification:

```text
id  alias      status  statuschanged         last_modified
1   localhost  0       2026-08-16 10:31:42   2026-08-16 10:31:42
```

The important safety result was that **exactly one row changed**.

## Community Server restart

Community Server was then restarted:

```bash
docker start onlyoffice-community-server
```

It returned to a running state.

Post-start tenant verification showed:

```text
id  alias      status  statuschanged         last_modified
1   localhost  0       2026-08-16 10:31:42   2026-08-16 10:31:42
```

The tenant therefore remained `Active` after Community Server came back; it did not re-enter `Migrating`.

## Migration-process check

The live Community Server process table was checked for:

```text
svcStorageMigrate
StorageMigrate
```

The only matching lines in the first manual check were the check command's own shell/grep processes. No actual storage-migration worker was present.

The standalone script uses a cleaner `pgrep`-based check to avoid mistaking its own grep command for the migration worker.

## Result

Recovery succeeded:

```text
Community Server       running
Tenant                 Active (0)
Storage migration      stopped
Tenant row changed     exactly one
Original storage       not modified by recovery
Storage settings       not modified by recovery
MySQL restore          not required
```

## Additional observation

During the manual test, the MySQL container's displayed uptime reset shortly after Community Server was restarted. MySQL nevertheless came back successfully and the subsequent tenant query returned the correct `Active` state.

That observation is not treated as part of the recovery mechanism; it is simply retained as an audit note from the test environment.

## Lessons incorporated into the script

The production recovery script therefore:

- stops Community Server before SQL modification;
- uses MySQL TCP on `127.0.0.1:3306`;
- backs up the tenant row first;
- discovers the one stuck tenant instead of hard-coding ID `1`;
- requires exactly one `status = 5` tenant;
- re-checks the tenant after Community has stopped;
- requires `ROW_COUNT() = 1`;
- verifies status `0` both before and after restart;
- checks that no migration process remains;
- leaves storage configuration and data untouched.