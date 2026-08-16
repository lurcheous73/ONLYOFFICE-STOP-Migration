# Technical Notes

## Purpose

This document records the reasoning behind `STOP-Migration.sh` so the recovery procedure is auditable rather than a magic SQL incantation.

The procedure is intentionally designed for a narrow failure mode:

- an ONLYOFFICE storage migration has failed, been abandoned, or needs to be stopped;
- the tenant remains in `TenantStatus.Migrating`;
- the desired outcome is to keep the original storage authoritative;
- the storage cut-over must **not** be allowed to complete while SQL state is being repaired.

## Relevant upstream behaviour

The upstream ONLYOFFICE CommunityServer implementation examined for this recovery was commit:

```text
fe1fa7babd093969e939ba6ff45a9fee1299dc93
```

### Tenant status values

`common/ASC.Core.Common/Tenants/TenantStatus.cs` defines:

```csharp
Active = 0
...
Migrating = 5
```

Source:

https://github.com/ONLYOFFICE/CommunityServer/blob/fe1fa7babd093969e939ba6ff45a9fee1299dc93/common/ASC.Core.Common/Tenants/TenantStatus.cs

### How storage migration is started

The storage-migration API sets the tenant to `Migrating` and persists it before/while migration proceeds.

Source:

https://github.com/ONLYOFFICE/CommunityServer/blob/fe1fa7babd093969e939ba6ff45a9fee1299dc93/module/ASC.Api/ASC.Api.Settings/SettingsApi.cs

### How files are moved

`StorageUploader.cs` creates an `MigrateOperation` and runs it as a long-running task.

For each configured storage module, the migration operation obtains:

- the existing store via `StorageFactory.GetStorage(...)`;
- the proposed destination via `StorageFactory.GetStorageFromConsumer(...)`.

It then enumerates existing files and calls `CopyFile(...)` into the destination.

The important sequencing is:

1. obtain old store;
2. obtain destination store;
3. enumerate/copy files;
4. finish all module loops;
5. call `settings.Save()`;
6. set tenant status back to `Active`;
7. save the tenant.

Source:

https://github.com/ONLYOFFICE/CommunityServer/blob/fe1fa7babd093969e939ba6ff45a9fee1299dc93/common/ASC.Data.Storage/StorageUploader.cs

## Why the original storage is not deleted by this recovery

The migration loop inspected above performs destination copies. No deletion of the original/source files is present in that loop.

`STOP-Migration.sh` itself never calls an S3 API, filesystem delete command, ONLYOFFICE storage-setting endpoint, or bucket operation. It changes only the tenant state row after Community Server has been stopped.

This is why the procedure is suitable for the specific case where migration is being abandoned before the new storage configuration is committed.

## Why `docker stop` is used rather than the migration Stop API

The upstream `StorageUploader.Stop()` implementation is:

```csharp
TokenSource.Cancel();
```

The task is created with that token. However, in the inspected `MigrateOperation.DoJob()` copy loops there is no visible per-file or per-loop cancellation-token check.

That does **not** prove cancellation can never interrupt work elsewhere in the call stack, but it means an emergency recovery should not rely on cooperative cancellation being observed promptly by the running copy loop.

Stopping the Community Server container provides a much clearer safety boundary: the process hosting the migration worker is no longer running when the SQL state is changed.

## Database state

The relevant table is:

```text
tenants_tenants
```

The recovery changes:

```sql
status = 5
```

into:

```sql
status = 0
```

and updates:

```text
statuschanged
last_modified
```

The tenant row is exported before the update.

## Why the script connects over TCP

During the original recovery exercise, the MySQL container was alive but an earlier attempt encountered:

```text
ERROR 2002 (HY000): Can't connect to local MySQL server through socket '/var/run/mysqld/mysqld.sock'
```

The server was then confirmed reachable over:

```text
127.0.0.1:3306
```

Therefore the recovery script deliberately uses:

```bash
-h 127.0.0.1 -P 3306
```

inside the MySQL container rather than relying on the Unix socket path.

## Fail-closed checks

The script refuses to modify SQL unless all of the following are true:

1. Docker is available.
2. The named Community Server container exists.
3. The named MySQL container exists and is running.
4. MySQL responds over TCP.
5. Exactly one tenant has `status = 5`.
6. Community Server successfully stops.
7. The discovered tenant is still status `5` after shutdown.
8. The guarded SQL update changes exactly one row.
9. The tenant reads back as status `0` before Community Server is restarted.
10. Community Server remains running after restart.
11. The tenant still reads as status `0` afterward.
12. No matching migration process is detected after restart.

If the SQL update does not affect exactly one row, Community Server is intentionally left stopped for manual inspection.

## Critical boundary condition: `settings.Save()`

The clean abort model depends on stopping the migration before successful storage cut-over.

The inspected upstream code performs:

```text
copy files -> settings.Save() -> tenant Active
```

If `settings.Save()` has already succeeded, merely resetting tenant status is **not** a complete storage rollback. At that point the current storage configuration must be inspected and corrected independently.

Therefore:

- do not assume `status = 5` alone proves the old storage configuration is still selected;
- do not delete the original store;
- do not delete the destination copy until authority is established;
- if there is evidence that the migration completed/cut over, stop and inspect configuration before using this recovery method as a full rollback.

## Tested deployment

The procedure was proven on 16 August 2026 with:

```text
Community Server: onlyoffice/communityserver:12.8.0.1971
MySQL:            mysql:8.4.0
Community name:   onlyoffice-community-server
MySQL name:       onlyoffice-mysql-server
Database:         onlyoffice
Tenant:           id 1 / alias localhost
```

The recovery script nevertheless discovers the tenant ID dynamically and allows container/database names to be overridden with environment variables.

## Scope of confidence

The procedure is well-grounded for the tested Community Server generation and the upstream implementation cited above.

Future ONLYOFFICE releases may change:

- tenant-state values;
- table/column names;
- migration execution architecture;
- storage commit sequencing;
- container layout.

Before using the script on a materially different release, compare the current upstream source with the assumptions documented here.