# SQL database objects – schema `ret` (v0.5)

| Item | Value |
|---|---|
| Script version | 0.5.1 – **Draft, not reviewed**. 0.5.1 = collation fix (COLLATE DATABASE_DEFAULT on sys.* string columns and STRING_AGG) after the error "Cannot resolve collation conflict for string_agg operation" on Azure SQL Database |
| Date | 1 November 2026 |
| Content | v0.4 (30 Oct 2026) + v0.5 patch (31 Oct 2026, CR-01 automatic table selection for Initial Cut-off) |
| Target | Azure SQL Database, DWH database, schema `ret`, compatibility level ≥ 130 |
| Sources | FSD-DWH-RET-001 v0.2 (Draft for Review, not approved); design table v0.2 |
| Used by | the ADF pipelines in `pipeline/adf` (contract: header "ADF CALL SEQUENCE PER TABLE") |

CR-01 (empty `TableConfigIdList` = automatic mode) is a **proposal that still needs approval**: it changes the input of FSD FR-004. Known limitation F-12 (a LARGE child of a SMALL/MEDIUM header can never be selected, OQ-26) is still open.

## Files

| File | Content | Deploy? |
|---|---|---|
| `DWH_Retention_DB_Objects_v0.5.sql` | Complete consolidated script (all sections 0–14). **Use this for a new database.** | Yes – whole file |
| `deploy/01_schema_tables.sql` | Schema `ret`, 10 tables with keys, constraints and indexes, migration blocks for v0.2/v0.3 databases | Same content as the full script, split for review |
| `deploy/02_triggers_seed.sql` | 3 triggers, parameter row, 30 error codes | 〃 |
| `deploy/03_functions.sql` | 9 functions | 〃 |
| `deploy/04_procedures.sql` | 29 stored procedures | 〃 |
| `deploy/05_reference_examples_monitoring.sql` | Example configuration, example calls, monitoring queries – **all commented out** | No (reference) |
| `deploy/06_security_roles_TEMPLATE.sql` | Roles and GRANTs, optional temporal history – **commented out template with placeholders** | Only after DBA review |
| `DWH_Retention_DB_Objects_v0.5_patch.sql` | Only `ret.usp_GetTablesToProcess` v0.5 | Only for a database where v0.4 is already deployed |

Run **either** the full script **or** `deploy/01` → `02` → `03` → `04` in that order, not both. Everything is re-runnable: tables are created only when missing, migration blocks run only when the old structure exists, code objects use `CREATE OR ALTER`.

## Object inventory

**Tables (10):** RetentionErrorCode, RetentionParameter, RetentionConfig, RetentionParentKey, RetentionRunLog, RetentionTableStatus, RetentionTableLock, RetentionTableLog, RetentionArchiveDate, RetentionStepLog.

**Triggers (3):** trg_RetentionConfig_AfterInsert, trg_RetentionConfig_AfterUpdate, trg_RetentionParentKey_Protect.

**Functions (9):** fn_NowUtc7, fn_TodayUtc7, fn_GetCutoffDates, fn_IsWithinWindow, fn_ArchiveFolderPath, fn_ArchiveFileName, fn_DelayString, fn_ColumnTypeSql, fn_TableDefinitionText.

**Stored procedures (29):**

| Group | Procedures | Granted to ADF |
|---|---|---|
| Internal helpers | usp_WriteStepLog, usp_SetTableError, usp_GetTableSqlParts, usp_AbortRunRebuilds | No |
| Run / table flow | usp_StartRun, usp_GetTablesToProcess, usp_BeginTable, usp_GetPendingResume, usp_IdentifyEligibleData, usp_GetExportPlan, usp_ExportSourceRows, usp_CheckExecutionWindow, usp_LogExportResult, usp_ValidateArchive, usp_BatchDelete | Yes |
| Table rebuild (IC only) | usp_TableRebuildPrepare, usp_TableRebuildSwap, usp_TableRebuildAbort | Yes |
| Post-check, expiry, cleanup, close | usp_PostCheck, usp_GetExpiredArchiveFolders, usp_LogExpiredArchiveResult, usp_LogCleanupResult, usp_EndTable, usp_EndRun | Yes |
| Operator / admin | usp_AdminCloseStaleRun, usp_AdminClearTableFlag, usp_ActivateDailyRoutine | No (ret_operator_admin) |
| Table analysis (FR-022) | usp_ListCandidateTables, usp_ProfileRetentionColumn | No (ret_operator_admin) |

All 20 procedures called by the ADF pipelines in `pipeline/adf` exist in this script (checked by name).

## Deployment steps (development database first)

1. Connect to the **DWH database** (not `master`) with a login that may create schemas and objects (e.g. `db_owner`).
2. Run `DWH_Retention_DB_Objects_v0.5.sql` (SSMS / Azure Data Studio, "GO" batch separator).
3. Set the archive container (container name only, decision D-02):
   `UPDATE ret.RetentionParameter SET ArchiveContainer = N'<container-name>' WHERE ParameterSetId = 1;`
4. Insert the approved tables into `ret.RetentionConfig` (and `ret.RetentionParentKey` for child tables) – see `deploy/05_…` for the format.
5. With the DBA: adapt and run `deploy/06_security_roles_TEMPLATE.sql` (create the ADF managed-identity user, roles, GRANT EXECUTE). The ADF identity needs EXECUTE only; DWH table access goes through `WITH EXECUTE AS OWNER`.
6. Dry check without data change: run the Initial Cut-off master pipeline with a VALIDATION run, or call `usp_StartRun @ProcessType = 'VALIDATION'` manually (see `deploy/05_…`).
7. Run the unit tests of FSD section 17 before any Initial Cut-off Run in production.

## Open points

- The script has **not** been executed on SQL Server / Azure SQL Database; syntax and behaviour are unverified.
- CR-01 and the deviations D4-01..D4-06 listed in the script header need FSD update / approval.
- F-12 / OQ-26 (LARGE child of SMALL/MEDIUM header) needs a business decision.
- Placeholders in the security template (`<adf-managed-identity-name>`) and the container name must be supplied by the infrastructure team.
