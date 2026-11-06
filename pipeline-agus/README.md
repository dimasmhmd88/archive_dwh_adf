# ADF Pipeline – DWH Data Retention and Archiving – variant `pipeline-agus`

| Item | Value |
|---|---|
| Based on | `pipeline/` (package v0.2, folder structure `DWH Retention` / `DWH Retention/Internal`, main 7c9f148) |
| Date | 6 November 2026 |
| Status | **Draft, not approved. Not imported or executed in any Data Factory.** |
| Difference | Uses the two linked services that **already exist in the factory** (created by the user) instead of `LS_RET_AzureSqlDb` / `LS_RET_ArchiveBlob` |

Pipeline logic, activities, parameters, folders, timeouts and the trigger are identical to `pipeline/`. Only the connection layer changed.

## 1. Changes compared with `pipeline/`

| Object | `pipeline/` | `pipeline-agus/` |
|---|---|---|
| Linked service – database | `LS_RET_AzureSqlDb`, type Azure SQL Database (generated) | **`Agus_SqlServer_dwh`**, type **SQL Server** (exists, not in the package) |
| Linked service – storage | `LS_RET_ArchiveBlob`, type Azure Blob Storage (generated) | **`Agus_AzureBlobStorage1`**, type Azure Blob Storage, storage account **`stormsfsax01loc10dev`** (exists, not in the package) |
| Dataset `DS_RET_SqlDb` | type `AzureSqlTable` | type **`SqlServerTable`** → `Agus_SqlServer_dwh` |
| Datasets `DS_RET_ArchiveParquet`, `DS_RET_ArchiveFolder` | → `LS_RET_ArchiveBlob` | → **`Agus_AzureBlobStorage1`** |
| Source of the 38 Lookup / Copy activities | `AzureSqlSource` | **`SqlServerSource`** (same stored-procedure calls and query timeouts) |
| `adf/linkedService/` | 2 files | **none** – importing must not overwrite the user's linked services |
| ARM template | 17 resources, parameters for SQL server, database, storage account, IR | **15 resources** (no linked services); parameters `factoryName` and `dailyRoutineTriggerStartTime` only |

`tools/validate_adf.py`: 0 errors, 0 warnings. The two linked services are treated as external.

## 2. Contents

```
adf/dataset/      DS_RET_SqlDb, DS_RET_ArchiveParquet, DS_RET_ArchiveFolder   (folder "DWH Retention")
adf/pipeline/     11 pipelines: 01, 02 in "DWH Retention"; 03, 03A–03F, 04, 04A in "DWH Retention/Internal"
adf/trigger/      TR_RET_DailyRoutine_2100_WIB (Stopped)
arm/              ARMTemplateForFactory.json + ARMTemplateParametersForFactory.json
tools/            build_adf.py (variant generator), validate_adf.py, sql_contract.json
```

SQL scripts and the design document are not duplicated. Use `../pipeline/sql/` (deploy order in `../pipeline/sql/README.md`) and `../pipeline/docs/`.

## 3. Prerequisites to check on the existing linked services

1. **Names exactly** `Agus_SqlServer_dwh` and `Agus_AzureBlobStorage1` (case-sensitive), otherwise the datasets do not resolve.
2. **`Agus_SqlServer_dwh`**
   - points to the DWH database that contains schema `ret`
   - its login (SQL login or identity) is a database user in role `ret_adf_executor`
   - `../pipeline/sql/deploy/06_security_roles_TEMPLATE.sql` uses `CREATE USER … FROM EXTERNAL PROVIDER` for a managed identity. For an SQL login, create the user `FOR LOGIN` (or as a contained user) instead – review with the DBA.
3. **Integration runtime of `Agus_SqlServer_dwh`**
   - If it uses a **self-hosted IR**, the Copy activities (SQL → Parquet) run on that IR. The IR machine then needs a 64-bit **Java runtime** (JRE or OpenJDK) for Parquet, and outbound HTTPS access to `stormsfsax01loc10dev.blob.core.windows.net`.
   - With the Azure IR nothing extra is needed.
4. **`Agus_AzureBlobStorage1`**
   - needs read, write, list and delete on the archive container (e.g. *Storage Blob Data Contributor* for its identity, or a key / SAS with these rights)
   - the container name itself is not in ADF: it is read from `ret.RetentionParameter.ArchiveContainer`:
     `UPDATE ret.RetentionParameter SET ArchiveContainer = N'<container>' WHERE ParameterSetId = 1;`

## 4. Import (ADF Studio)

1. Test connection of `Agus_SqlServer_dwh` and `Agus_AzureBlobStorage1` (Manage → Linked services).
2. Datasets: Author → + → Dataset. Choose **SQL Server** for `DS_RET_SqlDb` and **Azure Blob Storage** (Parquet / Binary) for the other two. Open Code `{}` and replace the JSON with the file content.
3. Pipelines: Author → + → Pipeline → Code `{}`, in this order:
   03F, 03E, 03C, 03D, 03B, 03A, 04A, 04, 03, 01, 02.
   The folder comes from the JSON.
4. Trigger `TR_RET_DailyRoutine_2100_WIB`: daily 21:00, (UTC+07:00) Bangkok, Hanoi, Jakarta. Leave it **Stopped**.
5. Validate all → Publish all.

ARM alternative: Manage → ARM template → Import → `arm/ARMTemplateForFactory.json`. The linked services must already exist in the target factory.

The verification checks V-01..V-09 and operating notes in `../pipeline/README.md` sections 6–7 apply unchanged. V-02 now means the test connection of the two `Agus_*` linked services.

## 5. Regenerating

```
python3 tools/build_adf.py <output-folder>
python3 tools/validate_adf.py <output-folder>
```
