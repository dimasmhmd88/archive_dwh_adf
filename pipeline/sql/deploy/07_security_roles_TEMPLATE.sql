/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - 07_security_roles_TEMPLATE.sql
   Part of DWH_Retention_DB_Objects_v0.6.sql (DRAFT - not reviewed, not executed against any database).
   COMMENTED OUT TEMPLATE: roles and grants (section 13) and optional temporal history (section 14). Review with the DBA; replace placeholders.
   Deploy order: see pipeline/sql/README.md. Run connected to the DWH database.
   ===================================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

/* =====================================================================================
   13. SECURITY (SEC-02..SEC-05) - REVIEW WITH THE DBA BEFORE USE (COMMENTED OUT)
       Procedures that read or change DWH tables run WITH EXECUTE AS OWNER (dynamic SQL breaks
       ownership chaining). The ADF identity needs EXECUTE only, no direct rights on DWH tables.
       The owner (dbo) needs the rights used by the rebuild: CREATE TABLE, ALTER, DROP, sp_rename,
       DBCC CHECKIDENT, GRANT on the rebuilt table (dbo has them).
       Internal procedures (usp_WriteStepLog, usp_SetTableError, usp_GetTableSqlParts,
       usp_AbortRunRebuilds, usp_PurgeTableLogs, usp_PurgeRunLogs) are not granted to anyone.
       Database user of the ADF connection: FSD SEC-01 uses the factory managed identity (FROM EXTERNAL
       PROVIDER). If the linked service (e.g. Agus_SqlServer_dwh, type SQL Server) signs in with an SQL
       login instead, create that user with FOR LOGIN (or as a contained user) and add it to
       ret_adf_executor - deviation from SEC-01 to be recorded (review decision D-2).
   =====================================================================================
CREATE USER [<adf-managed-identity-name>] FROM EXTERNAL PROVIDER;

CREATE ROLE ret_adf_executor;
GRANT EXECUTE ON ret.usp_StartRun                   TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_GetTablesToProcess         TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_BeginTable                 TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_GetPendingResume           TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_IdentifyEligibleData       TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_GetExportPlan              TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_ExportSourceRows           TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_CheckExecutionWindow       TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_LogExportResult            TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_ValidateArchive            TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_BatchDelete                TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_TableRebuildPrepare        TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_TableRebuildSwap           TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_TableRebuildAbort          TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_PostCheck                  TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_GetExpiredArchiveFolders   TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_LogExpiredArchiveResult    TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_LogCleanupResult           TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_GetRunArchiveFiles         TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_EndTable                   TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_EndRun                     TO ret_adf_executor;
ALTER ROLE ret_adf_executor ADD MEMBER [<adf-managed-identity-name>];

CREATE ROLE ret_config_editor;                                  -- Customer users (SEC-03)
GRANT SELECT, INSERT ON ret.RetentionConfig TO ret_config_editor;
GRANT UPDATE ON ret.RetentionConfig (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears,
      BlobRetentionYears, BlobPath, InitialCutoffMethod, IsActive, SizeCategory) TO ret_config_editor;
GRANT SELECT, INSERT, UPDATE, DELETE ON ret.RetentionParentKey TO ret_config_editor;   -- protected by trigger after archiving starts
GRANT SELECT ON ret.RetentionTableStatus TO ret_config_editor;

CREATE ROLE ret_log_reader;                                     -- Operations team (SEC-04)
GRANT SELECT ON SCHEMA::ret TO ret_log_reader;

CREATE ROLE ret_operator_admin;                                 -- operator procedures (TBC who)
GRANT EXECUTE ON ret.usp_AdminCloseStaleRun     TO ret_operator_admin;
GRANT EXECUTE ON ret.usp_AdminClearTableFlag    TO ret_operator_admin;
GRANT EXECUTE ON ret.usp_ActivateDailyRoutine   TO ret_operator_admin;
GRANT EXECUTE ON ret.usp_ListCandidateTables    TO ret_operator_admin;
GRANT EXECUTE ON ret.usp_ProfileRetentionColumn TO ret_operator_admin;
*/

/* =====================================================================================
   14. OPTIONAL - change history of the configuration tables (SEC-08) (COMMENTED OUT)
       Period columns are in UTC (engine behaviour). Note: usp_TableRebuildPrepare rejects temporal
       tables only for DWH tables being rebuilt; ret tables are never rebuilt.
   =====================================================================================
ALTER TABLE ret.RetentionConfig ADD
    ValidFromUtc DATETIME2(3) GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
        CONSTRAINT DF_RetentionConfig_ValidFrom DEFAULT (SYSUTCDATETIME()),
    ValidToUtc   DATETIME2(3) GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL
        CONSTRAINT DF_RetentionConfig_ValidTo   DEFAULT (CONVERT(DATETIME2(3), '9999-12-31 23:59:59.999')),
    PERIOD FOR SYSTEM_TIME (ValidFromUtc, ValidToUtc);
GO
ALTER TABLE ret.RetentionConfig
    SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = ret.RetentionConfigHistory));
GO
*/
