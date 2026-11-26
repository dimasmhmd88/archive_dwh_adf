# SQL database objects – schema `ret` (v0.6)

| Item | Value |
|---|---|
| Script version | 0.6 – **Draft, not reviewed, not executed against any database** |
| Date | 11 November 2026 |
| Reference | FSD_DWH_Data_Retention_v1.1 (FSD-DWH-RET v1.1, 10 Nov 2026, *Draft for Review*, not approved). Also the decisions D-1..D-4 of the review "pipeline-agus vs FSD v1.1" (11 Nov 2026), given by the user. |
| Target | Azure SQL Database, DWH database, schema `ret`, compatibility level ≥ 130 |
| Used by | `pipeline-agus/` (linked services `Agus_*`) and `pipeline/` (linked services `LS_RET_*`). Both are generated from the same contract (`tools/sql_contract.json`). |

## Patch v0.6.1 – Parquet column names (decision D-6, 21 Nov 2026)

Dry run of `BI.Fact_PO_Invoice_Retention_UT_A` failed with **ERR-CFG-08** (V-08): column names such as `Volume (000 STC)` or `Price Per Pack` contain white space or `( )`, which the ADF Parquet sink rejects (`ParquetInvalidColumnName`). The user chose option A:

| Object | Change |
|---|---|
| `ret.fn_ParquetColumnName` (new function) | Rejected characters (white space and `, ; { } ( ) =`, tab, line feed, carriage return) become `_`, repeated `_` collapsed, leading/trailing `_` removed. Valid names unchanged. Example: `Volume (000 STC)` → `Volume_000_STC` |
| `ret.usp_ExportSourceRows` | Renamed columns get an alias in the export query; values and column order unchanged |
| `ret.usp_BeginTable` (V-08) | Names are no longer rejected; still rejected: `sql_variant` / CLR types, and renamed names that are not unique (case-insensitive) |
| `ret.vw_ParquetColumnMap` (new view) | Source column → column in the archive file, `IsRenamed` (audit, restore) |

**FSD impact:** FR-006/FR-007 say "all columns, no transformation"; with D-6 the column *names* in the archive can differ from the source (values do not). Record D-6 in FSD v1.2.

Existing v0.6 database: run `deploy/08_patch_v0.6.1_parquet_column_names.sql`, then `test/90_verify_v06_deployment.sql` (10 functions, 7 views). If the opsi B objects are deployed, run `pipeline_opsi_B/sql/20_OpsiB_DB_Objects.sql` again afterwards (it carries `usp_BeginTable` with the `#RetOut_` option). New database: deploy/01–05 already contain the change.

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
| `deploy/03_functions.sql` | 10 functions (v0.6.1: `fn_ParquetColumnName`) | 3 |
| `deploy/04_procedures.sql` | 32 stored procedures | 4 |
| `deploy/05_monitoring_views.sql` | 7 monitoring views (MQ-01..07) + `vw_ParquetColumnMap` | 5 |
| `deploy/06_reference_examples_monitoring.sql` | Examples and queries, all commented out | No (reference) |
| `deploy/07_security_roles_TEMPLATE.sql` | Roles and GRANTs, commented out, with placeholders | After DBA review |
| `test/90_verify_v06_deployment.sql` | Read-only check that v0.6 is fully deployed (object counts, archive layout functions, v0.6 procedures used by ADF v0.3, BlobPath, old-layout inventory rows). Every row must show OK | After deploy/05 |
| `test/91_reset_table_for_retest.sql` | **DEV/TEST only.** Resets one table (`@TableConfigId`) after a test Initial Cut-off: lists the Blob files to delete, marks the archive inventory REMOVED (avoids ERR-EXP-02) and sets the status back to PENDING | Only for re-tests |
| `test/92_insert_test_table_config.sql` | **DEV/TEST.** Registers test tables (e.g. copies `<table>_Retention`) in `ret.RetentionConfig` after the V-01..V-04 / V-06 checks; size category from used space; preview with `@Apply = 0` | For tests |
| `deploy/08_patch_v0.6.1_parquet_column_names.sql` | **v0.6.1 patch (D-6)** for databases already on v0.6: `fn_ParquetColumnName`, `vw_ParquetColumnMap`, `usp_ExportSourceRows`, `usp_BeginTable` | Existing v0.6 databases only |
| `deploy/09_patch_v0.6.2_view_archive_files.sql` | **v0.6.2 patch:** view `ret.vw_MQ07_ArchiveFiles` (row counts per Parquet file) for databases already on v0.6 / v0.6.1 | Existing databases only |
| `monitoring/30_monitoring_queries.sql` | Read-only monitoring queries (16 blocks): runs, reconciliation, row counts per Parquet file (MQ-07), errors, step log, flags, live progress, Daily Routine readiness, performance | Not deployed (run when needed) |
| `monitoring/31_check_parent_child.sql` | Read-only check of header (parent) / child tables: configuration (DBR-20), join keys (V-10), key uniqueness (V-11, via `usp_GetTableSqlParts`), orphan rows and segments via the header date, Initial Cut-off order (DBR-18), unconfigured foreign keys | Not deployed (run when needed) |
| `monitoring/32_check_parent_key.sql` | Read-only check of `ret.RetentionParentKey`: keys of non-child tables, children without keys, KeyOrdinal, key columns (exist / type / collation / nullable, V-10), comparison with foreign keys, uniqueness in the header (V-11), match rate / orphans (DBR-21), proposed INSERTs from foreign keys | Not deployed (run when needed) |
| `test/93_insert_header_child_config.sql` | Registers a header table and its child table (example `bos.BOS_SD_FDo` / `bos.BOS_SD_FDoItem`, key `szdoId`): checks (tables, date column, keys, unique index, FK, size, existing rows), then header + child + `RetentionParentKey` in one transaction (`@Apply = 1`) | For header/child tables |
| `config/00_insert_default_config.sql` | **v0.1:** explicit defaults of all configuration tables: `RetentionParameter` (batch 10,000 / 3 s, window 21:00–05:00, NULL-check FULL, container `dwh-archive`; optional reset), 30 error codes, missing `RetentionTableStatus` rows | Before `10_…` |
| `config/10_insert_retention_config.sql` | **v0.2:** the 31 phase-1 tables of FSD App. A.1, BlobPath `schema.table`, ArchiveContainer `dwh-archive`; all other rows set inactive | After step 3 below |

**Partial deployment.** A database with the v0.6 tables and views but the v0.5 functions and procedures writes the old archive layout `<BlobPath>/year=YYYY/month=MM/day=DD/<schema>_<table>_<yyyyMMdd>_<RunId>.parquet` (seen in the first test, 15 Nov 2026). Deploy deploy/01–05 in order in one session (03 and 04 directly after each other) and run `test/90_verify_v06_deployment.sql`.

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
