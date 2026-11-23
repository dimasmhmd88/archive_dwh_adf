/* =====================================================================================
   DWH Data Retention and Archiving - monitoring queries (schema ret, SQL v0.6.1 / opsi B)
   -------------------------------------------------------------------------------------
   Script  : pipeline/sql/monitoring/30_monitoring_queries.sql   Version 0.2 (DRAFT, not executed)   23 November 2026
   Read-only. Run one block at a time. Set the variables in block 0 first.

   VIEWS (schema ret)
     vw_MQ01_LatestRuns            runs: status and table counters
     vw_MQ02_FailedTables          FAILED / STOPPED / SKIPPED tables of the last 7 days
     vw_MQ03_TableStatus           Initial Cut-off status and flags per table
     vw_MQ04_PendingResume         validated ranges not yet fully deleted
     vw_MQ05_Reconciliation        rows eligible / exported / deleted / retained per table run
     vw_MQ06_LocksAndRebuildTables table locks held, leftover __RBD_ tables
     vw_MQ07_ArchiveFiles          row counts per Parquet file: DWH / read / written, path, status (v0.6.2)
     vw_ParquetColumnMap           source column -> column in the Parquet file (D-6)

   BLOCKS
      0  Variables
      1  Last runs                                  9  Configuration overview
      2  Tables of one run (reconciliation)        10  Daily Routine readiness
      3  Files of one run (row counts per file)    11  Eligible data preview (one table)
      4  Errors and skipped tables                 12  Archive inventory per table and year
      5  Step log of one run                       13  Duration and performance per table
      6  Flags, pending resume, locks              14  Expired archive deletion (Daily Routine)
      7  Live progress of a running table          15  Parquet column renaming (D-6)
      8  Stale RUNNING runs                        16  Log volume (log retention)
   ===================================================================================== */
SET NOCOUNT ON;

/* ---- 0. Variables ---- */
DECLARE @RunId BIGINT = (SELECT MAX(RunId) FROM ret.RetentionRunLog);   -- or a fixed RunId
DECLARE @TableConfigId INT = NULL;                                       -- NULL = all tables
DECLARE @Days INT = 7;                                                   -- look-back for block 1 / 4

/* ---- 1. Last runs (incl. who started them) ---- */
SELECT r.RunId, r.ProcessType, r.RunDate, r.TriggerType, r.TriggeredBy, r.DowntimeReference, r.Status,
       r.TablesSelected, r.TablesSucceeded, r.TablesFailed, r.TablesSkipped,
       r.StartTime, r.EndTime, DATEDIFF(MINUTE, r.StartTime, ISNULL(r.EndTime, ret.fn_NowUtc7())) AS Minutes,
       r.ErrorMessage
FROM ret.RetentionRunLog AS r
WHERE r.RunDate >= DATEADD(DAY, -@Days, ret.fn_TodayUtc7())
ORDER BY r.RunId DESC;

/* ---- 2. Tables of one run: reconciliation (EligibleRows = RowsExported + expired rows = RowsDeleted) ---- */
SELECT v.*, CASE WHEN v.Status IN ('SUCCEEDED', 'NODATA')
                  AND ISNULL(v.RowsDeleted, 0) = ISNULL(v.EligibleRows, 0) THEN 'OK' ELSE 'CHECK' END AS ReconCheck
FROM ret.vw_MQ05_Reconciliation AS v
WHERE v.RunId = @RunId
ORDER BY v.TableLogId;

/* ---- 3. Files of one run: row counts per Parquet file (view MQ-07, patch v0.6.2) ---- */
IF OBJECT_ID(N'ret.vw_MQ07_ArchiveFiles', N'V') IS NOT NULL
    EXEC sp_executesql N'SELECT ProcessDate, ProcessType, SchemaName + N''.'' + TableName AS TableName, DataDate,
                                RowCountDwh, RowCountRead, RowCountParquet, RowDifference, RowCountMatch,
                                FileCount, ExportStatus, ValidationResult, FilePath, ExportStartTime, ExportEndTime,
                                ExportSeconds, ErrorMessage
                         FROM ret.vw_MQ07_ArchiveFiles
                         WHERE RunId = @RunId AND (@Tc IS NULL OR TableConfigId = @Tc)
                         ORDER BY TableName, DataDate;', N'@RunId BIGINT, @Tc INT', @RunId = @RunId, @Tc = @TableConfigId;
ELSE
    SELECT N'ret.vw_MQ07_ArchiveFiles not found: run pipeline/sql/deploy/09_patch_v0.6.2_view_archive_files.sql.' AS Warning;

-- 3a. All files with a row-count mismatch or a failed export (any run) - should be empty
IF OBJECT_ID(N'ret.vw_MQ07_ArchiveFiles', N'V') IS NOT NULL
    EXEC (N'SELECT * FROM ret.vw_MQ07_ArchiveFiles
            WHERE ExportStatus IN (''SUCCEEDED'', ''FAILED'') AND RowCountMatch = 0
            ORDER BY RunId DESC, SchemaName, TableName, DataDate;');

-- 3b. Summary per table of the run (dates / files / rows, mismatches)
SELECT c.SchemaName + N'.' + c.TableName AS TableName, a.ExportStatus,
       COUNT(*) AS Dates, SUM(a.FileCount) AS Files, SUM(a.ExpectedRows) AS RowsDwh, SUM(a.RowsWritten) AS RowsParquet,
       SUM(CASE WHEN a.RowsWritten <> a.ExpectedRows OR a.RowsRead <> a.ExpectedRows THEN 1 ELSE 0 END) AS DatesWithMismatch
FROM ret.RetentionArchiveDate AS a
JOIN ret.RetentionConfig AS c ON c.TableConfigId = a.TableConfigId
WHERE a.RunId = @RunId
GROUP BY c.SchemaName, c.TableName, a.ExportStatus
ORDER BY TableName, a.ExportStatus;

/* ---- 4. Errors and skipped tables (last @Days days) ---- */
SELECT * FROM ret.vw_MQ02_FailedTables ORDER BY TableLogId DESC;

-- 4b. Error codes with their meaning
SELECT l.RunId, c.SchemaName + N'.' + c.TableName AS TableName, l.Status, l.ErrorCode, e.Category, e.Description,
       l.ErrorStep, l.ErrorMessage
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
LEFT JOIN ret.RetentionErrorCode AS e ON e.ErrorCode = l.ErrorCode
WHERE l.ErrorCode IS NOT NULL AND l.RunDate >= DATEADD(DAY, -@Days, ret.fn_TodayUtc7())
ORDER BY l.TableLogId DESC;

/* ---- 5. Step log of one run (process trail) ---- */
SELECT s.StepLogId, c.SchemaName + N'.' + c.TableName AS TableName, s.StepCode, s.ValidationCheckCode, s.Status,
       s.BusinessDate, s.ExpectedRows, s.RowsRead, s.RowsWritten, s.RowsProcessed, s.BatchCount, s.FileCount,
       s.FilePath, s.Message, s.ErrorCode, s.ErrorMessage, s.StartTime, s.EndTime
FROM ret.RetentionStepLog AS s
LEFT JOIN ret.RetentionConfig AS c ON c.TableConfigId = s.TableConfigId
WHERE s.RunId = @RunId
  AND (@TableConfigId IS NULL OR s.TableConfigId = @TableConfigId)
ORDER BY s.StepLogId;

/* ---- 6. Flags, pending resume, locks (all should be empty) ---- */
SELECT * FROM ret.vw_MQ03_TableStatus
WHERE HasOrphanFiles = 1 OR HasIntegrityIssue = 1 OR HasReconciliationWarning = 1;
SELECT * FROM ret.vw_MQ04_PendingResume;
SELECT * FROM ret.vw_MQ06_LocksAndRebuildTables;

/* ---- 7. Live progress of a running table (export + batch delete) ---- */
SELECT l.TableLogId, l.RunId, c.SchemaName + N'.' + c.TableName AS TableName, l.Status,
       l.ExportDateCount,
       (SELECT COUNT(*) FROM ret.RetentionArchiveDate AS a WHERE a.TableLogId = l.TableLogId AND a.ExportStatus = 'SUCCEEDED') AS DatesExported,
       (SELECT COUNT(*) FROM ret.RetentionArchiveDate AS a WHERE a.TableLogId = l.TableLogId AND a.ExportStatus = 'PENDING')   AS DatesPending,
       l.IsValidated, l.ValidatedRowCount, l.DeleteStatus, l.RowsDeleted, l.DeleteBatchCount,
       CAST(100.0 * ISNULL(l.RowsDeleted, 0) / NULLIF(l.ValidatedRowCount, 0) AS DECIMAL(5, 1)) AS PctDeleted,
       DATEDIFF(MINUTE, l.StartTime, ret.fn_NowUtc7()) AS MinutesRunning
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.Status = 'RUNNING'
ORDER BY l.TableLogId;

/* ---- 8. Stale RUNNING runs (ADF run cancelled or crashed) -> ret.usp_AdminCloseStaleRun ---- */
SELECT RunId, ProcessType, RunDate, TriggeredBy, StartTime, DATEDIFF(HOUR, StartTime, ret.fn_NowUtc7()) AS HoursRunning
FROM ret.RetentionRunLog
WHERE Status = 'RUNNING' AND StartTime < DATEADD(HOUR, -12, ret.fn_NowUtc7());

/* ---- 9. Configuration overview ---- */
SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn, c.SizeCategory, c.InitialCutoffMethod,
       c.IsActive, c.DwhRetentionYears, c.BlobRetentionYears, c.LogRetentionYears, c.BlobPath,
       s.InitialCutoffStatus, s.InitialCutoffCompletionDate
FROM ret.RetentionConfig AS c
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
WHERE (@TableConfigId IS NULL OR c.TableConfigId = @TableConfigId)
ORDER BY c.IsActive DESC, c.SizeCategory, c.TableConfigId;

SELECT BatchSize, BatchPauseSeconds, CONVERT(CHAR(5), IcWindowStart, 108) AS IcWindowStart,
       CONVERT(CHAR(5), IcWindowEnd, 108) AS IcWindowEnd, DailyRoutineStartDate, DeleteRetryCount,
       DeleteLockTimeoutMs, DailyNullCheckMode, ArchiveContainer, ModifiedBy, ModifiedAt
FROM ret.RetentionParameter WHERE ParameterSetId = 1;

-- 9b. Opsi B only: export parallelism N (global and per table)
IF COL_LENGTH(N'ret.RetentionParameter', N'ExportParallelism') IS NOT NULL
    EXEC (N'SELECT p.ExportParallelism AS GlobalN, c.TableConfigId, c.SchemaName, c.TableName,
                   c.ExportParallelism AS TableN, ISNULL(c.ExportParallelism, p.ExportParallelism) AS EffectiveN
            FROM ret.RetentionConfig AS c CROSS JOIN ret.RetentionParameter AS p
            WHERE p.ParameterSetId = 1 AND c.IsActive = 1 ORDER BY c.TableConfigId;');

/* ---- 10. Daily Routine readiness (which tables the next Daily Routine of today will process) ---- */
SELECT c.TableConfigId, c.SchemaName + N'.' + c.TableName AS TableName, c.IsActive, s.InitialCutoffStatus,
       s.InitialCutoffCompletionDate, p.DailyRoutineStartDate,
       CASE WHEN p.DailyRoutineStartDate IS NULL THEN 'NO - Daily Routine not activated (usp_ActivateDailyRoutine)'
            WHEN p.DailyRoutineStartDate > ret.fn_TodayUtc7() THEN 'NO - starts ' + CONVERT(CHAR(10), p.DailyRoutineStartDate, 23)
            WHEN c.IsActive = 0 THEN 'NO - inactive'
            WHEN s.InitialCutoffStatus <> 'COMPLETED' THEN 'NO - Initial Cut-off ' + s.InitialCutoffStatus
            WHEN s.InitialCutoffCompletionDate >= ret.fn_TodayUtc7() THEN 'NO - completed today, from tomorrow'
            ELSE 'YES' END AS InDailyRoutineToday
FROM ret.RetentionConfig AS c
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
CROSS JOIN ret.RetentionParameter AS p
WHERE p.ParameterSetId = 1
ORDER BY c.IsActive DESC, c.TableConfigId;

/* ---- 11. Eligible data preview for one table (same cut-off rule as the pipeline; no change) ---- */
--     ret.usp_ProfileRetentionColumn and ret.usp_ListCandidateTables can also be used (FR-022).
IF @TableConfigId IS NOT NULL
BEGIN
    DECLARE @Sch SYSNAME, @Tab SYSNAME, @Col SYSNAME, @Dwh DATE, @Arc DATE, @sql NVARCHAR(MAX);
    SELECT @Sch = c.SchemaName, @Tab = c.TableName, @Col = c.RetentionColumn,
           @Dwh = co.DwhCutoffDate, @Arc = co.ArchiveCutoffDate
    FROM ret.RetentionConfig AS c
    CROSS APPLY ret.fn_GetCutoffDates(ret.fn_TodayUtc7(), c.DwhRetentionYears, c.BlobRetentionYears) AS co
    WHERE c.TableConfigId = @TableConfigId AND c.RetentionColumn IS NOT NULL;

    SET @sql = N'WITH d AS (SELECT CAST(' + QUOTENAME(@Col) + N' AS DATE) AS BusinessDate, COUNT_BIG(*) AS RowCnt
                            FROM ' + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tab) + N' GROUP BY CAST(' + QUOTENAME(@Col) + N' AS DATE))
                 SELECT @Arc AS ArchiveCutoff, @Dwh AS DwhCutoff,
                        ISNULL(SUM(CASE WHEN BusinessDate < @Arc THEN RowCnt END), 0) AS ExpiredRows,
                        ISNULL(SUM(CASE WHEN BusinessDate >= @Arc AND BusinessDate < @Dwh THEN RowCnt END), 0) AS ArchivedRows,
                        COUNT(CASE WHEN BusinessDate >= @Arc AND BusinessDate < @Dwh THEN 1 END) AS ArchivedFiles,
                        ISNULL(SUM(CASE WHEN BusinessDate >= @Dwh THEN RowCnt END), 0) AS RetainedRows,
                        ISNULL(SUM(CASE WHEN BusinessDate IS NULL THEN RowCnt END), 0) AS NullDates
                 FROM d;';
    IF @sql IS NOT NULL EXEC sp_executesql @sql, N'@Dwh DATE, @Arc DATE', @Dwh = @Dwh, @Arc = @Arc;
END;

/* ---- 12. Archive inventory per table and year (files currently kept in Blob) ---- */
SELECT c.SchemaName + N'.' + c.TableName AS TableName, YEAR(a.BusinessDate) AS ArchiveYear,
       COUNT(*) AS Files, SUM(a.RowsWritten) AS Rows, MIN(a.BusinessDate) AS FirstDate, MAX(a.BusinessDate) AS LastDate
FROM ret.RetentionArchiveDate AS a
JOIN ret.RetentionConfig AS c ON c.TableConfigId = a.TableConfigId
WHERE a.ExportStatus = 'SUCCEEDED'
  AND (@TableConfigId IS NULL OR a.TableConfigId = @TableConfigId)
GROUP BY c.SchemaName, c.TableName, YEAR(a.BusinessDate)
ORDER BY TableName, ArchiveYear;

-- 12b. The same business date archived more than once (should be empty; D-1)
SELECT a.TableConfigId, a.BusinessDate, COUNT(*) AS Times, STRING_AGG(CONVERT(NVARCHAR(20), a.RunId), N', ') AS RunIds
FROM ret.RetentionArchiveDate AS a
WHERE a.ExportStatus = 'SUCCEEDED'
GROUP BY a.TableConfigId, a.BusinessDate
HAVING COUNT(*) > 1;

/* ---- 13. Duration and performance per table run ---- */
SELECT l.RunId, r.ProcessType, r.TriggeredBy, c.SchemaName + N'.' + c.TableName AS TableName, l.Status,
       l.ExportDateCount, l.RowsExported, l.RowsDeleted, l.DeleteBatchCount,
       DATEDIFF(SECOND, l.StartTime, l.EndTime) AS TableSeconds,
       CAST(DATEDIFF(SECOND, l.StartTime, l.EndTime) * 1.0 / NULLIF(l.ExportDateCount, 0) AS DECIMAL(10, 1)) AS SecondsPerDate,
       (SELECT SUM(DATEDIFF(SECOND, a.ExportStartTime, a.ExportEndTime)) FROM ret.RetentionArchiveDate AS a
         WHERE a.TableLogId = l.TableLogId) AS ExportSecondsSum
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionRunLog AS r ON r.RunId = l.RunId
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.EndTime IS NOT NULL AND (@TableConfigId IS NULL OR l.TableConfigId = @TableConfigId)
ORDER BY l.RunId DESC, l.TableLogId;

/* ---- 14. Expired archive deletion (Daily Routine, DR-05) ---- */
SELECT l.RunId, l.RunDate, c.SchemaName + N'.' + c.TableName AS TableName, l.ArchiveCutoffDate,
       l.ArchiveFoldersDeleted, l.ArchiveFilesDeleted, s.Status AS ExpireStatus, s.Message, s.ErrorCode, s.ErrorMessage
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
LEFT JOIN ret.RetentionStepLog AS s ON s.TableLogId = l.TableLogId AND s.StepCode = 'EXPIRE'
WHERE l.ProcessType = 'DAILY_ROUTINE' AND l.RunId = @RunId
ORDER BY l.TableLogId, s.StepLogId;

/* ---- 15. Parquet column renaming (decision D-6) ---- */
--     Needs patch v0.6.1 (pipeline/sql/deploy/08_patch_v0.6.1_parquet_column_names.sql)
IF OBJECT_ID(N'ret.vw_ParquetColumnMap', N'V') IS NOT NULL
    EXEC sp_executesql N'SELECT * FROM ret.vw_ParquetColumnMap
                         WHERE IsRenamed = 1 AND (@Tc IS NULL OR TableConfigId = @Tc)
                         ORDER BY TableConfigId, ColumnOrdinal;', N'@Tc INT', @Tc = @TableConfigId;
ELSE
    SELECT N'ret.vw_ParquetColumnMap not found: patch v0.6.1 (D-6) is not deployed. Run pipeline/sql/deploy/08_patch_v0.6.1_parquet_column_names.sql.' AS Warning;

/* ---- 16. Log volume (log retention, LogRetentionYears) ---- */
SELECT N'RetentionRunLog' AS LogTable, COUNT(*) AS Rows, MIN(StartTime) AS Oldest FROM ret.RetentionRunLog
UNION ALL SELECT N'RetentionTableLog', COUNT(*), MIN(StartTime) FROM ret.RetentionTableLog
UNION ALL SELECT N'RetentionStepLog', COUNT(*), MIN(StartTime) FROM ret.RetentionStepLog
UNION ALL SELECT N'RetentionArchiveDate', COUNT(*), MIN(CAST(BusinessDate AS DATETIME2(3))) FROM ret.RetentionArchiveDate;
