# ADF Pipeline – DWH Data Retention and Archiving – variant `pipeline-agus` (v0.3)

| Item | Value |
|---|---|
| Version | 0.3 – 11 November 2026 (v0.2: 6 Nov 2026) |
| Reference | FSD_DWH_Data_Retention_v1.1 (FSD-DWH-RET v1.1, 10 Nov 2026, *Draft for Review*, not approved). Also the review "pipeline-agus vs FSD v1.1" with decisions D-1..D-4 (11 Nov 2026). |
| SQL | `../pipeline/sql/DWH_Retention_DB_Objects_v0.6.sql` and `../pipeline/sql/config/10_insert_retention_config.sql` v0.2 |
| Status | **Draft, not approved. Not imported or run in any Data Factory.** |
| Difference from `pipeline/` | Uses the linked services that **already exist in the factory**, created by the user (decision D-2). Pipeline logic is identical. |

## 1. Connections (decisions D-2 and D-4)

| Linked service | Type | Target | Status |
|---|---|---|---|
| `Agus_SqlServer_dwh` | SQL Server | DWH database (Azure SQL Database, schema `ret`) | Exists; test connection succeeded (user). IR: `AutoResolveIntegrationRuntime` (D-4). |
| `Agus_AzureBlobStorage1` | Azure Blob Storage | Storage account `stormsfsax01loc10dev`, container `dwh-archive` | Exists |

- The linked services are **not part of this package**: there are no files in `adf/linkedService/` and they are not in the ARM template. Importing therefore never overwrites them.
- `DS_RET_SqlDb` is of type `SqlServerTable`. The 38 Lookup and Copy sources are of type `SqlServerSource`.
- The SQL Server connector against Azure SQL Database is an accepted deviation from FSD 6.1 (`LS_RET_AzureSqlDb`, managed identity, SEC-01/05/06). It must be recorded in the FSD.
- With the Azure IR, no Java runtime is needed for Parquet.

## 2. Changes in v0.3 (alignment with FSD v1.1)

| Pipeline | FSD | Change |
|---|---|---|
| `PL_RET_01_InitialCutoff_Master` | 4.2, 4.11, **D-3** | New parameter **`ValidateOnly`** (bool, default false). When true, the run is a dry validation with process type VALIDATION. |
| `PL_RET_01` / `PL_RET_02` | 6.1 | Variable `vProcessType` is taken from `usp_StartRun` and passed to PL_RET_03. |
| `PL_RET_03F_Table_FileCleanup` | 4.18, 5.4, 6.1 | `usp_GetRunArchiveFiles` → ForEach (parallel, batch 4): folder exists? → Delete exactly `<FolderPath>/<FileName>` → `usp_LogCleanupResult`. The old pattern `*_<RunId>.parquet` is removed. |
| `PL_RET_04_ArchiveExpiry` | 4.13, 5.4 | 2 levels instead of 3: **YEAR** (container root), then **FILE** (`<cut-off year>/<BlobPath>`). |
| `PL_RET_04A_ArchiveExpiry_Level` | 4.13, 6.1, 6.2 | Parameters Level YEAR/FILE and CutoffYear. Get Metadata → `usp_GetExpiredArchiveFolders` → Filter DELETE → ForEach (parallel 4): exists? → Delete. YEAR deletes the folder `<yyyy>/<BlobPath>` recursively; FILE deletes one file. Counters are ArchiveFoldersDeleted / ArchiveFilesDeleted. |
| All | 1.6 | Annotations `FSD-DWH-RET v1.1`, `SQL v0.6`. Older requirement IDs in activity descriptions (FR-0nn, DBR-nn) use the FSD v0.2 numbering. |

These parts of FSD v1.1 are implemented in SQL v0.6 and need no pipeline change:
- archive layout MD-07: the Copy activity takes FolderPath and FileName from `usp_GetExportPlan`
- D-1 / ERR-EXP-02
- log retention MD-08 (inside `usp_EndTable` / `usp_EndRun`)
- monitoring views

`tools/validate_adf.py` reports 0 errors and 0 warnings. The scenario checks include:
- ValidateOnly
- the FILE-level folder `2018/bos.jti_sd_branddistdetail`
- the Delete wildcard (`*` for a folder, the exact file name for a file)

## 3. Dry validation (decision D-3, option A)

```
PL_RET_01_InitialCutoff_Master   ValidateOnly = true
                                 TableConfigIdList = ""   (empty = all active tables not COMPLETED)
                                 DowntimeReference        ignored
 └ usp_StartRun (VALIDATION) → usp_GetTablesToProcess → per table PL_RET_03:
     usp_BeginTable: lock, checks V-01..V-11 (NULL count and join-key duplicates always counted)
     no count, export or delete (PL_RET_03A is skipped)
     usp_EndTable: SUCCEEDED, or FAILED with ERR-CFG-nn; lock released
 └ usp_EndRun: SUCCEEDED only when every table passed; otherwise the ADF run is shown as failed
```

- **Pass criterion:** every table planned for the Initial Cut-off ended SUCCEEDED in the latest VALIDATION run. Check with `ret.vw_MQ02_FailedTables` and `ret.RetentionTableLog` where ProcessType = 'VALIDATION'.
- **Side effects:** the Initial Cut-off status is not changed, and leftover rebuild tables are only reported.
- **Timing:** V-04 and V-11 scan whole tables. Run the dry validation for LARGE tables inside 21:00–05:00.

## 4. Contents

```
adf/dataset/      DS_RET_SqlDb (SqlServerTable), DS_RET_ArchiveParquet, DS_RET_ArchiveFolder   folder "DWH Retention"
adf/pipeline/     11 pipelines: 01, 02 in "DWH Retention"; 03, 03A–03F, 04, 04A in "DWH Retention/Internal"
adf/trigger/      TR_RET_DailyRoutine_2100_WIB (Stopped, start 2026-12-01 21:00 SE Asia Standard Time)
arm/              ARMTemplateForFactory.json (15 resources, no linked services) + parameter file
tools/            build_adf.py (generator), validate_adf.py, sql_contract.json (SQL v0.6)
```

## 5. Prerequisites

1. SQL v0.6 is deployed and `config/10_insert_retention_config.sql` v0.2 has been run (`../pipeline/sql/README.md`).
2. The login of `Agus_SqlServer_dwh` is a database user in role `ret_adf_executor` (`deploy/07_security_roles_TEMPLATE.sql`), including EXECUTE on `usp_GetRunArchiveFiles`.
3. `ret.RetentionParameter.ArchiveContainer = 'dwh-archive'`, and the container exists in `stormsfsax01loc10dev`.
4. `Agus_AzureBlobStorage1` may read, write, list and delete in `dwh-archive`.

## 6. Import (ADF Studio)

The factory has Git enabled (Azure DevOps). Changes are made in Git mode on a branch, merged through a pull request into the collaboration branch, and then published by someone with publish rights.

Create the objects in this order:

| Step | Objects |
|---|---|
| 1 | Datasets: `DS_RET_SqlDb` (SQL Server), `DS_RET_ArchiveParquet` (Blob, Parquet), `DS_RET_ArchiveFolder` (Blob, Binary). In each, paste the JSON into Code `{}`. |
| 2 | Pipelines, in this order: 03F, 03E, 03C, 03D, 03B, 03A, 04A, 04, 03, 01, 02 |
| 3 | Trigger `TR_RET_DailyRoutine_2100_WIB`, left **Stopped** |
| 4 | Validate all → Save all → pull request → Publish |

If v0.2 was already imported: replace the JSON of **03F, 04, 04A, 01, 02** (other pipelines only have new annotations). The parameters of PL_RET_04A changed: `CutoffMonth` was removed.

## 7. Regenerating

```
python3 tools/build_adf.py <output-folder>
python3 tools/validate_adf.py <output-folder>
```
