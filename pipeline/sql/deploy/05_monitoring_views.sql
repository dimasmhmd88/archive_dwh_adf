/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - 05_monitoring_views.sql
   Part of DWH_Retention_DB_Objects_v0.6.sql (DRAFT - not reviewed, not executed against any database).
   Monitoring views MQ-01..MQ-06 (section 9b, FSD 4.15 / 11.3)
   Deploy order: see pipeline/sql/README.md. Run connected to the DWH database.
   ===================================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

/* =====================================================================================
   9b. MONITORING VIEWS (FSD 4.15, 11.3, MQ-01..MQ-06) - read-only, role ret_log_reader
       Ordering is given in the query, not in the view, e.g.
         SELECT TOP (20) * FROM ret.vw_MQ01_LatestRuns ORDER BY RunId DESC;
         SELECT * FROM ret.vw_MQ02_FailedTables ORDER BY TableLogId DESC;
         SELECT * FROM ret.vw_MQ05_Reconciliation WHERE RunDate = CAST(DATEADD(DAY, -1, ret.fn_TodayUtc7()) AS DATE);
   ===================================================================================== */

-- MQ-01 Runs with status and counters
CREATE OR ALTER VIEW ret.vw_MQ01_LatestRuns
AS
SELECT RunId, ProcessType, RunDate, TriggerType, Status, TablesSelected, TablesSucceeded,
       TablesFailed, TablesSkipped, StartTime, EndTime, ErrorMessage
FROM ret.RetentionRunLog;
GO

-- MQ-02 Failed, stopped or skipped tables of the last 7 days
CREATE OR ALTER VIEW ret.vw_MQ02_FailedTables
AS
SELECT l.TableLogId, l.RunId, l.RunDate, l.ProcessType, c.SchemaName, c.TableName,
       l.Status, l.ErrorCode, l.ErrorStep, l.ErrorMessage
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.Status IN ('FAILED', 'STOPPED', 'SKIPPED')
  AND l.RunDate >= DATEADD(DAY, -7, ret.fn_TodayUtc7());
GO

-- MQ-03 Status and flags per table, with the header of child tables
CREATE OR ALTER VIEW ret.vw_MQ03_TableStatus
AS
SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn,
       h.SchemaName + N'.' + h.TableName AS HeaderTable, c.IsActive, c.SizeCategory,
       c.InitialCutoffMethod, c.LogRetentionYears, s.InitialCutoffStatus, s.InitialCutoffCompletionDate,
       s.HasOrphanFiles, s.HasIntegrityIssue, s.HasReconciliationWarning, s.FlagComment
FROM ret.RetentionConfig AS c
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
LEFT JOIN ret.RetentionConfig AS h ON h.TableConfigId = c.ParentTableConfigId;
GO

-- MQ-04 Validated ranges not fully deleted (pending resume)
CREATE OR ALTER VIEW ret.vw_MQ04_PendingResume
AS
SELECT l.TableLogId, l.RunId, c.SchemaName, c.TableName, l.ValidatedRangeTo,
       l.ValidatedRowCount, l.RowsDeleted, l.DeleteStatus
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.IsValidated = 1 AND l.DeleteStatus IN ('NOT_STARTED', 'IN_PROGRESS', 'FAILED');
GO

-- MQ-05 Reconciliation per table run
CREATE OR ALTER VIEW ret.vw_MQ05_Reconciliation
AS
SELECT l.TableLogId, l.RunId, l.RunDate, c.SchemaName, c.TableName, l.MethodUsed, l.EligibleRows,
       l.ArchivedSegmentRows, l.ExpiredSegmentRows, l.RowsExported, l.RowsDeleted,
       l.RetainedRowsBefore, l.RetainedRowsAfter, l.OrphanRows,
       l.ArchiveFoldersDeleted, l.ArchiveFilesDeleted, l.Status
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.ProcessType IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE');
GO

-- MQ-06 Locks held and leftover __RBD_ tables. Catalog names are converted to the database collation
-- (UNION with configuration columns); create_date is UTC and is shown in UTC+7.
CREATE OR ALTER VIEW ret.vw_MQ06_LocksAndRebuildTables
AS
SELECT N'LOCK' AS ItemType, c.SchemaName, c.TableName, k.RunId, k.ProcessType,
       k.AcquiredAt AS SinceUtc7, k.AcquiredBy
FROM ret.RetentionTableLock AS k
JOIN ret.RetentionConfig AS c ON c.TableConfigId = k.TableConfigId
UNION ALL
SELECT N'REBUILD_TABLE', CONVERT(SYSNAME, SCHEMA_NAME(t.schema_id)) COLLATE DATABASE_DEFAULT, t.name COLLATE DATABASE_DEFAULT,
       NULL, NULL, CONVERT(DATETIME2(3), DATEADD(HOUR, 7, t.create_date)), NULL
FROM sys.tables AS t
WHERE t.name COLLATE DATABASE_DEFAULT LIKE N'%[_][_]RBD[_]%';
GO
