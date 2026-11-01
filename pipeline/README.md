# ADF Pipeline Design – DWH Data Retention and Archiving

| Item | Value |
|---|---|
| Package | ADF resources for FSD-DWH-RET-001 |
| Package version | 0.2 – Draft for review |
| Date | 31 October 2026 |
| Status | **Not approved.** Not imported or executed in any Data Factory. |
| Sources | FSD_DWH_Data_Retention_v0.2 301026.docx (FSD v0.2, Draft for Review, not approved); DWH_Retention_DB_Objects_v0.4.sql + DWH_Retention_DB_Objects_v0.5_patch.sql (drafts, not executed) |
| Contract followed | "ADF CALL SEQUENCE PER TABLE" in the SQL v0.4 header; procedure parameters and result columns of SQL v0.4 |

The pipelines contain no business logic of their own. Every decision (table selection, checks, cut-off dates, validation, deletion, rebuild, expiry) is taken by the schema `ret` procedures; ADF only orchestrates, copies rows to Parquet and lists/deletes blob folders (FSD 6.1, FR-021).

---

## 1. Package contents

```
adf/                         ADF Git-integration layout (copy into the factory repository root folder)
  linkedService/             LS_RET_AzureSqlDb, LS_RET_ArchiveBlob          (placeholders: <sql-server-name> etc.)
  dataset/                   DS_RET_SqlDb, DS_RET_ArchiveParquet, DS_RET_ArchiveFolder
  pipeline/                  11 pipelines: folder "DWH Retention/Run" (2, started by the operator / trigger)
                             and "DWH Retention/Internal" (9, called by the Run pipelines only)
  trigger/                   TR_RET_DailyRoutine_2100_WIB (deployed Stopped)
arm/
  ARMTemplateForFactory.json             same resources as one ARM template (17 resources)
  ARMTemplateParametersForFactory.json   parameter file to fill in
tools/
  build_adf.py               generator of all JSON files (single source; edit here, then regenerate)
  validate_adf.py            static checks + scenario evaluation of the dynamic T-SQL expressions
  sql_contract.json          procedure parameters / result columns transcribed from SQL v0.4
```

## 2. Pipeline hierarchy

```
Run/PL_RET_01_InitialCutoff_Master  (PL-01, manual, concurrency 1)     params: TableConfigIdList (empty = automatic), RunDate, DowntimeReference, TriggeredBy
Run/PL_RET_02_DailyRoutine_Master   (PL-02, trigger 21:00 WIB, conc. 1) params: RunDate, TriggeredBy
 │  usp_StartRun → usp_GetTablesToProcess → ForEach table (sequential) → usp_EndRun (fails the run if not SUCCEEDED)
 └─ PL_RET_03_Table_Process  (PL-03, per table)
     │  usp_BeginTable ─┬─ PROCEED (not VALIDATION) → PL_RET_03A_Table_DataSteps
     │                  └─ DAILY_ROUTINE and CanRunArchiveExpiry = 1 → PL_RET_04_ArchiveExpiry
     │  usp_EndTable (always; ADF error text passed as @ErrorMessage) → Fail activity if FAILED / STOPPED
     ├─ PL_RET_03A_Table_DataSteps
     │    PendingResume? → PL_RET_03B_Table_ResumeDelete (usp_BatchDelete on earlier ranges, usp_GetPendingResume)
     │    usp_IdentifyEligibleData → Switch:
     │       BATCH     → PL_RET_03C_Path_BatchDelete   export → usp_ValidateArchive → usp_BatchDelete → usp_PostCheck
     │       REBUILD   → PL_RET_03D_Path_TableRebuild  usp_TableRebuildPrepare → export → usp_ValidateArchive
     │                                                → usp_TableRebuildSwap → usp_PostCheck | usp_TableRebuildAbort
     │       IC_NODATA → usp_PostCheck (IC without eligible rows reaches COMPLETED)
     ├─ PL_RET_03E_Export_BusinessDates   Until: usp_GetExportPlan(MaxRows 1) → Copy (source usp_ExportSourceRows,
     │                                    Parquet sink) → usp_LogExportResult; stops on ContinueExport = 0
     ├─ PL_RET_03F_Table_FileCleanup      Delete <schema>_<table>_*_<RunId>.parquet under <BlobPath> → usp_LogCleanupResult
     └─ PL_RET_04_ArchiveExpiry (PL-04)   YEAR → MONTH → DAY levels via PL_RET_04A_ArchiveExpiry_Level:
                                          Get Metadata → usp_GetExpiredArchiveFolders → Delete folders → usp_LogExpiredArchiveResult
```

Design rules applied:

- **No nested containers except If inside Until.** ForEach/Until/If/Switch never contain another loop; deeper logic is placed in child pipelines (Execute Pipeline). This keeps every pipeline within ADF nesting limits.
- **Decisions come from procedure results.** Values needed later are copied into pipeline variables (`vValidationResult`, `vDeleteResult`, `vSwapDeleteStatus`, …) so that no activity reads the output of an activity inside another container.
- **Fail-safe ordering (BR-08).** `usp_ValidateArchive` is always called after the export step, also when the export failed; it then returns FAILED and nothing is removed. Deletion and swap run only when the stored result is PASSED.
- **`usp_EndTable` always runs** (Completion dependencies), so locks are released and an unfinished rebuild is undone by the procedure (SQL D4-06).
- **Nullable procedure parameters.** Where a value may be NULL (`@RunDate`, `@DowntimeReference`, `@ErrorMessage`), the Lookup uses an `EXEC` statement built by expression, with single quotes doubled and `NULL` when empty. An empty DowntimeReference is therefore never stored as an empty string (it would bypass the LARGE / TABLE_REBUILD gate of BR-16). All other calls use stored-procedure parameters.

## 3. Traceability – FSD to pipeline

| FSD item | Implemented in | Coverage | Note |
|---|---|---|---|
| PL-01 / PRC-02 / FR-011 Initial Cut-off Run | PL_RET_01, 03, 03A, 03C, 03D | Full | Sequential list; DowntimeReference passed to usp_StartRun |
| PL-02 / PRC-03 / FR-012 Daily Routine | PL_RET_02 + TR_RET_DailyRoutine_2100_WIB | Full | Trigger 21:00 SE Asia Standard Time, deployed Stopped (FR-020) |
| PL-03 per-table flow (IC-01..IC-05, DR-01..DR-06) | PL_RET_03, 03A | Full | |
| PL-04 / PRC-04 / FR-013 expired archive deletion | PL_RET_04, 04A | Partial | File count not reported (F-03) |
| FR-003 run date UTC+7 | usp_StartRun (RunDate NULL = today) | Full | Override only earlier (DBR-15, enforced in SQL) |
| FR-004 table selection, DBR-18/19 order | usp_GetTablesToProcess, ForEach sequential | Full | |
| FR-005 eligible data, FR-023 child tables | usp_IdentifyEligibleData | Full | Child logic is inside SQL |
| FR-006 / FR-007 Parquet per business date, MD-07 layout | PL_RET_03E, DS_RET_ArchiveParquet | Full | Folder and file name taken from usp_GetExportPlan |
| FR-008 row-count validation (BR-08) | usp_ValidateArchive in 03C / 03D | Full | rowsRead / rowsCopied of the Copy activity recorded per date |
| FR-009 batch delete | usp_BatchDelete in 03C | Full | |
| FR-010 table rebuild RB-01..RB-10 | PL_RET_03D (Prepare / export / Validate / Swap / Abort) | Full | Window behaviour differs from FR-019 (F-01) |
| FR-014 execution logging | All procedure calls; usp_EndTable / usp_EndRun | Full | ADF error text written to the table log |
| FR-016 concurrency | Pipeline concurrency 1 + table lock in SQL | Full | |
| FR-017 resume | PL_RET_03B | Full | |
| FR-018 cleanup of failed-run files | PL_RET_03F | Full | Verify wildcard behaviour (V-04 in section 6) |
| FR-019 IC window | usp_CheckExecutionWindow before the first date; usp_LogExportResult after each date; SQL in delete / rebuild | Full for export and delete | See F-01 for rebuild |
| FR-020 activation | Trigger Stopped; start after usp_ActivateDailyRoutine | Full (manual step) | |
| FR-015 monitoring | ADF monitoring + Fail activity per failed table | Full | No alerts (BR-15) |
| FR-004 automatic selection (CR-01, proposed) | PL_RET_01 with empty TableConfigIdList; SQL v0.5 patch | Change request | Changes FR-004 "Input"; requires approval |

## 4. Findings and open decisions

Facts are stated as found in the sources; recommendations are marked [REC].

| ID | Severity | Finding | Evidence | Impact | Proposed handling |
|---|---|---|---|---|---|
| F-01 | High | FR-019 says a table rebuild, once RB-03 has started, is not interrupted by the window check. SQL v0.4 stops it: `usp_LogExportResult` stops the export at the window end for every IC table, and `usp_TableRebuildSwap` returns STOPPED outside the window. The pipelines follow SQL v0.4, so a rebuild that reaches the window end is aborted and its files removed. | FSD 7.2.19; SQL 6.9, 7.3 | A large rebuild may never complete inside one window; downtime is wasted. | Decide which behaviour is required (link to OQ-11, R-11), then align FSD or SQL. No pipeline change is needed if SQL changes. |
| F-02 | High | Export is one Copy activity per business date, sequential (DEC-07, OQ-16 open). The IC archived segment covers 5 years, about 1,826 business dates per table if every day has data, and must finish in one window, because a window stop removes the files and the next run exports from the first date again (E2, 13.5). The fixed start-up time of each Copy activity has not been measured. | FSD 10.6.3, 13.5, OQ-16, R-11 | IC of tables with many dates may not fit in 21:00–05:00. | Measure Copy duration per date in the proof of concept (TS-042). If too slow, decide on parallel export (needs an FSD / design-table change) or on exporting the archived segment in earlier windows (OQ-11). |
| F-03 | Medium | The pipelines do not read a file count from the Delete activity. `usp_LogExpiredArchiveResult` receives FoldersDeleted = number of folders submitted for deletion and FilesDeleted is not passed (stored 0); `usp_LogCleanupResult` receives no FilesRemoved. | PL_RET_04A, PL_RET_03F | ArchiveFilesDeleted (BRD 7.4 mapping, FSD 10.6.10) is not populated. | [REC] Enable Delete activity logging to a log folder, or list files with Get Metadata before deletion; or accept folder counts and update the FSD. |
| F-04 | Medium | Retry counts, intervals and timeouts are TBD in the FSD. Values used here are proposals. | FSD 13.4, Section 11 | Too short timeouts would fail long deletes / rebuilds. | Confirm values with the DBA; see section 5. |
| F-05 | Medium | Integration Runtime and authentication are TBD (OQ-17). The package uses the factory managed identity and `AutoResolveIntegrationRuntime` as defaults. | FSD Section 11, SEC-01 | Import works, connection fails if the network requires a self-hosted or managed-VNet IR. | Set `integrationRuntimeName` at import (the IR must exist). |
| F-06 | Low | ERR-EXP-02 (target file already exists) is not raised by ADF: the Copy activity overwrites a file of the same name. Uniqueness relies on the RunId in the file name (DBR-07); a same-name write only happens on an ADF retry of the same date in the same run. | SQL 3 seed, FSD DEC-04 | None expected. | Accept, or [REC] add a Get Metadata `exists` check before Copy. |
| F-07 | Low | A VALIDATION run calls `usp_BeginTable`, which may drop a leftover `__RBD_` table of an unfinished rebuild (SQL D4-06). The dry validation is therefore not strictly free of changes. | SQL 6.3 | Unexpected for an operator who expects no change. | Document in the operational guide or skip the rebuild clean-up for VALIDATION in SQL. |
| F-08 | Low | Inactive tables are not selected by the Daily Routine, so their expired archive files are not deleted. | SQL 6.2, FSD PRC-06, OQ-07 | Expired files may remain for deactivated tables. | Decide OQ-07. |
| F-12 | Medium | A LARGE child table whose header table is SMALL or MEDIUM can never be selected: the header waits for the child (DBR-18) and the child waits for all SMALL/MEDIUM tables (DBR-05). Applies to explicit and automatic selection. | SQL v0.4/v0.5 usp_GetTablesToProcess | IC of such a pair never completes | Decide OQ-26 / BR-16 (e.g. allow a LARGE child before its header, or classify the pair together). |
| F-09 | Info | Rebuild preconditions outside ADF (ETL writes stopped, restore point confirmed, log capacity) are not checked by the pipelines; only the DowntimeReference is enforced (by SQL). | FSD 8.4 RB-01, R-02 | Operator checklist required. | Keep in the rebuild checklist (BRQ-15). |

## 5. Timeouts and retries used [REC – values TBD per FSD 13.4]

| Activity group | Activity timeout | Query timeout | Retry |
|---|---|---|---|
| Control procedures (StartRun, GetTables, Validate, window, export plan, Abort) | 30 min | 30 min | 1 × 60 s |
| Logging procedures (LogExportResult, LogCleanupResult, LogExpiredArchiveResult, EndTable) | 10 min | 30 min | 2 × 30 s |
| Scanning procedures (BeginTable, IdentifyEligibleData, PostCheck) | 4 h 15 min | 4 h | 1 × 60 s |
| BatchDelete, RebuildPrepare, RebuildSwap | 8 h 30 min | 8 h | 0 (rebuild: no automatic retry, FSD 13.4) |
| usp_EndRun | 30 min | 30 min | 0 (raises an error by design) |
| Copy per business date | 4 h | 4 h | 2 × 120 s |
| Get Metadata / Delete | 30 min / 1 h | – | 2 × 60 s |
| Until loops | 12 h | – | – |

## 6. Import

**Prerequisites (before import)**

1. Deploy `DWH_Retention_DB_Objects_v0.4.sql`, then `sql/DWH_Retention_DB_Objects_v0.5_patch.sql`, to the DWH database (development first).
2. Create the database user for the factory managed identity and add it to `ret_adf_executor` (SQL section 13, commented out; review with the DBA).
3. Give the factory managed identity *Storage Blob Data Contributor* on the archive container only (SEC-05).
4. `UPDATE ret.RetentionParameter SET ArchiveContainer = N'<container>' WHERE ParameterSetId = 1;` (D-02).

**Option A – ARM template (recommended for a factory without Git)**

1. ADF Studio → Manage → ARM template → *Import ARM template* → *Build your own template in the editor* → *Load file* → `arm/ARMTemplateForFactory.json` → Save.
2. Fill in: factory name, `sqlServerFqdn`, `sqlDatabaseName`, `archiveStorageAccountName`, `integrationRuntimeName`, `dailyRoutineTriggerStartTime` (local time, e.g. the DailyRoutineStartDate at 21:00).
3. Review + create. Alternatively: `az deployment group create -g <rg> --template-file arm/ARMTemplateForFactory.json --parameters @arm/ARMTemplateParametersForFactory.json`.

**Option C – ADF Studio only (no Azure Portal access)**

1. Manage → Linked services → + New: create `LS_RET_AzureSqlDb` (Azure SQL Database) and `LS_RET_ArchiveBlob` (Azure Blob Storage), both with System-assigned managed identity.
2. Author → + → Dataset: create `DS_RET_SqlDb` (Azure SQL Database), `DS_RET_ArchiveParquet` (Blob, Parquet), `DS_RET_ArchiveFolder` (Blob, Binary); open `{}` (Code) and replace the JSON with the file content.
3. Author → + → Pipeline: for each file in this order paste the JSON into `{}`: 03F, 03E, 03C, 03D, 03B, 03A, 04A, 04, 03, 01, 02. Put 01 and 02 in folder `DWH Retention/Run`, the others in `DWH Retention/Internal` (the folder is part of the JSON).
4. Manage → Triggers: create `TR_RET_DailyRoutine_2100_WIB` (Schedule, daily 21:00, (UTC+07:00) Bangkok, Hanoi, Jakarta), not started; attach it to PL_RET_02.
5. Validate all → Publish all.

**Option B – Git-integrated factory**

1. Replace the placeholders in `adf/linkedService/*.json` (`<sql-server-name>`, `<dwh-database-name>`, `<archive-storage-account>`, IR name).
2. Copy the four folders into the root folder of the collaboration branch, refresh ADF Studio, *Validate all*, then *Publish*.

**Verify after import (not tested yet – no factory was available)**

| # | Check | Expected |
|---|---|---|
| V-01 | ADF Studio *Validate all* | No errors |
| V-02 | Test connection of both linked services | Succeeds with managed identity |
| V-03 | SQL v0.5 patch deployed; PL_RET_01 with empty TableConfigIdList (dev, 1 SMALL + 1 LARGE table, no DowntimeReference) | SMALL table processed; LARGE table SKIPPED with ERR-CFG-07; second run selects only tables not COMPLETED |
| V-04 | PL_RET_03F with a RunId that has no files, and with a folder that does not exist | Run succeeds; `usp_LogCleanupResult` SUCCEEDED; only `*_<RunId>.parquet` files removed in all date folders |
| V-05 | PL_RET_01 on a SMALL dev table, BATCH_DELETE | Parquet files per date, counts PASSED, rows removed, IC COMPLETED (TS-012..TS-016) |
| V-06 | PL_RET_01 with Copy forced to fail (e.g. wrong container) | Files of the run removed, nothing deleted, table FAILED (TS-032..) |
| V-07 | PL_RET_01 TABLE_REBUILD on a dev table with DowntimeReference | Swap COMPLETED, definition check passed |
| V-08 | PL_RET_02 manual run after `usp_ActivateDailyRoutine` | One date exported per table, expired folders removed level by level |
| V-09 | Parquet type mapping (datetime2, decimal, Unicode) | As agreed in TS-042 |

**Activation of the Daily Routine (FSD 16.2):** after every active table is COMPLETED, run `EXEC ret.usp_ActivateDailyRoutine @Confirm = 1;`, set the trigger start time to that date 21:00, then *Start* `TR_RET_DailyRoutine_2100_WIB` and publish.

## 7. Operating the Initial Cut-off Run

- Trigger `PL_RET_01_InitialCutoff_Master` manually inside 21:00–05:00 UTC+7.
- `TableConfigIdList`: **leave empty for automatic mode** (requires SQL v0.5 patch): every active table not yet COMPLETED is selected, SMALL/MEDIUM before LARGE, child tables first. Run the pipeline again (in later windows) until every table is COMPLETED; LARGE tables are selected only when all SMALL/MEDIUM tables are COMPLETED and a DowntimeReference is given. Or give a comma-separated list to choose the tables and their order yourself.
- `DowntimeReference`: required for LARGE or TABLE_REBUILD tables (otherwise SQL skips them with ERR-CFG-07).
- `RunDate`: leave empty (today UTC+7); an earlier date is allowed only as an override (DBR-15).
- A failed table shows as a failed `PL_RET_03_Table_Process` run; the master continues and ends FAILED or COMPLETED_WITH_ERRORS in `ret.RetentionRunLog`. Rerun per FSD 16.7.

## 8. Regenerating

```
python3 tools/build_adf.py <output-folder>
python3 tools/validate_adf.py <output-folder>
```

The validator checks expression syntax, activity references and their scope, upstream dependencies, nesting rules, variables, parameters of Execute Pipeline and datasets, procedure names, parameter names and result columns against `sql_contract.json`, and ARM escaping; it also evaluates the generated T-SQL with sample values. It does not replace ADF Studio validation.

## 9. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 | 31 Oct 2026 | Prepared with Claude for the project team (owner TBD) | First draft from FSD v0.2 and SQL v0.4 |
| 0.2 | 31 Oct 2026 | Prepared with Claude for the project team (owner TBD) | Option A: PL_RET_05 removed; folders Run / Internal; TableConfigIdList optional (automatic mode, CR-01, SQL v0.5 patch); import option C; finding F-12 |
