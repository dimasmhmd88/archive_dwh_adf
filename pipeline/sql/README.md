# SQL database objects – schema `ret` (v0.6)

| Item | Value |
|---|---|
| Script version | 0.6 – **Draft, not reviewed, not executed against any database** |
| Date | 11 November 2026 |
| Reference | FSD_DWH_Data_Retention_v1.1 (FSD-DWH-RET v1.1, 10 Nov 2026, *Draft for Review*, not approved). Also the decisions D-1..D-4 of the review "pipeline-agus vs FSD v1.1" (11 Nov 2026), given by the user. |
| Target | Azure SQL Database, DWH database, schema `ret`, compatibility level ≥ 130 |
| Used by | `pipeline-agus/` (linked services `Agus_*`) and `pipeline/` (linked services `LS_RET_*`). Both are generated from the same contract (`tools/sql_contract.json`). |

## Changes in v0.6 (alignment with FSD v1.1)

| Topic | FSD | Change |
|---|---|---|
| Archive layout | MD-07, 3.4, 4.7, 8 | `<container>/<yyyy>/<BlobPath>/<BlobPath>_<yyyyMMdd>.parquet`, BlobPath = `<schema>.<table>` in lower case without slash, container `dwh-archive`. The RunId is no longer in the file name; it is recorded in `ret.RetentionArchiveDate`. |
| Existing archive file | 4.17, decision **D-1** | `usp_IdentifyEligibleData` refuses a business date that may already have a file from an earlier run. The table gets **ERR-EXP-02** and ends FAILED; nothing is exported or deleted. Manual handling. |
| Failed-run cleanup | 4.18 | New procedure `usp_GetRunArchiveFiles`; `PL_RET_03F` deletes exactly those files. |
| Archive expiry | 4.13 | `usp_GetExpiredArchiveFolders` has levels **YEAR** (container root) and **FILE** (cut-off year). |
| Log retention | MD-08, 4.24 | Column `LogRetentionYears` (default 3). `usp_EndTable` and `usp_EndRun` delete old log rows in the Daily Routine (internal procedures `usp_PurgeTableLogs`, `usp_PurgeRunLogs`). |
| Monitoring | 4.15, 11.3 | Views `ret.vw_MQ01_LatestRuns` … `ret.vw_MQ06_LocksAndRebuildTables`. |
| Dry validation | 4.2, 4.11, decision **D-3** | VALIDATION with an empty list means all active tables that are not COMPLETED. A VALIDATION run never drops leftover rebuild tables; they are only reported. |
| Migration v0.5 → v0.6 | – | Adds `LogRetentionYears`. BlobPath values with a slash are converted automatically for tables that have no archive files yet. |

**Addition not covered by FSD v1.1 (FSD update needed):** log retention keeps the archive-inventory rows of files that are not yet expired. The D-1 check needs these rows. The FSD 4.24 "rows still needed" list does not include them yet.

## Files

| File | Content | Deploy? |
|---|---|---|
| `DWH_Retention_DB_Objects_v0.6.sql` | Complete consolidated script (sections 0–14) | Yes – the whole file, **or** deploy/01–05 |
| `deploy/01_schema_tables.sql` | Schema, 10 tables, migration blocks (v0.2 / v0.3 / v0.5) | 1 |
| `deploy/02_triggers_seed.sql` | 3 triggers, parameter row, 30 error codes | 2 |
| `deploy/03_functions.sql` | 9 functions | 3 |
| `deploy/04_procedures.sql` | 32 stored procedures | 4 |
| `deploy/05_monitoring_views.sql` | 6 monitoring views | 5 |
| `deploy/06_reference_examples_monitoring.sql` | Examples and queries, all commented out | No (reference) |
| `deploy/07_security_roles_TEMPLATE.sql` | Roles and GRANTs, commented out, with placeholders | After DBA review |
| `config/00_insert_default_config.sql` | **v0.1:** explicit defaults of all configuration tables: `RetentionParameter` (batch 10,000 / 3 s, window 21:00–05:00, NULL-check FULL, container `dwh-archive`; optional reset), 30 error codes, missing `RetentionTableStatus` rows | Before `10_…` |
| `config/10_insert_retention_config.sql` | **v0.2:** the 31 phase-1 tables of FSD App. A.1, BlobPath `schema.table`, ArchiveContainer `dwh-archive`; all other rows set inactive | After step 3 below |

The v0.5 files (`DWH_Retention_DB_Objects_v0.5.sql`, `…_v0.5_patch.sql`) are replaced by v0.6 and remain in the Git history. v0.6 can be run over a v0.5 / v0.5.1 database: the migration blocks and `CREATE OR ALTER` update it.

## Object inventory

| Object type | Count | Names |
|---|---|---|
| Tables | 10 | RetentionErrorCode, RetentionParameter, RetentionConfig (+ LogRetentionYears), RetentionParentKey, RetentionRunLog, RetentionTableStatus, RetentionTableLock, RetentionTableLog, RetentionArchiveDate, RetentionStepLog |
| Triggers | 3 | – |
| Functions | 9 | `fn_ArchiveFolderPath` / `fn_ArchiveFileName` now have the signature `(@BlobPath, @BusinessDate)` |
| Procedures | 32 | – |
| Views | 6 | MQ-01 to MQ-06 |

New procedures in v0.6 (the other 29 are as in v0.5):

| Procedure | Called by |
|---|---|
| `usp_GetRunArchiveFiles` | ADF (PL_RET_03F) |
| `usp_PurgeTableLogs` | Internal, from `usp_EndTable` |
| `usp_PurgeRunLogs` | Internal, from `usp_EndRun` |

## Deployment steps (development database first)

1. Connect to the **DWH database**.
2. Run `DWH_Retention_DB_Objects_v0.6.sql`, or `deploy/01` → `02` → `03` → `04` → `05` in that order.
3. With the DBA, adapt `deploy/07_security_roles_TEMPLATE.sql`. The ADF connection user goes into `ret_adf_executor`. For `Agus_SqlServer_dwh` with an SQL login: create the user `FOR LOGIN` or as a contained user. This deviates from SEC-01 (decision D-2).
4. Run `config/10_insert_retention_config.sql`. Review its defaults first: InitialCutoffMethod is BATCH_DELETE for all tables, while the 11 LARGE tables are rebuild candidates.
5. In Blob storage `stormsfsax01loc10dev`, the container `dwh-archive` must exist.
6. Run a dry validation: PL_RET_01 with `ValidateOnly = true` (see `pipeline-agus/README.md`).
7. Run the unit tests of the FSD before the first Initial Cut-off Run.

## Open points

- Not executed on Azure SQL Database: syntax and behaviour are unverified.
- FSD update needed for:
  - the log-retention addition above
  - the linked-service deviation (D-2)
  - the ValidateOnly parameter (D-3)
  - ERR-EXP-02, which is now raised (D-1)
- Decision on TABLE_REBUILD for the LARGE tables.
- F-12 / OQ-26 (LARGE child of a SMALL/MEDIUM header) is not relevant for phase 1, because child tables are excluded.
