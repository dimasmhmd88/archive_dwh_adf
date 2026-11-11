/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - 06_reference_examples_monitoring.sql
   Part of DWH_Retention_DB_Objects_v0.6.sql (DRAFT - not reviewed, not executed against any database).
   COMMENTED OUT: example configuration, example calls, monitoring queries (sections 10-12)
   Deploy order: see pipeline/sql/README.md. Run connected to the DWH database.
   ===================================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

/* =====================================================================================
   10. EXAMPLE CONFIGURATION (COMMENTED OUT)
       Values are illustrations only. Schema, table, column, method and size category come from
       the approved candidate list (FSD Appendix A, D-05); the container name from D-02.
   =====================================================================================
-- Archive container (container name only, MD-07; value to be supplied by the infrastructure team)
UPDATE ret.RetentionParameter SET ArchiveContainer = N'<container-name>' WHERE ParameterSetId = 1;

-- Own-dated table (BRD 7.3 example)
INSERT INTO ret.RetentionConfig
    (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears,
     BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
VALUES
    (N'BOS', N'JTI_SD_BrandDistDetail', N'dtmDate', NULL, 3, 5,
     N'bos.jti_sd_branddistdetail', 'BATCH_DELETE', 1, 'LARGE');            -- method TBD (rebuild candidate)

-- Header table and child table without its own date column (FR-023, MD-05)
DECLARE @HeaderId INT, @ChildId INT;

INSERT INTO ret.RetentionConfig
    (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears,
     BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
VALUES
    (N'<schema>', N'<HeaderTable>', N'<dateColumn>', NULL, 3, 5, N'<schema>.<headertable>', 'BATCH_DELETE', 1, 'MEDIUM');
SET @HeaderId = SCOPE_IDENTITY();

INSERT INTO ret.RetentionConfig
    (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears,
     BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
VALUES
    (N'<schema>', N'<ChildTable>', NULL, @HeaderId, 3, 5, N'<schema>.<childtable>', 'BATCH_DELETE', 1, 'MEDIUM');
SET @ChildId = SCOPE_IDENTITY();

INSERT INTO ret.RetentionParentKey (TableConfigId, KeyOrdinal, ChildColumn, ParentColumn)
VALUES (@ChildId, 1, N'<childKeyColumn1>', N'<headerKeyColumn1>'),
       (@ChildId, 2, N'<childKeyColumn2>', N'<headerKeyColumn2>');

-- Initial Cut-off order: child tables first or earlier in the same list (DBR-18), e.g.
--   EXEC ret.usp_GetTablesToProcess @RunId = <RunId>, @TableConfigIdList = N'<ChildId>,<HeaderId>';
*/

/* =====================================================================================
   11. EXAMPLE CALLS (COMMENTED OUT)
   =====================================================================================
-- Dry validation (V-01..V-11, no data change)
EXEC ret.usp_StartRun @ProcessType = 'VALIDATION', @TriggerType = 'MANUAL', @TriggeredBy = N'<operator>';
EXEC ret.usp_GetTablesToProcess @RunId = <RunId>, @TableConfigIdList = N'1,2';   -- or NULL: all active tables not COMPLETED (v0.6)
EXEC ret.usp_BeginTable @RunId = <RunId>, @TableConfigId = 1;
EXEC ret.usp_EndTable @TableLogId = <TableLogId>;
EXEC ret.usp_EndRun @RunId = <RunId>, @FailPipelineOnError = 0;

-- Table rebuild (IC, downtime reference required)
EXEC ret.usp_StartRun @ProcessType = 'INITIAL_CUTOFF', @TriggerType = 'MANUAL', @TriggeredBy = N'<operator>', @DowntimeReference = N'<CR-number>';
--   usp_GetTablesToProcess -> usp_BeginTable -> usp_IdentifyEligibleData -> usp_TableRebuildPrepare
--   -> export loop -> usp_ValidateArchive -> usp_TableRebuildSwap -> usp_PostCheck -> usp_EndTable
--   on failure before the swap commits: usp_TableRebuildAbort -> file cleanup -> usp_LogCleanupResult -> usp_EndTable

-- Archive expiry (DR-05), level by level
EXEC ret.usp_GetExpiredArchiveFolders @TableLogId = <TableLogId>, @Level = 'YEAR', @ChildItemsJson = N'[{"name":"2017","type":"Folder"},{"name":"2018","type":"Folder"}]';
EXEC ret.usp_GetExpiredArchiveFolders @TableLogId = <TableLogId>, @Level = 'FILE', @Year = 2018, @ChildItemsJson = N'[{"name":"bos.jti_sd_branddistdetail_20181026.parquet","type":"File"},{"name":"bos.jti_sd_branddistdetail_20181027.parquet","type":"File"}]';
-- Files written by one table log (cleanup after a failure)
EXEC ret.usp_GetRunArchiveFiles @TableLogId = <TableLogId>;

-- Activation of the Daily Routine after all Initial Cut-off Runs completed (AC-15)
EXEC ret.usp_ActivateDailyRoutine @Confirm = 1;
*/

/* =====================================================================================
   12. MONITORING QUERIES (FR-015, BRQ-13) (COMMENTED OUT)
   =====================================================================================
-- 12.1 Latest runs
SELECT TOP (20) RunId, ProcessType, RunDate, TriggerType, Status, TablesSelected, TablesSucceeded,
       TablesFailed, TablesSkipped, StartTime, EndTime, ErrorMessage
FROM ret.RetentionRunLog ORDER BY RunId DESC;

-- 12.2 Failed, stopped or skipped tables in the last 7 days
SELECT l.RunId, l.RunDate, l.ProcessType, c.SchemaName, c.TableName, l.Status, l.ErrorCode, l.ErrorStep, l.ErrorMessage
FROM ret.RetentionTableLog AS l JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.Status IN ('FAILED', 'STOPPED', 'SKIPPED') AND l.RunDate >= DATEADD(DAY, -7, ret.fn_TodayUtc7())
ORDER BY l.TableLogId DESC;

-- 12.3 Status and flags per table, with header table of child tables
SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn, h.SchemaName + N'.' + h.TableName AS HeaderTable,
       c.IsActive, c.SizeCategory, c.InitialCutoffMethod, s.InitialCutoffStatus, s.InitialCutoffCompletionDate,
       s.HasOrphanFiles, s.HasIntegrityIssue, s.HasReconciliationWarning, s.FlagComment
FROM ret.RetentionConfig AS c
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
LEFT JOIN ret.RetentionConfig AS h ON h.TableConfigId = c.ParentTableConfigId
ORDER BY COALESCE(c.ParentTableConfigId, c.TableConfigId), c.ParentTableConfigId, c.TableConfigId;

-- 12.4 Pending resume (validated batch-delete ranges not fully deleted)
SELECT l.TableLogId, l.RunId, c.SchemaName, c.TableName, l.ValidatedRangeTo, l.ValidatedRowCount, l.RowsDeleted, l.DeleteStatus
FROM ret.RetentionTableLog AS l JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.IsValidated = 1 AND l.DeleteStatus IN ('NOT_STARTED', 'IN_PROGRESS', 'FAILED');

-- 12.5 Reconciliation per table log (exported vs deleted, orphan child rows)
SELECT l.TableLogId, l.RunDate, c.SchemaName, c.TableName, l.MethodUsed, l.EligibleRows, l.ArchivedSegmentRows, l.ExpiredSegmentRows,
       l.RowsExported, l.RowsDeleted, l.RetainedRowsBefore, l.RetainedRowsAfter, l.OrphanRows, l.ArchiveFilesDeleted, l.Status
FROM ret.RetentionTableLog AS l JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.ProcessType IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE')
ORDER BY l.TableLogId DESC;

-- 12.6 Locks held and leftover rebuild tables
SELECT k.TableConfigId, c.SchemaName, c.TableName, k.RunId, k.ProcessType, k.AcquiredAt, k.AcquiredBy
FROM ret.RetentionTableLock AS k JOIN ret.RetentionConfig AS c ON c.TableConfigId = k.TableConfigId;

SELECT SCHEMA_NAME(t.schema_id) AS SchemaName, t.name AS TableName, t.create_date
FROM sys.tables AS t WHERE t.name LIKE N'%[_][_]RBD[_]%';
*/
