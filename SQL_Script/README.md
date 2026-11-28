# SQL_Script – all SQL of DWH Data Retention and Archiving (schema `ret`)

| Item | Value |
|---|---|
| Status | **Draft – not reviewed, not executed against any database by the author.** Compile and test in DEV first. |
| Version | SQL v0.6.2 (base) + opsi B v0.7.1 (D-8 child delete mode) |
| Date | 28 November 2026 |
| Target | Azure SQL Database, DWH database, schema `ret`, compatibility level ≥ 130 |
| Used by | ADF package `pipeline_opsi_B/` (`PL_RETB_*`, the package in use). `pipeline-agus/` and `pipeline/` (v0.3) still work with the same objects. |
| Replaces | `pipeline/sql/` and `pipeline_opsi_B/sql/` (moved here on 28 Nov 2026, file names unchanged). Older history: `HISTORY_v0.6.md` and Git history. |

## 1. Folders

```
SQL_Script/
├── README.md                              ← this file (deployment order and checks)
├── HISTORY_v0.6.md                        ← change history v0.6 / v0.6.1 / v0.6.2 (former pipeline/sql/README.md)
├── DWH_Retention_FULL_v0.7.1.sql          ← GENERATED bundle: deploy/01..05 + deploy/20 in one file
├── deploy/                                ← database objects (run in number order)
│   ├── 01_schema_tables.sql               10 tables, migration blocks
│   ├── 02_triggers_seed.sql               3 triggers, parameter row, 30 error codes
│   ├── 03_functions.sql                   10 functions (incl. fn_ParquetColumnName, D-6)
│   ├── 04_procedures.sql                  32 procedures v0.6.1 (source of deploy/20)
│   ├── 05_monitoring_views.sql            8 views (MQ-01..07, vw_ParquetColumnMap)
│   ├── 07_security_roles_TEMPLATE.sql     roles / GRANTs, commented out, placeholders – after DBA review
│   ├── 08_patch_v0.6.1_parquet_column_names.sql   upgrade of a v0.6 database (D-6)
│   ├── 09_patch_v0.6.2_view_archive_files.sql     upgrade: view vw_MQ07_ArchiveFiles
│   └── 20_OpsiB_DB_Objects.sql            GENERATED opsi B v0.7.1: columns ExportParallelism / ChildDeleteMode,
│                                          9 procedures with #RetOut_, 6 wrapper procedures – ALWAYS LAST
├── config/                                ← configuration data
│   ├── 00_insert_default_config.sql       RetentionParameter defaults (BatchSize 20000 / pause 2 s, D-7), error codes
│   ├── 10_insert_retention_config.sql     the 31 phase-1 tables (FSD App. A.1)
│   ├── 11_insert_table_config.sql         register own-dated tables (checks, method by size)
│   └── 12_insert_header_child_config.sql  register one header + one child table (parameters, checks, join keys)
├── verify/                                ← read-only checks after a deployment
│   ├── 90_verify_v06_deployment.sql       object counts (32 or 38 procedures), patches 08 / 09, archive layout
│   ├── 21_verify_opsiB.sql                opsi B objects, ChildDeleteMode, index check of child tables
│   └── 22_check_child_delete_mode.sql     JOIN vs KEY_TABLE select the same child rows (D-8)
├── monitoring/                            ← read-only queries, run when needed
│   ├── 30_monitoring_queries.sql          16 blocks: runs, reconciliation, files (MQ-07), errors, progress
│   ├── 31_check_parent_child.sql          header / child configuration and data
│   ├── 32_check_parent_key.sql            ret.RetentionParentKey
│   └── 06_reference_examples_monitoring.sql  examples, all commented out
├── test/                                  ← DEV / TEST only
│   ├── 91_reset_table_for_retest.sql      reset one table after a test Initial Cut-off
│   ├── 92_insert_test_table_config.sql    register test tables
│   └── 93_insert_header_child_config.sql  old example header/child (replaced by config/12)
├── rollback/
│   └── 29_rollback_opsiB.sql              remove the opsi B objects
├── src/                                   ← sources of deploy/20 (not deployed on their own)
│   ├── opsiB_new_objects.sql
│   └── usp_BatchDelete_opsiB.sql
└── tools/
    ├── make_sql_opsiB.py                  builds deploy/20 from deploy/04 + src/
    └── make_full_bundle.py                builds DWH_Retention_FULL_v0.7.1.sql
```

## 2. Deployment

Always: connected to the DWH database, whole file in one session, **no retention run RUNNING**:

```sql
SELECT RunId, ProcessType, Status FROM ret.RetentionRunLog WHERE Status = 'RUNNING';   -- must be empty
```

### A. New (empty) database

| # | Script | Expected |
|---|---|---|
| 1 | `DWH_Retention_FULL_v0.7.1.sql` **or** `deploy/01` → `02` → `03` → `04` → `05` → `20` | No error |
| 2 | `config/00_insert_default_config.sql` with `@ResetToDefault = 1` | Parameter row: BatchSize 20000, pause 2 s, window 21:00–05:00, container `dwh-archive` |
| 3 | `config/10_insert_retention_config.sql` and/or `config/11_…` / `config/12_…` (`@Apply = 0` first, then `1`) | Tables registered, status PENDING |
| 4 | `verify/90_verify_v06_deployment.sql` | Every row OK (38 procedures) |
| 5 | `verify/21_verify_opsiB.sql` | Every row OK |
| 6 | `deploy/07_security_roles_TEMPLATE.sql` | After DBA review only (ADF identity needs EXECUTE on schema `ret`) |

### B. Existing database already on v0.6 (DEV / QA)

| # | Script | Why |
|---|---|---|
| 1 | `deploy/08_patch_v0.6.1_parquet_column_names.sql` | `fn_ParquetColumnName`, `vw_ParquetColumnMap`, `usp_ExportSourceRows`, `usp_BeginTable` (D-6) |
| 2 | `deploy/09_patch_v0.6.2_view_archive_files.sql` | View `vw_MQ07_ArchiveFiles` |
| 3 | `deploy/20_OpsiB_DB_Objects.sql` | **Must run after 08 / 09**: they overwrite `usp_BeginTable` without the `#RetOut_` output that the `PL_RETB_*` pipelines need |
| 4 | `verify/21_verify_opsiB.sql` | Every row OK (38 procedures, ChildDeleteMode, usp_BatchDelete v0.7.1) |
| 5 | `verify/90_verify_v06_deployment.sql` | Every row OK (incl. the objects of 08 / 09) |
| 6 | `config/11_…` / `config/12_…` | Register new tables (`@Apply = 0` first) |

Running `DWH_Retention_FULL_v0.7.1.sql` on such a database has the same result as steps 1–3.

**Rule:** `deploy/20` is always the last object script. After `deploy/04`, `deploy/08` or the full bundle part 04 has run on its own, run `deploy/20` again, otherwise the opsi B pipelines cannot read the procedure results.

## 3. Parameters after deployment

```sql
SELECT BatchSize, BatchPauseSeconds, IcWindowStart, IcWindowEnd, ExportParallelism, ChildDeleteMode,
       DailyRoutineStartDate, ArchiveContainer
FROM ret.RetentionParameter WHERE ParameterSetId = 1;
```

| Parameter | Default | Decision |
|---|---|---|
| BatchSize / BatchPauseSeconds | 20000 / 2 (config/00 v0.2; column defaults in deploy/01 stay 10000 / 3) | D-7 (UAT), to record in FSD v1.2 |
| ExportParallelism | 4 | opsi B (DEC-07 change) |
| ChildDeleteMode | JOIN (`KEY_TABLE` after `verify/22`) | D-8, to record in FSD v1.2 |

**Table order (D-9, 28 Nov 2026, safeguard for tests):** in an explicit `TableConfigIdList` a child table listed after its header is moved directly before the header (`52,53` → 53, 52; `10,52,20,53` → 10, 53, 52, 20). Other tables keep their listed position; the step log `SELECT_TABLES` names every move. A header whose active child is neither COMPLETED nor listed is still SKIPPED (DBR-18). The Daily Routine and the automatic mode (empty list) already process child tables first. FSD says "in the given order": record D-9 in FSD v1.2.

## 4. Changing the SQL

- `deploy/20_OpsiB_DB_Objects.sql` and `DWH_Retention_FULL_v0.7.1.sql` are generated – never edit them by hand.
- After a change of `deploy/04_procedures.sql` or `src/`:

```bash
python3 SQL_Script/tools/make_sql_opsiB.py .      # from the repository root
python3 SQL_Script/tools/make_full_bundle.py .
```

- Change of `usp_BatchDelete`: edit `src/usp_BatchDelete_opsiB.sql` (opsi B source); `deploy/04` keeps the v0.6 text.

## 5. Known limitations

- No SQL Server was available to the author: all scripts are checked statically only.
- Child tables (header / detail) are out of go-live phase 1 (MD-05); activating them is a scope decision.
- Decisions D-6, D-7, D-8, D-9 and the disabled Initial Cut-off window (`IcWindowStart = IcWindowEnd`) are not yet in the FSD.
