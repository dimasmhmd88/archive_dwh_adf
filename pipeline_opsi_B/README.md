# pipeline_opsi_B – Option B: parallel export per chunk and merged Lookups

| Item | Value |
|---|---|
| Version | ADF opsi B v0.1 (unchanged), SQL v0.7.1-opsiB |
| Status | **Draft – not reviewed, not executed in ADF or against a database** |
| Date | 17 November 2026; SQL v0.7.1-opsiB 27 November 2026 (D-8 child delete mode) |
| Based on | `pipeline-agus/` v0.3 (linked services `Agus_SqlServer_dwh`, `Agus_AzureBlobStorage1`) and SQL v0.6.1 (D-6 Parquet column names, 21 Nov 2026) |
| Decisions to record | **D-7** (UAT): BatchSize 20,000, BatchPauseSeconds 2. **D-8**: child tables deleted through a header-key temp table (`ChildDeleteMode = KEY_TABLE`), default unchanged (`JOIN`). Both for FSD v1.2, not approved yet. |
| Decision needed | Change of **DEC-07** (export one business date at a time) to "N business dates of one table exported in parallel per chunk". FSD v1.2 update. This package is the proposal; it is not approved. |

The existing packages `pipeline-agus/` and `pipeline/` are **not changed**. This folder is separate.

## 1. What changes compared with pipeline-agus v0.3

| # | Change | Where | Effect (from the measured test run, 1 table, 1 date, 2 m 53 s) |
|---|---|---|---|
| B | Export of **N dates in parallel per chunk**. N = `ret.RetentionConfig.ExportParallelism` (per table, optional), otherwise `ret.RetentionParameter.ExportParallelism` (default **4**), 1..16. N is changed in SQL, **no pipeline change** | `PL_RETB_03E_Export_Chunks` (loop per chunk) + `PL_RETB_03G_Export_Chunk` (ForEach, batchCount 16) + `ret.usp_GetExportChunk` | Cost per date ±36 s / N. Table with 1,826 dates: ±18 h → ±4.7 h (N = 4), ±2.5 h (N = 8) – estimate |
| T1a | ValidateArchive + BatchDelete + PostCheck in **one Lookup** | `ret.usp_ValidateDeleteAndCheck` in `PL_RETB_03C` | −2 Lookups, −2 If, −4 Set Variable (±20 s) |
| T1b | `LKP_CheckExecutionWindow` removed; the window check is in `usp_GetExportChunk`, `usp_LogExportResult` and `usp_BatchDelete` | `PL_RETB_03E` | ±10 s |
| T1c | `LKP_NextExportDate` replaced by one `usp_GetExportChunk` per chunk | `PL_RETB_03E` | per chunk instead of per date |
| T1d | StartRun + GetTablesToProcess in **one Lookup** | `ret.usp_StartRunAndGetTables` in the masters | ±8 s per run |
| T1e | BeginTable + IdentifyEligibleData in **one Lookup** (except after a resume, FSD 4.17) | `ret.usp_BeginTableAndIdentify` in `PL_RETB_03` | ±7 s |
| DR | Expired archive deletion in **one pipeline**, both levels decided by one Lookup (was 2 × PL_RET_04A) | `PL_RETB_04_ArchiveExpiry` + `ret.usp_GetExpiredArchiveItems` | Daily Routine: −2 Lookups and −2 pipeline calls per table (±15 s) |

Lookups per table with one business date: **12 → 7** (StartRunAndGetTables, BeginTableAndIdentify, GetExportChunk, LogExport, ValidateDeleteAndCheck, EndTable, EndRun). The earlier estimate of 6 assumed that the first chunk is returned by BeginTableAndIdentify; that would need an array passed through three pipeline levels and saves only ±7 s, so it was not done.

**Not changed:** validation rules (per date and total, BR-08), D-1 (ERR-EXP-02), archive layout MD-07, resume (PL_RETB_03B), table rebuild path (PL_RETB_03D, only its export now uses the chunk loop), file cleanup (PL_RETB_03F), checks V-01..V-11, error codes, monitoring views. Tables are still processed one after the other (DEC-07 for tables unchanged); only the dates of one table run in parallel.

## 2. Folder content

```
pipeline_opsi_B/
├── README.md
├── sql/
│   ├── 20_OpsiB_DB_Objects.sql      ← deploy (generated, SQL v0.7.1-opsiB)
│   ├── 21_verify_opsiB.sql          ← check after deploy, every row OK
│   ├── 22_check_child_delete_mode.sql ← read-only: JOIN vs KEY_TABLE select the same child rows (D-8)
│   ├── 29_rollback_opsiB.sql        ← remove opsi B objects (back to v0.6)
│   └── src/
│       ├── opsiB_new_objects.sql    ← hand-written part (columns + 6 new procedures)
│       └── usp_BatchDelete_opsiB.sql ← opsi B source of usp_BatchDelete (ChildDeleteMode), used instead of 04
├── adf/                             ← ADF JSON (Git layout): 3 datasets, 11 pipelines, 1 trigger
├── arm/                             ← ARM template (no linked services)
└── tools/
    ├── make_sql_opsiB.py            ← builds sql/20_... from pipeline/sql/deploy/04_procedures.sql (v0.6)
    ├── build_adf.py                 ← builds adf/ and arm/
    ├── validate_adf.py              ← static validation + expression scenarios (0 errors, 0 warnings)
    └── sql_contract.json            ← procedure parameters / result columns (v0.6 + v0.7-opsiB)
```

### ADF objects

| Folder | Object | Note |
|---|---|---|
| DWH Retention Opsi B | `PL_RETB_01_InitialCutoff_Master` | Same parameters as PL_RET_01 (TableConfigIdList, RunDate, DowntimeReference, TriggeredBy, ValidateOnly) |
| DWH Retention Opsi B | `PL_RETB_02_DailyRoutine_Master` | Same parameters as PL_RET_02 |
| DWH Retention Opsi B/Internal | `PL_RETB_03`, `03A`, `03B`, `03C`, `03D`, `03E_Export_Chunks`, `03F`, **`03G_Export_Chunk`** (new), `PL_RETB_04_ArchiveExpiry` | `PL_RET_04A` no longer exists |
| DWH Retention | `DS_RET_SqlDb`, `DS_RET_ArchiveParquet`, `DS_RET_ArchiveFolder` | **Shared** with pipeline-agus, same definition (only the annotations differ) – do not create them twice |
| – | `TR_RETB_DailyRoutine_2100_WIB` | Created **Stopped**. Never start it together with `TR_RET_DailyRoutine_2100_WIB` |

The PL_RETB_* names let the package sit next to pipeline-agus in the same factory for a comparison test. Both packages use the same `ret` tables: never run both at the same time (the table lock stops the second one with ERR-LCK-01).

## 3. SQL v0.7-opsiB

`20_OpsiB_DB_Objects.sql` contains:

- **A. Columns** `ExportParallelism` (TINYINT, 1..16): `ret.RetentionParameter` (NOT NULL, default 4) and `ret.RetentionConfig` (NULL = global value).
- **B. 9 v0.6 procedures with an output option** (generated, logic unchanged): `usp_StartRun`, `usp_GetTablesToProcess`, `usp_BeginTable`, `usp_IdentifyEligibleData`, `usp_ValidateArchive`, `usp_BatchDelete`, `usp_PostCheck`, `usp_GetExpiredArchiveFolders`, `usp_EndRun`. Each result SELECT writes into `#RetOut_<procedure>` when the caller created that temp table, otherwise it returns the v0.6 result set. **pipeline-agus keeps working unchanged.**
  Why not `INSERT … EXEC`: it would run the called procedure inside one transaction – usp_BatchDelete would lose its short per-batch transactions, and the TRY/CATCH blocks of usp_BeginTable (lock conflict ERR-LCK-01) would leave a doomed transaction.
- **C. 6 new procedures**:

| Procedure | Called by | Does |
|---|---|---|
| `usp_StartRunAndGetTables` | PL_RETB_01 / 02 | usp_StartRun + usp_GetTablesToProcess; one row per table (a row with TableConfigId NULL when none). A selection error closes the run with usp_EndRun (FAILED) and is raised again |
| `usp_BeginTableAndIdentify` | PL_RETB_03 | usp_BeginTable; when PROCEED, not VALIDATION and no pending resume: usp_IdentifyEligibleData (an unexpected identify error → ERR-SYS-01, IdentifyResult FAILED, the table is still closed by usp_EndTable) |
| `usp_GetExportChunk` | PL_RETB_03E | Stop (with cleanup) when the table log is FAILED/STOPPED or a date failed; stop when nothing is PENDING; IC window check (ERR-WIN-01); otherwise the next N PENDING dates |
| `usp_ValidateDeleteAndCheck` | PL_RETB_03C | Recount RowsExported; usp_ValidateArchive → usp_BatchDelete **only when PASSED** → usp_PostCheck **only when COMPLETED**. ADF retry 0 |
| `usp_GetCleanupDecision` | PL_RETB_03C (error path) | Files of this run may be removed only while no row was deleted (DeleteStatus NOT_STARTED, RowsDeleted 0) |
| `usp_GetExpiredArchiveItems` | PL_RETB_04 | usp_GetExpiredArchiveFolders for YEAR and FILE in one call |

The ADF identity needs EXECUTE on the 6 new procedures (with a schema-level `GRANT EXECUTE ON SCHEMA::ret` nothing changes).

### 3.1 Child delete mode (D-8, SQL v0.7.1-opsiB)

`ret.RetentionParameter.ChildDeleteMode` (VARCHAR(10), NOT NULL, default `JOIN`, CHECK `JOIN` / `KEY_TABLE`) decides how `ret.usp_BatchDelete` deletes the rows of a **child** table. Own-dated tables are not affected. **No ADF change**: same procedure, same parameters, same result columns.

| | `JOIN` (default, v0.6) | `KEY_TABLE` |
|---|---|---|
| Header table read | in every batch (join + header date filter) | **once** per call: distinct join keys of the header rows in the validated range → `#RetBdParentKey` (KeySeq + k1..kn, header column types and collations) |
| Batch | `DELETE TOP (BatchSize) t FROM child t LEFT JOIN header p … WHERE p.date < @Upper` | `DELETE TOP (BatchSize) t FROM child t JOIN #RetBdParentKey k … WHERE k.KeySeq BETWEEN @SeqFrom AND @SeqTo` |
| BatchSize means | child rows | child rows (unchanged); keys are processed in windows of BatchSize keys, a batch below BatchSize moves to the next window, empty windows are not counted and not paused |
| Pre-delete recount (DBR-06) | header join | child JOIN key table – counts exactly the rows the batches can delete |
| Final recount (ERR-DEL-02) | header join | header join (independent check) |
| Orphans (DBR-21) | never match | never in the key table |

Unchanged in both modes: BR-08 gate, per-batch transaction and log update, `BatchPauseSeconds`, retry 1205/1222, `DeleteLockTimeoutMs`, IC window stop, resume (the key table is rebuilt in every call; the header still exists because the child is processed first, DBR-18/19). A key column type that cannot be copied (text, xml, sql_variant, …) falls back to `JOIN` (note in the step message). The step message shows the mode, e.g. `Deleted 120000 rows in 6 batches. ChildDeleteMode KEY_TABLE: 4500 header keys.`

`pipeline/sql/deploy/04_procedures.sql` keeps the v0.6 text (old packages unchanged); the generator takes `usp_BatchDelete` from `sql/src/usp_BatchDelete_opsiB.sql`. Never run `deploy/04` (or patch 08) after `20_OpsiB_DB_Objects.sql` without running 20 again: it would overwrite the opsi B procedures.

Risks: tempdb space for the key table (Initial Cut-off of a large header: millions of keys); an index on the child join key is still required (`21_verify_opsiB.sql` section 6).

```sql
UPDATE ret.RetentionParameter SET ChildDeleteMode = 'KEY_TABLE', ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7()
 WHERE ParameterSetId = 1;      -- back: 'JOIN'. Effective from the next usp_BatchDelete call.
```

## 4. Deployment order

1. Check that SQL v0.6.1 is complete (`pipeline/sql/deploy/08_patch_v0.6.1_parquet_column_names.sql` on an existing v0.6 database): `pipeline/sql/test/90_verify_v06_deployment.sql` – every row OK.
   After any later change of `pipeline/sql/deploy/04_procedures.sql`, regenerate and run `20_OpsiB_DB_Objects.sql` again.
2. Run `sql/20_OpsiB_DB_Objects.sql` (whole file, one session).
3. Run `sql/21_verify_opsiB.sql` – every row OK (38 procedures, ChildDeleteMode column, usp_BatchDelete v0.7.1).
   Optional (D-8): `sql/22_check_child_delete_mode.sql` per child table, then set `ChildDeleteMode = 'KEY_TABLE'`.
4. ADF (Git mode, branch): create the pipelines from `adf/pipeline/*.json` **in this order** (children first): `03F`, `03G`, `03E`, `03B`, `03D`, `03C`, `04`, `03A`, `03`, `01`, `02`; then the trigger (leave it Stopped). The datasets already exist (pipeline-agus).
5. Validate all, Debug `PL_RETB_01_InitialCutoff_Master` with `ValidateOnly = true` first.

## 5. Setting N

```sql
-- global (all tables)
UPDATE ret.RetentionParameter SET ExportParallelism = 4 WHERE ParameterSetId = 1;
-- per table (overrides the global value); NULL = back to global
UPDATE ret.RetentionConfig SET ExportParallelism = 2 WHERE TableConfigId = 5;
```

Effective from the next chunk. Recommended: start with 4, go to 8 for SMALL / MEDIUM tables with an index on the date column after measuring; more than 8 only after a load test with the DBA. 16 is the upper bound (ForEach batchCount of PL_RETB_03G); a higher value needs a pipeline change **and** a change of the two CHECK constraints.

## 6. Test plan (before any decision)

| # | Test | Expected |
|---|---|---|
| 1 | Dry validation of the test tables (`ValidateOnly = true`) | Run VALIDATION SUCCEEDED, BeginResult PROCEED, nothing exported |
| 2 | IC, 1 table, 1 date (same as the measured run) | Same result as pipeline-agus; duration compared (target ±2 min) |
| 3 | IC, 1 table with ±60 dates, N = 4 and N = 8 | Files and counts identical to pipeline-agus; duration per chunk measured |
| 4 | One date fails (e.g. a value that cannot be written to Parquet) | Loop stops after the chunk, table FAILED ERR-EXP-01, all files of the run removed, DWH unchanged |
| 5 | Window: set a short IC window, start outside it | Table STOPPED ERR-WIN-01, files removed |
| 6 | Resume: stop a batch delete (window) and run again | PL_RETB_03B finishes the range, then identify + export of new data |
| 7 | Daily Routine 1 table (after `usp_ActivateDailyRoutine`) | 1 chunk; expired archive deletion through PL_RETB_04 (YEAR and FILE counts in RetentionTableLog) |
| 8 | Regression: run pipeline-agus PL_RET_01 on another test table after deploying SQL v0.7-opsiB | Unchanged behaviour |
| 9 | D-8: `22_check_child_delete_mode.sql` on a child table | Result OK (same child rows in both modes) |
| 10 | D-8: IC header + child (child first in `TableConfigIdList`), `ChildDeleteMode = KEY_TABLE` | Child RowsDeleted = validated count, message shows KEY_TABLE and the key count; header deleted after; orphan rows still present |
| 11 | D-8: one header with more child rows than BatchSize | Several full batches in one window, no row left (no ERR-DEL-02) |
| 12 | D-8: composite join key (2 columns in RetentionParentKey) | Same as 10 |
| 13 | D-8: stop the child delete at the IC window end, run again | Resume rebuilds the key table and finishes the range |
| 14 | D-8: same data with `JOIN` and with `KEY_TABLE` (reset with 91) | Same counts; delete duration compared |

## 7. Known limitations and risks

- **Not executed.** SQL v0.7.1 (KEY_TABLE) is also not compiled. SQL and ADF are checked statically only (generator checks, `validate_adf.py`); no SQL Server was available to compile the script.
- **DWH load:** N reads of the same table at the same time; an index on the date column is strongly recommended for LARGE tables. Agree N with the DBA.
- **Inherited from v0.3:** a file written by a Copy whose result could not be logged (log Lookup failed) stays PENDING and is not removed by the cleanup; the next run overwrites it with the same name.
- ADF may run fewer than N items in parallel when the integration runtime is busy.
- `usp_ValidateDeleteAndCheck` appears as **one** activity in ADF Monitor: which step failed is in `ret.RetentionStepLog` / `RetentionTableLog.ErrorStep`.

## 8. Regenerating

```bash
python3 pipeline_opsi_B/tools/make_sql_opsiB.py .            # from the repository root
cd pipeline_opsi_B && python3 tools/build_adf.py . && python3 tools/validate_adf.py .
```
